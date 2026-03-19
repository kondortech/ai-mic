/// Web client ID for Google Sign-In (required on Android to avoid APIException 10).
///
/// Get it from: [Google Cloud Console](https://console.cloud.google.com/)
/// → APIs & Services → Credentials → OAuth 2.0 Client IDs
/// → open the **"Web client (auto created by Google Service)"** (or create a Web client)
/// → copy the **Client ID** (looks like `xxxxx.apps.googleusercontent.com`).
///
/// Also add your app's SHA-1 in Firebase Console:
/// Project settings → Your apps → Android app → Add fingerprint.
/// Get SHA-1: `cd android && ./gradlew signingReport`
const String kGoogleSignInWebClientId =
    '1055509999220-jeis14d69u108cata0gl1ioh2jqo59t8.apps.googleusercontent.com';
