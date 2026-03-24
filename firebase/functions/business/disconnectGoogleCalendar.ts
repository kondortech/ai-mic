import { FieldValue } from "firebase-admin/firestore";
import type { Firestore } from "firebase-admin/firestore";

import type { DisconnectGoogleCalendarRequest, DisconnectGoogleCalendarResponse } from "../shared/types";

interface DisconnectGoogleCalendarContext {
  uid: string;
  firestore: Firestore;
}

export async function disconnectGoogleCalendarBusiness(
  _data: DisconnectGoogleCalendarRequest | undefined,
  ctx: DisconnectGoogleCalendarContext
): Promise<DisconnectGoogleCalendarResponse> {
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
