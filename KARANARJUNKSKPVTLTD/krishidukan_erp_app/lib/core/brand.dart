import 'package:flutter/services.dart' show appFlavor;

/// The name and logo for the selected build flavor. The Dart defines also
/// support builds that supply branding without an Android flavor.
abstract final class Brand {
  static const _agrimass = appFlavor == 'agrimass';

  /// Shown as the app title and in the profile footer.
  static const name = String.fromEnvironment('BRAND_NAME',
      defaultValue: _agrimass ? 'Agrimass' : 'KrishiDukan ERP');

  /// Short name used in sentences ("Open the {short} ERP app").
  static const shortName = String.fromEnvironment('BRAND_SHORT',
      defaultValue: _agrimass ? 'Agrimass' : 'KaranArjun');

  /// The logo shown on the login screen and in the app.
  static const logoAsset = String.fromEnvironment('BRAND_LOGO',
      defaultValue: _agrimass
          ? 'assets/brands/agrimass/app_icon.png'
          : 'assets/icons/app_icon.png');
}
