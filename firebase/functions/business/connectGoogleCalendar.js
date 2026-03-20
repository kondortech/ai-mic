"use strict";

const { HttpsError } = require("firebase-functions/v2/https");
const { FieldValue } = require("firebase-admin/firestore");

/**
 * @typedef {import('../generated/api.types').components['schemas']['ConnectGoogleCalendarRequest']} ConnectGoogleCalendarRequest
 * @typedef {import('../generated/api.types').components['schemas']['ConnectGoogleCalendarResponse']} ConnectGoogleCalendarResponse
 */

/**
 * Exchange server auth code for refresh token and store under users/{uid}/tokens/google_calendar.
 * @param {ConnectGoogleCalendarRequest} data
 * @param {{
 *   uid: string,
 *   firestore: import('firebase-admin/firestore').Firestore,
 *   googleOAuthWebClientId: string,
 *   googleOAuthClientSecret: string,
 *   logger: import('firebase-functions/logger'),
 * }} ctx
 * @returns {Promise<ConnectGoogleCalendarResponse>}
 */
async function connectGoogleCalendarBusiness(data, ctx) {
  const { uid, firestore, googleOAuthWebClientId, googleOAuthClientSecret, logger } = ctx;

  const serverAuthCode = data?.serverAuthCode;
  if (!serverAuthCode || typeof serverAuthCode !== "string") {
    throw new HttpsError("invalid-argument", "Missing serverAuthCode.");
  }

  const clientId = googleOAuthWebClientId.trim();
  const clientSecret = googleOAuthClientSecret;
  if (!clientId || !clientSecret) {
    throw new HttpsError(
      "failed-precondition",
      "Set GOOGLE_OAUTH_WEB_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET."
    );
  }

  try {
    const body = new URLSearchParams({
      code: serverAuthCode,
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "authorization_code",
    });

    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    const tokenJson = await tokenRes.json();
    if (!tokenRes.ok) {
      const msg = tokenJson.error_description || tokenJson.error || `HTTP ${tokenRes.status}`;
      throw new Error(msg);
    }

    const refreshToken = tokenJson.refresh_token;
    if (!refreshToken) {
      throw new Error(
        "No refresh token received. Revoke app access in Google Account and connect again."
      );
    }

    await firestore
      .collection("users")
      .doc(uid)
      .collection("tokens")
      .doc("google_calendar")
      .set({
        type: "Google Calendar",
        token: refreshToken,
        createdAt: FieldValue.serverTimestamp(),
        expired: false,
      });

    await firestore
      .collection("users")
      .doc(uid)
      .collection("tokens-last-status")
      .doc("google_calendar")
      .set({
        type: "Google Calendar",
        status: "connected",
        expired: false,
        updatedAt: FieldValue.serverTimestamp(),
      });

    logger.log("connectGoogleCalendar: token stored", { uid });
    return { ok: true };
  } catch (err) {
    logger.error("connectGoogleCalendar: failed", { error: err?.message });
    throw new HttpsError("internal", err?.message || "Failed to store Calendar token.");
  }
}

module.exports = { connectGoogleCalendarBusiness };
