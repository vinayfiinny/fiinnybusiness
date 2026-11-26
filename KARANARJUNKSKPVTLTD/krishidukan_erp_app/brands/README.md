# White-label builds

The Android flavors share the Flutter code, Firebase project, and logins.
Each flavor has its own package name and can be installed on the same device.

| Flavor | Package name | App name |
| --- | --- | --- |
| `karanarjun` (default) | `com.krishidukan.erp` | KrishiDukan ERP |
| `agrimass` | `com.Agrimass.erp` | Agrimass |

## Build one

In GitHub Actions, run **ERP App APK**, select the brand, and choose `apk`
for testing or `aab` for Google Play. Play builds require the upload
keystore and passwords configured as the workflow's signing secrets.
Agrimass uses `AGRIMASS_ANDROID_KEYSTORE_BASE64`, `AGRIMASS_KEYSTORE_PASSWORD`,
`AGRIMASS_KEY_ALIAS`, and `AGRIMASS_KEY_PASSWORD`. KaranArjun uses the same
secret names without the prefix.

For a local Agrimass build:

    flutter build apk --release --flavor agrimass
    flutter build appbundle --release --flavor agrimass

## Agrimass Firebase registration

Register `com.Agrimass.erp` as an Android app in the existing
`karanarjun-pvt-ltd` Firebase project. Save its downloaded
`google-services.json` at `android/app/src/agrimass/google-services.json`.
The default flavor uses `android/app/google-services.json`.
Add the Agrimass Play app signing certificate's SHA-1 in Firebase before
testing Google Sign-In from the Play-distributed app.

The launcher resources live in `android/app/src/agrimass/res/` and are
generated from `assets/brands/agrimass/app_icon.png`. The app's sign-in
screen uses the same source image.
