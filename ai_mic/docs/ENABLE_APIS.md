# APIs and billing required for the transcription function

For the **transcribeRecording** Cloud Function to work, the following must be enabled in the **same Google Cloud project** that backs your Firebase project (e.g. **ai-mic-18768**).

## 1. Enable Cloud Speech-to-Text API (required)

The function uses Google Cloud Speech-to-Text to transcribe audio. This API must be enabled.

**Steps:**

1. Open [Google Cloud Console](https://console.cloud.google.com/).
2. Select your project (same as your Firebase project, e.g. **ai-mic-18768**).
3. In the left menu go to **APIs & Services** → **Library** (or open [API Library](https://console.cloud.google.com/apis/library)).
4. Search for **“Cloud Speech-to-Text API”**.
5. Open it and click **Enable**.

Direct link (replace `YOUR_PROJECT_ID` with your project ID, e.g. `ai-mic-18768`):

**https://console.cloud.google.com/apis/library/speech.googleapis.com?project=YOUR_PROJECT_ID**

---

## 2. Blaze (pay-as-you-go) plan

- Cloud Functions that call paid APIs (like Speech-to-Text) or run longer need the **Blaze** plan.
- In [Firebase Console](https://console.firebase.google.com/) → your project → **Usage and billing** → upgrade to **Blaze** if you’re still on Spark.
- You only pay for what you use; free tiers still apply (e.g. Speech-to-Text has a free quota per month).

---

## 3. Other APIs (usually already enabled)

These are typically enabled when you use Firebase; if something fails, check that they’re enabled in [API Library](https://console.cloud.google.com/apis/library):

| API | Used for |
|-----|----------|
| **Cloud Functions API** | Deploying and running functions |
| **Cloud Build API** | Building function code on deploy |
| **Cloud Storage API** | Reading/writing Storage (recordings, transcripts) |
| **Cloud Firestore API** | Updating `status: 'transcribed'` in Firestore |

If deploy or runtime errors mention a specific API, enable that API in the same project.

---

## 4. Quick checklist

- [ ] **Cloud Speech-to-Text API** enabled (see step 1).
- [ ] Project is on **Blaze** (see step 2).
- [ ] Function deployed: `firebase deploy --only functions`.

After enabling Speech-to-Text and being on Blaze, redeploy is not required; the next invocation of the function will use the API. If you still see “API not enabled” or 403 errors, check the exact error in Firebase Functions logs and enable the API it names.
