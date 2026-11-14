/// `flutter run --dart-define=USE_EMULATOR=true` points the app at the local
/// Auth + Firestore emulators under a demo- project id, so billing can be
/// exercised end to end without any chance of touching production data.
/// Shared so a second Firebase app (used to create portal logins without
/// signing the admin out) talks to the same emulator.
const useFirebaseEmulator = bool.fromEnvironment('USE_EMULATOR');
const firebaseEmulatorHost =
    String.fromEnvironment('EMULATOR_HOST', defaultValue: 'localhost');
