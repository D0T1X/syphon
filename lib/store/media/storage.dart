import 'dart:convert';
import 'dart:typed_data';

import 'package:sembast/sembast.dart';
import 'package:syphon/global/print.dart';

const String MEDIA = 'MEDIA';

Future<bool> checkMedia(
  String mxcUri, {
  Database storage,
}) async {
  final store = StoreRef<String, String>(MEDIA);

  return await store.record(mxcUri).exists(storage);
}

Future<void> saveMedia(
  String mxcUri,
  Uint8List data, {
  Database storage,
}) async {
  final store = StoreRef<String, String>(MEDIA);

  return await storage.transaction((txn) async {
    final record = store.record(mxcUri);
    await record.put(txn, json.encode(data as List<int>));
  });
}

/**
 * Load Media (Cold Storage)
 * 
 * load one set of media data based on mxc uri
 */
Future<Uint8List> loadMedia({
  String mxcUri,
  Database storage,
}) async {
  try {
    final store = StoreRef<String, String>(MEDIA);

    final mediaData = await store.record(mxcUri).get(storage);

    final dataBytes = json.decode(mediaData);

    // Convert json decoded List<int> to Uint8List
    return Uint8List.fromList(
        (dataBytes as List)?.map((e) => e as int)?.toList());
  } catch (error) {
    printError(error.toString(), title: 'loadMedia');
    return null;
  }
}

/**
 * Load All Media (Cold Storage)
 *  
 * load all media found within media storage
 */
Future<Map<String, Uint8List>> loadMediaAll({
  Database storage,
}) async {
  try {
    final Map<String, Uint8List> media = {};
    final store = StoreRef<String, String>(MEDIA);

    final mediaDataAll = await store.find(storage);

    for (RecordSnapshot<String, String> record in mediaDataAll) {
      final data = json.decode(record.value);

      // TODO: sometimes, a null gets saved to cold storage
      if (data != null) {
        media[record.key] = Uint8List.fromList(
          (data as List)?.map((e) => e as int)?.toList(),
        );
      }
    }

    return media;
  } catch (error) {
    printError(error.toString(), title: 'loadMediaAll');
    return null;
  }
}
