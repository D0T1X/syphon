import 'dart:async';
import 'dart:math';
import 'package:syphon/global/libs/matrix/encryption.dart';
import 'package:syphon/global/libs/matrix/errors.dart';
import 'package:syphon/global/libs/matrix/index.dart';
import 'package:syphon/store/alerts/actions.dart';
import 'package:syphon/store/media/actions.dart';
import 'package:syphon/store/rooms/events/actions.dart';
import 'package:syphon/store/sync/actions.dart';
import 'package:syphon/store/user/model.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import 'package:syphon/store/index.dart';

import 'room/model.dart';
import 'events/model.dart';

final protocol = DotEnv().env['PROTOCOL'];

class SetLoading {
  final bool loading;
  SetLoading({this.loading});
}

class SetSending {
  final bool sending;
  final Room room;
  SetSending({this.sending, this.room});
}

class SetRooms {
  final List<Room> rooms;
  SetRooms({this.rooms});
}

class SetRoom {
  final Room room;
  SetRoom({this.room});
}

// Atomically Update specific room attributes
class UpdateRoom {
  final String id; // room id
  final Message draft;
  final bool syncing;

  UpdateRoom({
    this.id,
    this.draft,
    this.syncing,
  });
}

class RemoveRoom {
  final Room room;
  RemoveRoom({this.room});
}

class ResetRooms {
  ResetRooms();
}

/**
 * tempId for messages that have attempted sending but not finished
 */
class SaveOutboxMessage {
  final String id; // TODO: room id
  final String tempId;
  final Message pendingMessage;

  SaveOutboxMessage({
    this.id,
    this.tempId,
    this.pendingMessage,
  });
}

class DeleteOutboxMessage {
  final Message message; // room id

  DeleteOutboxMessage({
    this.message,
  });
}

/**
 * Sync State Data
 * 
 * Helper action that will determine how to update a room
 * from data formatted like a sync request
 */
ThunkAction<AppState> syncRooms(
  Map roomData,
) {
  return (Store<AppState> store) async {
    // init new store containers
    final rooms = store.state.roomStore.rooms ?? Map<String, Room>();
    final user = store.state.authStore.user;
    final lastSince = store.state.syncStore.lastSince;

    // syncing null data happens sometimes?
    if (roomData == null) {
      return;
    }

    // update those that exist or add a new room
    roomData.forEach((id, json) {
      // use pre-existing values where available
      Room room = rooms.containsKey(id) ? rooms[id] : Room(id: id);

      // Filter through parsers
      room = room.fromSync(
        json: json,
        currentUser: user,
        lastSince: lastSince,
      );

      // fetch avatar if a uri was found
      if (room.avatarUri != null) {
        store.dispatch(fetchThumbnail(
          mxcUri: room.avatarUri,
        ));
      }

      // fetch previous messages since last /sync if
      // more than one batch needs to be fetched (a gap)
      // and is not already at the end of the hash
      // the end would be room.prevHash == room.endHash
      if (room.prevHash != null && room.prevHash != room.endHash) {
        store.dispatch(
          fetchMessageEvents(
            room: room,
            endHash: room.endHash,
            startHash: room.prevHash,
          ),
        );
      }

      store.dispatch(SetRoom(room: room));
    });
  };
}

/**
 *  
 *  Fetch Rooms (w/o /sync)
 * 
 * Takes a negligible amount of time
 * 
 * final stopwatch = Stopwatch()..start();
 * print('[fetchRooms] TIMESTAMP ${stopwatch.elapsed}');
 * stopwatch.stop();
 */
ThunkAction<AppState> fetchRooms() {
  return (Store<AppState> store) async {
    try {
      store.dispatch(SetLoading(loading: true));

      final data = await MatrixApi.fetchRoomIds(
        protocol: protocol,
        homeserver: store.state.authStore.user.homeserver,
        accessToken: store.state.authStore.user.accessToken,
      );

      if (data['errcode'] != null) {
        throw data['error'];
      }

      // Convert joined_rooms to Room objects
      final List<dynamic> rawJoinedRooms = data['joined_rooms'];
      final joinedRooms = rawJoinedRooms.map((id) => Room(id: id)).toList();
      final fullJoinedRooms = joinedRooms.map((room) async {
        try {
          final stateEvents = await MatrixApi.fetchStateEvents(
            protocol: protocol,
            homeserver: store.state.authStore.user.homeserver,
            accessToken: store.state.authStore.user.accessToken,
            roomId: room.id,
          );

          if (!(stateEvents is List) && stateEvents['errcode'] != null) {
            throw stateEvents['error'];
          }

          final messageEvents = await MatrixApi.fetchMessageEvents(
            protocol: protocol,
            homeserver: store.state.authStore.user.homeserver,
            accessToken: store.state.authStore.user.accessToken,
            roomId: room.id,
            limit: 20,
          );

          store.dispatch(syncRooms({
            '${room.id}': {
              'state': {
                'events': stateEvents,
              },
              'timeline': {
                'events': messageEvents['chunk'],
              }
            },
          }));
        } catch (error) {
          print('[fetchRooms] ${room.id} $error');
        } finally {
          store.dispatch(UpdateRoom(id: room.id, syncing: false));
        }
      });

      await Future.wait(fullJoinedRooms);
    } catch (error) {
      // WARNING: Silent error, throws error if they have no direct messages
      print('[fetchRooms] error: $error');
    } finally {
      store.dispatch(SetLoading(loading: false));
    }
  };
}

/**
 * Fetch Direct Rooms
 * 
 * Fetches both state and message of direct rooms
 * found from account_data of current authed user
 * 
 * @riot-bot:matrix.org: [!ajJxpUAIJjYYTzvsHo:matrix.org],
 * alekseyparfyonov@gmail.com: [!muTrhMUMwdJSrYlqic:matrix.org] 
 */
ThunkAction<AppState> fetchDirectRooms() {
  return (Store<AppState> store) async {
    final stopwatch = Stopwatch()..start();
    try {
      store.dispatch(SetLoading(loading: true));

      final data = await MatrixApi.fetchDirectRoomIds(
        protocol: protocol,
        homeserver: store.state.authStore.user.homeserver,
        accessToken: store.state.authStore.user.accessToken,
        userId: store.state.authStore.user.userId,
      );

      if (data['errcode'] != null) {
        throw data['error'];
      }

      // Mark specified rooms as direct chats
      final directRooms = data as Map<String, dynamic>;

      // TODO: refactor more functional
      // Fetch room state and messages by roomId
      directRooms.forEach((userId, roomIds) {
        roomIds.forEach((roomId) async {
          try {
            final stateEvents = await MatrixApi.fetchStateEvents(
              protocol: protocol,
              homeserver: store.state.authStore.user.homeserver,
              accessToken: store.state.authStore.user.accessToken,
              roomId: roomId,
            );

            if (!(stateEvents is List) && stateEvents['errcode'] != null) {
              throw stateEvents['error'];
            }

            final messageEvents = await MatrixApi.fetchMessageEvents(
              protocol: protocol,
              homeserver: store.state.authStore.user.homeserver,
              accessToken: store.state.authStore.user.accessToken,
              roomId: roomId,
              limit: 20,
            );

            if (messageEvents['errcode'] != null) {
              throw messageEvents['error'];
            }

            // Format response like /sync request
            // Hacked together to provide isDirect data
            await store.dispatch(syncRooms({
              '$roomId': {
                'state': {
                  'events': stateEvents,
                },
                'timeline': {
                  'events': messageEvents['chunk'],
                  'prev_batch': messageEvents['from'],
                },
                'account_data': {
                  'events': [
                    {
                      "type": 'm.direct',
                      'content': {
                        '$userId',
                      }
                    }
                  ],
                }
              },
            }));
          } catch (error) {
            print('[fetchDirectRooms] INTERNAL $error');
          }
        });
      });
    } catch (error) {
      print('[fetchDirectRooms] $error');
    } finally {
      store.dispatch(SetLoading(loading: false));
      print('[fetchDirectRooms] TIMESTAMP ${stopwatch.elapsed}');
      stopwatch.stop();
    }
  };
}

/**
 * Create Room 
 */
ThunkAction<AppState> createRoom({
  String name = 'New Chat',
  String alias,
  String topic,
  String avatarUri,
  List<User> invites,
  bool isDirect = false,
}) {
  return (Store<AppState> store) async {
    try {
      store.dispatch(SetLoading(loading: true));
      await store.dispatch(stopSyncObserver());

      final data = await MatrixApi.createRoom(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomName: name,
        roomTopic: topic,
        roomAlias: alias,
        invites: invites.map((user) => user.userId).toList(),
        isDirect: isDirect,
      );

      final newRoomId = data['room_id'];

      if (data['errcode'] != null) {
        throw data['error'];
      }

      print('[createRoom] $data $newRoomId');

      if (isDirect) {
        final accountData = {
          '${invites[0].userId}': [newRoomId]
        };

        final data = await MatrixApi.saveAccountData(
          protocol: protocol,
          accessToken: store.state.authStore.user.accessToken,
          homeserver: store.state.authStore.user.homeserver,
          userId: store.state.authStore.user.userId,
          type: AccountDataTypes.direct,
          accountData: accountData,
        );

        print('[DIRECT Save Account Data] $data');

        if (data['errcode'] != null) {
          throw data['error'];
        }

        await store.dispatch(fetchDirectRooms());
      }
      await store.dispatch(startSyncObserver());

      return newRoomId;
    } catch (error) {
      print('[createRoom] error: $error');
      return null;
    } finally {
      store.dispatch(SetLoading(loading: false));
    }
  };
}

/**
 * Toggle Direct Room
 * 
 * NOTE: https://github.com/matrix-org/matrix-doc/issues/1519
 * 
 * Fetch the direct rooms list and recalculate it without the
 * given alias
 */
ThunkAction<AppState> toggleDirectRoom({Room room}) {
  return (Store<AppState> store) async {
    try {
      store.dispatch(SetLoading(loading: true));

      final data = await MatrixApi.fetchDirectRoomIds(
        protocol: protocol,
        homeserver: store.state.authStore.user.homeserver,
        accessToken: store.state.authStore.user.accessToken,
        userId: store.state.authStore.user.userId,
      );

      if (data['errcode'] != null) {
        throw data['error'];
      }

      final currentUser = store.state.authStore.user;

      final otherUser = room.users.values.firstWhere(
        (user) => user.userId != currentUser.userId,
      );

      Map directRoomUsers = data as Map<String, dynamic>;

      if (otherUser == null) {
        throw 'Cannot toggle room to direct without other users';
      }

      if (directRoomUsers[otherUser.userId] == null) {
        directRoomUsers[otherUser.userId] = [room.id];
      } else {
        directRoomUsers = directRoomUsers.map((user, rooms) {
          List<dynamic> updatedRooms = List.from(rooms as List<dynamic>);
          if (updatedRooms.contains(room.id)) {
            updatedRooms.remove(room.id);
          }
          return MapEntry(user, updatedRooms);
        });
      }

      // Filter out empty list entries for a user
      directRoomUsers.removeWhere((key, value) {
        final roomIds = value as List<dynamic>;
        return roomIds.isEmpty;
      });

      final saveData = await MatrixApi.saveAccountData(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        userId: store.state.authStore.user.userId,
        type: AccountDataTypes.direct,
        accountData: directRoomUsers,
      );

      if (saveData['errcode'] != null) {
        throw saveData['error'];
      }

      store.dispatch(fetchDirectRooms());

      print('[toggleDirectRoom] successfully toggled direct ${room.name}');
    } catch (error) {
      print('[toggleDirectRoom] error: $error');
    } finally {
      store.dispatch(SetLoading(loading: false));
    }
  };
}

/**
 * Toggle Room Encryption On (Only)
 */
ThunkAction<AppState> toggleRoomEncryption({Room room}) {
  return (Store<AppState> store) async {
    try {
      if (room.encryptionEnabled) {
        throw 'Room is already encrypted';
      }

      final content = {
        'algorithm': Algorithms.megolmv1,
      };

      final data = await MatrixApi.sendEvent(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomId: room.id,
        eventType: EventTypes.encryption,
        content: content,
      );

      if (data['errcode'] != null) {
        throw data['error'];
      }

      store.dispatch(fetchStateEvents(room: room));
      print('[toggleRoomEncryption] success $data');
    } catch (error) {
      store.dispatch(addAlert(type: 'warning', message: error));
      print('[toggleRoomEncryption] failure $error');
    }
  };
}

ThunkAction<AppState> acceptRoom({Room room}) {
  return (Store<AppState> store) async {
    try {
      final data = await MatrixApi.joinRoom(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomId: room.id,
      );

      if (data['errcode'] != null) {
        throw data['error'];
      }

      final rooms = store.state.roomStore.rooms ?? Map<String, Room>();

      Room joinedRoom = rooms.containsKey(room.id)
          ? rooms[room.id]
          : Room(
              id: room.id,
            );

      store.dispatch(SetRoom(
        room: joinedRoom.copyWith(invite: false),
      ));

      await store.dispatch(fetchRooms());
      await store.dispatch(fetchDirectRooms());
    } catch (error) {
      store.dispatch(addAlert(type: 'warning', message: error));
      print(error);
    }
  };
}

/**
 * Delete Room
 * 
 * Both leaves and forgets room
 * 
 * TODO: make sure this is in accordance with matrix in that
 * the user can only delete if owning the room, or leave if
 * just a member
 */
ThunkAction<AppState> removeRoom({Room room}) {
  return (Store<AppState> store) async {
    try {
      store.dispatch(SetLoading(loading: true));

      // submit a leave room request
      final leaveData = await MatrixApi.leaveRoom(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomId: room.id,
      );

      // Remove the room locally if it's already been removed remotely
      if (leaveData['errcode'] != null) {
        if (leaveData['errcode'] == MatrixErrors.room_unknown) {
          await store.dispatch(RemoveRoom(room: Room(id: room.id)));
        } else if (leaveData['errcode'] == MatrixErrors.room_not_found) {
          await store.dispatch(RemoveRoom(room: Room(id: room.id)));
        }
        throw leaveData['error'];
      }
      if (!kReleaseMode) {
        print('[removeRoom|leaveData] success $leaveData');
      }

      final forgetData = await MatrixApi.forgetRoom(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomId: room.id,
      );

      if (forgetData['errcode'] != null) {
        if (leaveData['errcode'] == MatrixErrors.room_not_found) {
          // TODO: confirm this works, deletes room if it doesn't
          await store.dispatch(RemoveRoom(room: Room(id: room.id)));
        }
        throw forgetData['error'];
      }

      if (room.direct) {
        await store.dispatch(toggleDirectRoom(room: room));
      }

      if (!kReleaseMode) {
        print('[removeRoom] forgetData $forgetData');
      }

      await store.dispatch(RemoveRoom(room: Room(id: room.id)));
      print('[removeRoom] successfully removed ${room.name}');
    } catch (error) {
      print('[removeRoom] error: $error');
    } finally {
      store.dispatch(SetLoading(loading: false));
    }
  };
}

/**
 * Delete Room
 * 
 * NOTE: https://github.com/vector-im/riot-web/issues/722
 * NOTE: https://github.com/vector-im/riot-web/issues/6978
 * NOTE: https://github.com/matrix-org/matrix-doc/issues/948
 * 
 * Kick all (if owner), tries to delete alias, and leaves
 * TODO: make sure this is in accordance with matrix in that
 * the user can only delete if owning the room, or leave if
 * just a member
 */
ThunkAction<AppState> deleteRoom({Room room}) {
  return (Store<AppState> store) async {
    try {
      store.dispatch(SetLoading(loading: true));

      final deleteData = await MatrixApi.leaveRoom(
        protocol: protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.user.homeserver,
        roomId: room.id,
      );

      if (deleteData['errcode'] != null) {
        throw deleteData['error'];
      }

      if (!kReleaseMode) {
        print('[deleteRoom] $deleteData');
        print('[deleteRoom] room was successfully deleted');
      }

      store.dispatch(RemoveRoom(room: Room(id: room.id)));
    } catch (error) {
      print('[deleteRoom] error: $error');
    }
  };
}

/**
 * Create Draft Room
 * 
 * TODO: make sure this is in accordance with matrix in that
 * A local only room that has not been established with matrix
 * meant to prep a room or first message before actually creating it 
 */
// ThunkAction<AppState> createDraftRoom({
//   String name = 'New Chat',
//   String topic,
//   String avatarUri,
//   List<User> users,
//   bool isDirect = false,
// }) {
//   return (Store<AppState> store) async {
//     try {
//       final draftId = Random.secure().nextInt(1 << 32).toString();

//       final draftRoom = Room(
//         id: draftId,
//         name: name,
//         topic: topic,
//         direct: isDirect,
//         avatarUri: avatarUri,
//         isDraftRoom: true,
//         users: Map.fromIterable(
//           users,
//           key: (user) => user.id,
//           value: (user) => user,
//         ),
//       );

//       await store.dispatch(SetRoom(room: draftRoom));
//       return draftRoom;
//     } catch (error) {
//       print('[createDraftRoom] error: $error');
//       return null;
//     }
//   };
// }

/**
 * TODO: Room Drafts
 * 
 * Convert a draft room to a remote matrix room
 */
// ThunkAction<AppState> convertDraftRoom({
//   Room room,
// }) {
//   return (Store<AppState> store) async {
//     try {
//       if (!room.isDraftRoom) {
//         throw 'Room has already been created';
//       }

//       final newRoomId = await store.dispatch(
//         createRoom(
//           name: room.name,
//           topic: room.topic,
//           invites: room.users,
//           isDirect: room.direct,
//         ),
//       );

//       if (newRoomId == null) {
//         throw 'Failed to convert draft room to a real room';
//       }

//       // To temporarily redirect to the new room in the UI
//       return Room(
//         id: newRoomId,
//         name: room.name,
//       );
//     } catch (error) {
//       print('[createRoom] error: $error');
//       return null;
//     }
//   };
// }