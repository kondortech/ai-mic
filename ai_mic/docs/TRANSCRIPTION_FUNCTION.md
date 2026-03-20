# Transcription Cloud Function

The **transcribeRecording** Cloud Function is a **callable** function: you invoke it from your app (or any authenticated client) when you want to transcribe a recording. It uses Google Cloud Speech-to-Text and saves the transcript to Storage (same UUID, different path and extension).

## Behavior

1. **Trigger**: You call the function explicitly (e.g. from the Flutter app after uploading a note audio).
2. **Input**: Pass either:
   - **`noteUuid`**: UUID of the note (recommended)
   - **`storagePath`**: Full path to the audio file in the default bucket, e.g. `{userId}/notes/{noteUuid}/raw_audio.mp4`
3. **Auth**: The user must be signed in. They may only transcribe files under their own `{userId}/notes/{noteUuid}/` path.
4. **Transcription**: The audio is sent to Cloud Speech-to-Text (M4A/MP4 are converted to FLAC first).
5. **Output**: The transcript is written to **Cloud Storage** at `{userId}/notes/{noteUuid}/raw_text.txt`.

Example: for audio at `abc123/notes/550e8400-e29b-41d4-a716-446655440000/raw_audio.mp4`, the transcript is saved at `abc123/notes/550e8400-e29b-41d4-a716-446655440000/raw_text.txt`.

## Calling from Flutter

```dart
import 'package:cloud_functions/cloud_functions.dart';

// After uploading the note audio (raw_audio.mp4):
final result = await FirebaseFunctions.instance
    .httpsCallable('transcribeRecording')
    .call<Map<String, dynamic>>({
  'noteUuid': '550e8400-e29b-41d4-a716-446655440000',
  // or 'storagePath': 'YOUR_UID/notes/<noteUuid>/raw_audio.mp4',
});
// result.data['ok'] == true, result.data['rawTextPath'], result.data['transcriptLength']
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

- **Notes audio**: Users can write only their own `{userId}/notes/{noteUuid}/raw_audio.mp4` (see `storage.rules`).
- **Notes text**: Users can read their own `{userId}/notes/{noteUuid}/raw_text.txt`; only the Cloud Function (service account) can write.
- Temp files used during M4A conversion (`.transcribe_temp/`) are not user-accessible.

## Language and limits

- Transcription is configured for **English (en-US)**. To change, edit `languageCode` in `functions/index.js`.
- Long files (> ~10 MB) use **long-running recognition** (up to ~9 minutes). Shorter files use synchronous recognition.
- Function timeout is 540 seconds (9 minutes); increase in Firebase Console if needed.
