/// Who this build belongs to. The same code ships as the KaranArjun ERP app
/// (the defaults below, so a plain `flutter build` is unchanged) and as a
/// client's white-label app (`brands/<id>/brand.json` passed with
/// `--dart-define-from-file`). Server, data and logins are shared; only the
/// name and logo differ. See brands/README.md.
abstract final class Brand {
  /// Shown as the app title and in the profile footer.
  static const name = String.fromEnvironment('BRAND_NAME', defaultValue: 'KrishiDukan ERP');

  /// Short name used in sentences ("Open the {short} ERP app").
  static const shortName = String.fromEnvironment('BRAND_SHORT', defaultValue: 'KaranArjun');

  /// The logo shown on the login screen and in the app.
  static const logoAsset = String.fromEnvironment('BRAND_LOGO', defaultValue: 'assets/icons/app_icon.png');
}
