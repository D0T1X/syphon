import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:syphon/global/dimensions.dart';

///
/// Secured Text Field Input
///
/// Remove all auto completions by default
/// Other functionality that could indicate
/// text content
///
class TextFieldSecure extends StatelessWidget {
  const TextFieldSecure({
    Key? key,
    this.label,
    this.hint,
    this.suffix,
    this.focusNode,
    this.controller,
    this.maxLines = 1,
    this.valid = true,
    this.disabled = false,
    this.obscureText = false,
    this.disableSpacing = false,
    this.autocorrect = false,
    this.enabledSuggestions = false,
    this.textAlign = TextAlign.left,
    this.formatters = const [],
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.textInputAction,
    this.autofillHints,
  }) : super(key: key);

  final bool valid;
  final bool disabled;
  final bool obscureText;
  final bool disableSpacing;
  final bool autocorrect;
  final bool enabledSuggestions;

  final int maxLines;
  final Widget? suffix; // include actions
  final String? hint;
  final String? label;
  final TextAlign textAlign;

  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final TextEditingController? controller;
  final List<TextInputFormatter> formatters;

  final Function? onChanged;
  final Function? onSubmitted;
  final Function? onEditingComplete;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) => Container(
        height: Dimensions.inputHeight,
        constraints: BoxConstraints(
          minWidth: Dimensions.inputWidthMin,
          maxWidth: Dimensions.inputWidthMax,
        ),
        child: TextField(
          enabled: !disabled,
          maxLines: maxLines,
          focusNode: focusNode,
          controller: controller,
          onChanged: onChanged as void Function(String)?,
          onSubmitted: onSubmitted as void Function(String)?,
          textInputAction: textInputAction,
          onEditingComplete: onEditingComplete as void Function()?,
          autocorrect: autocorrect,
          enableSuggestions: enabledSuggestions,
          autofillHints: disabled ? null : autofillHints,
          selectionHeightStyle: BoxHeightStyle.max,
          inputFormatters: !disableSpacing
              ? [
                  FilteringTextInputFormatter.deny(RegExp(r'\t')),
                  ...formatters,
                ]
              : [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                  FilteringTextInputFormatter.deny(RegExp(r'\t')),
                  FilteringTextInputFormatter.deny(RegExp(r'\n')),
                  ...formatters,
                ],
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          textAlign: textAlign,
          obscureText: obscureText,
          cursorColor: Theme.of(context).primaryColor,
          keyboardAppearance: Theme.of(context).brightness,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: suffix,
            contentPadding: Dimensions.inputPadding,
            border: OutlineInputBorder(
              borderSide: !valid
                  ? BorderSide()
                  : BorderSide(
                      color: Theme.of(context).primaryColor,
                    ),
              borderRadius: BorderRadius.circular(
                Dimensions.inputBorderRadius,
              ),
            ),
          ),
        ),
      );
}
