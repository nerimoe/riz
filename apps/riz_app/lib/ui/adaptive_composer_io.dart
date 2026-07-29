import 'package:flutter/material.dart';

import 'adaptive_text_selection.dart';

class AdaptiveComposerField extends StatelessWidget {
  const AdaptiveComposerField({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) => TextField(
    selectionControls: rizTextSelectionControls,
    magnifierConfiguration: rizTextMagnifierConfiguration,
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
