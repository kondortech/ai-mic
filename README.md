# ai_mic

A Flutter app for recording audio with one-way sync to Firebase (Cloud Storage + Firestore).

## Firebase setup (for cloud sync)

1. **Configure the Flutter app**  
   From the project root run:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```
   This creates/updates `lib/firebase_options.dart` and adds platform config (e.g. `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist`). If you prefer not to use FlutterFire CLI, add your Firebase config files manually and call `Firebase.initializeApp()` in `main.dart` (e.g. with a named options object).

2. **Enable sign-in methods**  
   In [Firebase Console](https://console.firebase.google.com/) → Authentication → Sign-in method, enable **Email/Password** and/or **Google**.

   **Google Sign-In on Android (fixes APIException 10):**
   - Add your **SHA-1** in Firebase Console → Project settings → Your apps → Android app → Add fingerprint. Get it with: `cd android && ./gradlew signingReport` (use the SHA-1 under `Variant: debug` or your signing config).
   - Get the **Web client ID**: [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials → open **"Web client (auto created by Google Service)"** → copy the Client ID (`xxxxx.apps.googleusercontent.com`).
   - Set it in `lib/config/google_sign_in_config.dart`: `const String kGoogleSignInWebClientId = 'YOUR_WEB_CLIENT_ID';`

3. **Create Storage and Firestore**  
   In the Firebase Console, enable **Cloud Storage** and **Cloud Firestore** (create a database if prompted).

4. **Deploy rules**  
   From the project root:
   ```bash
   firebase deploy --only firestore,storage
   ```

Sync behavior:

- **Save recording**: File is uploaded to Storage at `recordings/{userId}/{fileName}` and metadata (description, timestamp, `deleted: false`) is written to Firestore at `users/{userId}/recordings/{docId}`.
- **Delete recording locally**: Only the local file and local metadata are removed; in Firestore the same document is updated with `deleted: true`. The file in Storage is **not** deleted (soft delete).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
