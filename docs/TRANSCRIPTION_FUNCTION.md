# Transcription Cloud Function

The **transcribeRecording** Cloud Function is a **callable** function: you invoke it from your app (or any authenticated client) when you want to transcribe a recording. It uses Google Cloud Speech-to-Text and saves the transcript to Storage (same UUID, different path and extension).

## Behavior

1. **Trigger**: You call the function explicitly (e.g. from the Flutter app after uploading a recording).
2. **Input**: Pass either:
   - **`storagePath`**: Full path in the default bucket, e.g. `recordings/{userId}/recording_{uuid}.m4a`
   - **`fileName`**: Just the file name, e.g. `recording_{uuid}.m4a` (the function uses the current user’s `recordings/` folder).
3. **Auth**: The user must be signed in. They may only transcribe files under their own `recordings/{userId}/` path.
4. **Transcription**: The audio is sent to Cloud Speech-to-Text (M4A/MP4 are converted to FLAC first).
5. **Output**: The transcript is written to **Cloud Storage** at `transcripts/{userId}/recording_{uuid}.txt`.

Example: for a recording at `recordings/abc123/recording_550e8400-e29b-41d4-a716-446655440000.m4a`, the transcript is saved at `transcripts/abc123/recording_550e8400-e29b-41d4-a716-446655440000.txt`.

## Calling from Flutter

```dart
import 'package:cloud_functions/cloud_functions.dart';

// After uploading the recording (e.g. recording_<uuid>.m4a):
final result = await FirebaseFunctions.instance
    .httpsCallable('transcribeRecording')
    .call<Map<String, dynamic>>({
  'fileName': 'recording_550e8400-e29b-41d4-a716-446655440000.m4a',
  // or 'storagePath': 'recordings/YOUR_UID/recording_550e8400-e29b-41d4-a716-446655440000.m4a',
});
// result.data['ok'] == true, result.data['transcriptPath'], result.data['transcriptLength']
```

## Requirements

- **Firebase Blaze plan** (pay-as-you-go) for Cloud Functions and Cloud Storage.
- **Cloud Speech-to-Text API** enabled in [Google Cloud Console](https://console.cloud.google.com/apis/library/speech.googleapis.com).
- Default Storage bucket created (see [STORAGE_SETUP.md](STORAGE_SETUP.md)).

## Deploy

From the project root:

```bash
firebase deploy --only functions
```

To deploy only the transcription function:

```bash
firebase deploy --only functions:transcribeRecording
```

## Security

- **Recordings**: Users can read/write only their own `recordings/{userId}/` (see `storage.rules`).
- **Transcripts**: Users can **read** their own `transcripts/{userId}/`; only the Cloud Function (service account) can write.
- Temp files used during M4A conversion (`.transcribe_temp/`) are not user-accessible.

## Language and limits

- Transcription is configured for **English (en-US)**. To change, edit `languageCode` in `functions/index.js`.
- Long files (> ~10 MB) use **long-running recognition** (up to ~9 minutes). Shorter files use synchronous recognition.
- Function timeout is 540 seconds (9 minutes); increase in Firebase Console if needed.
