/**
 * Google Calendar OAuth (refresh token) for server-side use.
 * Tokens live in Firestore at users/{uid}/private/google_calendar (client cannot read).
 * Status for the app UI: users/{uid}/integrations/calendar
 */

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

const PRIVATE_DOC = "google_calendar";
const INTEGRATIONS_DOC = "calendar";

/**
 * Exchange server auth code (from mobile Google Sign-In) for tokens.
 */
async function exchangeServerAuthCode({ code, clientId, clientSecret }) {
  const body = new URLSearchParams({
    code,
    client_id: clientId,
    client_secret: clientSecret,
    grant_type: "authorization_code",
  });

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const json = await res.json();
  if (!res.ok) {
    const msg = json.error_description || json.error || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return json;
}

/**
 * Refresh access token using stored refresh_token.
 */
async function refreshAccessToken({ refreshToken, clientId, clientSecret }) {
  const body = new URLSearchParams({
    refresh_token: refreshToken,
    client_id: clientId,
    client_secret: clientSecret,
    grant_type: "refresh_token",
  });
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const json = await res.json();
  if (!res.ok) {
    const msg = json.error_description || json.error || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return json;
}

async function fetchGoogleUserEmail(accessToken) {
  try {
    const res = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) return null;
    const data = await res.json();
    return data.email || null;
  } catch (_) {
    return null;
  }
}

/**
 * Save tokens after code exchange. Keeps existing refresh_token if Google omits it on re-consent.
 */
async function persistTokensAfterCodeExchange(uid, tokenJson) {
  const firestore = getFirestore();
  const privateRef = firestore
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc(PRIVATE_DOC);

  const snap = await privateRef.get();
  const existing = snap.exists ? snap.data() : {};
  const refreshToken = tokenJson.refresh_token || existing.refreshToken || null;

  if (!refreshToken) {
    throw new Error(
      "No refresh token received. In Google Account settings, remove app access for this project, then connect again."
    );
  }

  const accessToken = tokenJson.access_token;
  const expiresIn = Number(tokenJson.expires_in || 3600);
  const expiresAt = new Date(Date.now() + expiresIn * 1000);

  await privateRef.set(
    {
      refreshToken,
      accessToken: accessToken || existing.accessToken,
      accessTokenExpiresAt: accessToken ? expiresAt : existing.accessTokenExpiresAt,
      scope: tokenJson.scope || existing.scope || "",
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  const email = accessToken ? await fetchGoogleUserEmail(accessToken) : existing.calendarEmail || null;

  await firestore
    .collection("users")
    .doc(uid)
    .collection("integrations")
    .doc(INTEGRATIONS_DOC)
    .set(
      {
        connected: true,
        calendarEmail: email || null,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  if (email) {
    await privateRef.set({ calendarEmail: email }, { merge: true });
  }

  return { connected: true, calendarEmail: email };
}

/**
 * For use by other Cloud Functions: returns a valid access token (refreshes if needed).
 * @param {string} uid Firebase Auth uid
 * @param {{ clientId: string, clientSecret: string }} oauth
 * @returns {Promise<{ accessToken: string, scope: string }>}
 */
async function getValidCalendarAccessToken(uid, { clientId, clientSecret }) {
  const firestore = getFirestore();
  const privateRef = firestore
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc(PRIVATE_DOC);

  const snap = await privateRef.get();
  if (!snap.exists) {
    throw new Error("Google Calendar not connected for this user.");
  }
  const data = snap.data();
  const refreshToken = data.refreshToken;
  if (!refreshToken) {
    throw new Error("Missing refresh token; user must reconnect Google Calendar.");
  }

  let accessToken = data.accessToken;
  let expiresAt = data.accessTokenExpiresAt?.toDate?.() || null;
  const bufferMs = 120 * 1000;
  const needsRefresh =
    !accessToken ||
    !expiresAt ||
    expiresAt.getTime() < Date.now() + bufferMs;

  if (needsRefresh) {
    const refreshed = await refreshAccessToken({
      refreshToken,
      clientId,
      clientSecret,
    });
    accessToken = refreshed.access_token;
    const expiresIn = Number(refreshed.expires_in || 3600);
    const newExpiresAt = new Date(Date.now() + expiresIn * 1000);
    await privateRef.set(
      {
        accessToken,
        accessTokenExpiresAt: newExpiresAt,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  return {
    accessToken,
    scope: data.scope || "",
  };
}

async function disconnectCalendar(uid) {
  const firestore = getFirestore();
  await firestore
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc(PRIVATE_DOC)
    .delete()
    .catch(() => {});

  await firestore
    .collection("users")
    .doc(uid)
    .collection("integrations")
    .doc(INTEGRATIONS_DOC)
    .set(
      {
        connected: false,
        calendarEmail: null,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
}

module.exports = {
  exchangeServerAuthCode,
  persistTokensAfterCodeExchange,
  getValidCalendarAccessToken,
  disconnectCalendar,
  GOOGLE_CALENDAR_SCOPE: "https://www.googleapis.com/auth/calendar",
};
