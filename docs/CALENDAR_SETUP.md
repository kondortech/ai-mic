# Google Calendar + Cloud Functions (refresh token)

The app connects Calendar by sending a **server auth code** from Google Sign-In to the callable **`connectGoogleCalendar`**, which exchanges it for **access + refresh tokens** and stores them in Firestore for future server use.

## Data layout (Firestore)

| Path | Who reads/writes | Contents |
|------|------------------|----------|
| `users/{uid}/private/google_calendar` | **Only Admin SDK** (Cloud Functions) | `refreshToken`, cached `accessToken`, expiry, scope |
| `users/{uid}/integrations/calendar` | Client **read only** | `connected`, `calendarEmail`, `updatedAt` |

Security rules deny all client access to `users/{uid}/private/**`.

## 1. Google Cloud Console

1. Enable **Google Calendar API**: [API Library](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com) → Enable.
2. **OAuth consent screen** → add scope `https://www.googleapis.com/auth/calendar` (or a narrower scope if you change code later).
3. **Credentials** → OAuth 2.0 Client IDs:
   - **Web application** (the same client you use as `kGoogleSignInWebClientId` in Flutter).
   - Copy **Client ID** and **Client secret**.

## 2. Flutter app

Set **`lib/config/google_sign_in_config.dart`**:

```dart
const String kGoogleSignInWebClientId = 'YOUR_WEB_CLIENT_ID.apps.googleusercontent.com';
```

Required for both Google Sign-In and Calendar connect (server auth code).

## 3. Cloud Functions secrets & config

**Client secret** (sensitive):

```bash
cd functions
firebase functions:secrets:set GOOGLE_OAUTH_CLIENT_SECRET
# paste the Web client secret when prompted
```

**Web client ID** (same string as Flutter, not highly secret but kept server-side):

- Create `functions/.env` (do not commit; add `functions/.env` to `.gitignore` if needed):

```env
GOOGLE_OAUTH_WEB_CLIENT_ID=YOUR_WEB_CLIENT_ID.apps.googleusercontent.com
```

Or set the parameter when Firebase CLI prompts during deploy.

## 4. Deploy

```bash
firebase deploy --only functions:connectGoogleCalendar,functions:disconnectGoogleCalendar,firestore:rules
```

## 5. User flow

1. User opens **Profile** → **Connect Calendar**.
2. Google account picker + consent.
3. App calls `connectGoogleCalendar` with `serverAuthCode`.
4. Profile shows **Connected** when `integrations/calendar` updates.

### No refresh token?

Google may omit `refresh_token` if the user already granted access. User should open [Google Account → Third-party access](https://myaccount.google.com/permissions), remove your app, then connect again. The app uses `forceCodeForRefreshToken: true` on Android to improve this.

## 6. Using Calendar from another Cloud Function

In `functions/`, require the helper:

```js
const {
  getValidCalendarAccessToken,
} = require("./google_calendar");
const { defineSecret, defineString } = require("firebase-functions/params");

const googleOAuthWebClientId = defineString("GOOGLE_OAUTH_WEB_CLIENT_ID");
const googleOAuthClientSecret = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");

// Inside your onCall / trigger (with secrets: [googleOAuthClientSecret]):
const { accessToken } = await getValidCalendarAccessToken(uid, {
  clientId: googleOAuthWebClientId.value().trim(),
  clientSecret: googleOAuthClientSecret.value(),
});
// Then call Calendar API with Authorization: Bearer ${accessToken}
```

Add `googleapis` if you want a typed client:

```bash
cd functions && npm install googleapis
```

## 7. Integration test with mock data

There is an integration-style test that seeds Firestore with mock Calendar docs in the exact production paths/shape:

- `users/{uid}/private/google_calendar`
- `users/{uid}/integrations/calendar`

Test file:

- `functions/test/calendar.integration.test.js`

Run it against Firestore Emulator:

```bash
firebase emulators:exec --only firestore "cd functions && npm run test:calendar"
```

### Prerequisite: JDK 21+
Recent versions of the Firebase CLI require **Java 21+** to run the local emulators.

Check your current Java:

```bash
java -version
```

If it’s below 21, install JDK 21 and point `JAVA_HOME` to it (macOS example):

```bash
brew install openjdk@21
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
export PATH="$JAVA_HOME/bin:$PATH"
java -version
```

Then re-run the test command above.

What it verifies:

- mock insertion path + schema format
- `persistTokensAfterCodeExchange` writes connected state
- `getValidCalendarAccessToken` reads valid cached token
- `disconnectCalendar` removes private token doc and marks integration disconnected
