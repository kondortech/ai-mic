"use strict";

const { FieldValue } = require("firebase-admin/firestore");

/**
 * @typedef {import('../generated/api.types').components['schemas']['DisconnectGoogleCalendarRequest']} DisconnectGoogleCalendarRequest
 * @typedef {import('../generated/api.types').components['schemas']['DisconnectGoogleCalendarResponse']} DisconnectGoogleCalendarResponse
 */

/**
 * Mark Calendar token as disconnected and update status doc.
 * @param {DisconnectGoogleCalendarRequest} _data
 * @param {{
 *   uid: string,
 *   firestore: import('firebase-admin/firestore').Firestore,
 * }} ctx
 * @returns {Promise<DisconnectGoogleCalendarResponse>}
 */
async function disconnectGoogleCalendarBusiness(_data, ctx) {
  const { uid, firestore } = ctx;

  await firestore
    .collection("users")
    .doc(uid)
    .collection("tokens")
    .doc("google_calendar")
    .set(
      {
        type: "Google Calendar",
        expired: true,
      },
      { merge: true }
    );

  await firestore
    .collection("users")
    .doc(uid)
    .collection("tokens-last-status")
    .doc("google_calendar")
    .set(
      {
        type: "Google Calendar",
        status: "not connected",
        expired: true,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  return { ok: true };
}

module.exports = { disconnectGoogleCalendarBusiness };
