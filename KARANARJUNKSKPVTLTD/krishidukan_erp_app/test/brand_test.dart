import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukan_erp/core/brand.dart';

/// The default build is the KaranArjun app; a brand build (the workflow's
/// `--dart-define-from-file` with `brands/<id>/brand.json`) swaps only name and logo.
void main() {
  const branded = bool.hasEnvironment('BRAND_NAME');

  test('with no brand defined, the app is exactly the KaranArjun app', () {
    if (branded) return; // covered by the branded run below
    expect(Brand.name, 'KrishiDukan ERP');
    expect(Brand.shortName, 'KaranArjun');
    expect(Brand.logoAsset, 'assets/icons/app_icon.png');
  });

  test('the Agrimass brand files are complete and consistent', () {
    // Plain file checks, so they run in every build, branded or not.
    final json = File('brands/agrimass/brand.json').readAsStringSync();
    expect(json, contains('"BRAND_NAME": "Agrimass"'));
    expect(File('assets/brands/agrimass/app_icon.png').existsSync(), isTrue);
    expect(File('assets/brands/agrimass/logo.png').existsSync(), isTrue);
    expect(File('assets/brands/agrimass/tile.png').existsSync(), isTrue);
    expect(File('flutter_launcher_icons-agrimass.yaml').readAsStringSync(),
        contains('assets/brands/agrimass/app_icon.png'));
    expect(File('pubspec.yaml').readAsStringSync(), contains('assets/brands/agrimass/'));
    // The default app title / logo are not hardcoded anywhere else.
    expect(File('assets/icons/app_icon.png').existsSync(), isTrue);
  });

  test('a brand build carries the client name and logo', () {
    if (!branded) return;
    expect(Brand.name, 'Agrimass');
    expect(Brand.shortName, 'Agrimass');
    expect(Brand.logoAsset, 'assets/brands/agrimass/tile.png');
  });
}
