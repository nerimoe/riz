import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class AdaptiveComposerField extends StatelessWidget {
  const AdaptiveComposerField({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return AdaptiveComposerFieldIo(
        controller: controller,
        hintText: hintText,
      );
    }
    return _IosNativeComposer(controller: controller, hintText: hintText);
  }
}

class AdaptiveComposerFieldIo extends StatelessWidget {
  const AdaptiveComposerFieldIo({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    minLines: 1,
    maxLines: 7,
    decoration: InputDecoration(
      hintText: hintText,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
    ),
  );
}

class _IosNativeComposer extends StatefulWidget {
  const _IosNativeComposer({required this.controller, required this.hintText});

  final TextEditingController controller;
  final String hintText;

  @override
  State<_IosNativeComposer> createState() => _IosNativeComposerState();
}

class _IosNativeComposerState extends State<_IosNativeComposer> {
  web.HTMLTextAreaElement? element;
  StreamSubscription<web.Event>? inputSubscription;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(syncFromController);
  }

  @override
  void didUpdateWidget(covariant _IosNativeComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(syncFromController);
      widget.controller.addListener(syncFromController);
    }
    element?.placeholder = widget.hintText;
    syncFromController();
  }

  void onElementCreated(Object object) {
    final textarea = object as web.HTMLTextAreaElement;
    element = textarea;
    textarea
      ..value = widget.controller.text
      ..placeholder = widget.hintText
      ..rows = 3
      ..spellcheck = true
      ..setAttribute('enterkeyhint', 'enter')
      ..setAttribute('aria-label', widget.hintText);
    textarea.style
      ..width = '100%'
      ..height = '100%'
      ..boxSizing = 'border-box'
      ..border = '0'
      ..outline = '0'
      ..resize = 'none'
      ..backgroundColor = 'transparent'
      ..color = _cssColor(Theme.of(context).colorScheme.onSurface)
      ..fontFamily = '-apple-system, BlinkMacSystemFont, sans-serif'
      ..fontSize = '16px'
      ..lineHeight = '22px'
      ..padding = '12px 14px 8px'
      ..overflowY = 'auto'
      ..touchAction = 'auto'
      ..setProperty('-webkit-user-select', 'text')
      ..setProperty('user-select', 'text')
      ..setProperty('-webkit-touch-callout', 'default');
    inputSubscription = textarea.onInput.listen((_) {
      final value = textarea.value;
      if (widget.controller.text == value) return;
      final offset = textarea.selectionStart;
      widget.controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: offset),
      );
    });
  }

  void syncFromController() {
    final textarea = element;
    if (textarea == null || textarea.value == widget.controller.text) return;
    textarea.value = widget.controller.text;
    final offset = widget.controller.selection.isValid
        ? widget.controller.selection.extentOffset
        : widget.controller.text.length;
    textarea.setSelectionRange(offset, offset);
  }

  @override
  void dispose() {
    widget.controller.removeListener(syncFromController);
    inputSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: HtmlElementView.fromTagName(
      tagName: 'textarea',
      onElementCreated: onElementCreated,
    ),
  );
}

String _cssColor(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
