# Firebase Storage setup

If you see **"object not found"** or **"Storage bucket not found"** when saving notes/audio to the cloud, the default Cloud Storage bucket has not been created yet.

## 1. Create the default Storage bucket

1. Open [Firebase Console](https://console.firebase.google.com/) and select your project (**ai-mic-18768**).
2. In the left sidebar, go to **Build → Storage**.
3. If you see **Get started**, click it.  
   - If you are prompted to upgrade to the **Blaze (pay-as-you-go)** plan, complete the upgrade (Storage requires it as of Oct 2024; there is a free tier).
4. Choose a **location** for your bucket (e.g. **us-central1**, **us-east1**, or **us-west1** for Always Free tier).
5. Leave or adjust the default security rules, then click **Done**.

Your default bucket will be created. Its name will be:

- **`ai-mic-18768.firebasestorage.app`** (new format, used by this app)

or, for older projects:

- **`ai-mic-18768.appspot.com`**

This app uses the bucket from your Flutter Firebase config (`firebase_options.dart`), which should match the bucket shown in the Storage **Files** tab.

## 2. Deploy Storage security rules

From the project root (where `firebase.json` lives):

```bash
firebase deploy --only storage
```

This deploys `storage.rules` so that only signed-in users can read/write their own `<userId>/notes/<noteUuid>/raw_audio.mp4`.

## 3. Verify

- In Firebase Console → **Storage → Files**, you should see the default bucket (no files until the app uploads).
- Run the app, sign in, record, and save; the note audio should upload and appear under `<your-uid>/notes/<noteUuid>/raw_audio.mp4`.

If errors persist, confirm in **Storage → Files** that the bucket name matches `storageBucket` in `lib/firebase_options.dart`.
