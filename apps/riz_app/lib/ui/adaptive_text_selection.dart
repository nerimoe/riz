import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@visibleForTesting
bool useBrowserNativeTextSelection({
  required bool isWeb,
  required TargetPlatform platform,
}) => isWeb && platform == TargetPlatform.iOS;

bool get _usesBrowserNativeTextSelection => useBrowserNativeTextSelection(
  isWeb: kIsWeb,
  platform: defaultTargetPlatform,
);

/// Safari already supplies the magnifier, handles, and clipboard menu for the
/// DOM text input used by Flutter Web. Desktop controls keep Flutter's editing
/// gestures without painting a second touch selection layer over Safari's.
TextSelectionControls? get rizTextSelectionControls =>
    _usesBrowserNativeTextSelection ? desktopTextSelectionHandleControls : null;

TextMagnifierConfiguration? get rizTextMagnifierConfiguration =>
    _usesBrowserNativeTextSelection
    ? TextMagnifierConfiguration.disabled
    : null;
