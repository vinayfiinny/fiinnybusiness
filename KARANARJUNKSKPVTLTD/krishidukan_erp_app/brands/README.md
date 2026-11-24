# White-label builds

The same app, rebranded per client. Server, data and logins are shared; only
the name and logo change. The default build (no brand) is the KaranArjun ERP
app, untouched.

## Build one

GitHub -> Actions -> "ERP App APK" -> Run workflow -> choose **brand**.
The APK downloads from the run's Artifacts, named after the brand.

Locally (analyze/test only on the shared machine; release builds happen on
the build machine):

    flutter build apk --release --dart-define-from-file=brands/agrimass/brand.json

## Add a client

1. `assets/brands/<id>/app_icon.png` - square, 1024 px, white background, logo
   inside the middle ~65% (Android crops the edges of adaptive icons).
2. `brands/<id>/brand.json` - `BRAND_NAME`, `BRAND_SHORT`, `BRAND_LOGO`.
3. `flutter_launcher_icons-<id>.yaml` - copy the agrimass one, change the path.
4. Add `<id>` to the workflow's `brand` choices, and
   `assets/brands/<id>/` to the assets in pubspec.yaml.

Not covered (needs a new package id, Firebase app and signing key): a
separate Play Store listing, or both brands installed on one phone.
