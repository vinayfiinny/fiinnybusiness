import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/core/brand.dart';

/// The default build is the KaranArjun app; a brand build (the workflow's
/// `--dart-define-from-file` with `brands/<id>/brand.json`) swaps only name and logo.
void main() {
  const branded = bool.hasEnvironment('BRAND_NAME');
  const agrimassIcon = 'assets/brands/agrimass/app_icon.png';

  test('with no brand defined, the app is exactly the KaranArjun app', () {
    if (branded) return; // covered by the branded run below
    expect(Brand.name, 'KrishiDukan ERP');
    expect(Brand.shortName, 'KaranArjun');
    expect(Brand.logoAsset, 'assets/icons/app_icon.png');
  });

  test('the Agrimass brand files are complete and consistent', () {
    // Plain file checks, so they run in every build, branded or not.
    final brand =
        jsonDecode(File('brands/agrimass/brand.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(brand['BRAND_NAME'], 'Agrimass');
    expect(brand['BRAND_LOGO'], agrimassIcon);
    expect(File(agrimassIcon).existsSync(), isTrue);
    final launcher =
        File('brands/agrimass/launcher_icons.yaml').readAsStringSync();
    expect(launcher, contains('image_path: "$agrimassIcon"'));
    expect(launcher, contains('adaptive_icon_foreground: "$agrimassIcon"'));
    expect(File('pubspec.yaml').readAsStringSync(),
        contains('assets/brands/agrimass/'));
    // The Android app name must come from strings.xml (the brand step edits
    // it) — a hard-coded label left the Agrimass APK named "KrishiDukan ERP".
    expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('android:label="@string/app_name"'));
    // A flutter_launcher_icons-<x>.yaml file is read as a build flavor and the
    // icon never reaches the APK.
    expect(File('flutter_launcher_icons-agrimass.yaml').existsSync(), isFalse);
    // The default app title / logo are not hardcoded anywhere else.
    expect(File('assets/icons/app_icon.png').existsSync(), isTrue);
  });

  test('a brand build carries the client name and logo', () {
    if (!branded) return;
    expect(Brand.name, 'Agrimass');
    expect(Brand.shortName, 'Agrimass');
    expect(Brand.logoAsset, agrimassIcon);
  });
}
