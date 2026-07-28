import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riz_app/ui/adaptive_text_selection.dart';

void main() {
  test('uses browser-native selection only for iOS web', () {
    expect(
      useBrowserNativeTextSelection(isWeb: true, platform: TargetPlatform.iOS),
      isTrue,
    );
    expect(
      useBrowserNativeTextSelection(isWeb: false, platform: TargetPlatform.iOS),
      isFalse,
    );
    expect(
      useBrowserNativeTextSelection(
        isWeb: true,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
  });

  test('iOS web policy removes Flutter touch selection chrome', () {
    if (!kIsWeb) return;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(rizTextSelectionControls, same(desktopTextSelectionHandleControls));
    expect(
      rizTextMagnifierConfiguration,
      same(TextMagnifierConfiguration.disabled),
    );
  });
}
