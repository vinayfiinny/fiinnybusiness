import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/core/brand.dart';

/// Check the default and branded configurations on the shared project.
void main() {
  const branded = appFlavor == 'agrimass' || bool.hasEnvironment('BRAND_NAME');
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
    // The Android app name resolves through each flavor's resources.
    expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('android:label="@string/app_name"'));
    expect(
        File('android/app/src/agrimass/res/values/strings.xml')
            .readAsStringSync(),
        contains('<string name="app_name">Agrimass</string>'));
    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      expect(
          File('android/app/src/agrimass/res/mipmap-$density/ic_launcher.png')
              .existsSync(),
          isTrue);
      expect(
          File('android/app/src/agrimass/res/drawable-$density/ic_launcher_foreground.png')
              .existsSync(),
          isTrue);
    }
    expect(File('assets/icons/app_icon.png').existsSync(), isTrue);
  });

  test('a brand build carries the client name and logo', () {
    if (!branded) return;
    expect(Brand.name, 'Agrimass');
    expect(Brand.shortName, 'Agrimass');
    expect(Brand.logoAsset, agrimassIcon);
  });
}
