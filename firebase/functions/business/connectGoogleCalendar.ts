import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import type { Firestore } from "firebase-admin/firestore";
import type {
  ConnectGoogleCalendarRequest,
  ConnectGoogleCalendarResponse,
  GoogleOAuthTokenResponse,
  GoogleOAuthErrorResponse,
  GoogleCalendarTokenDoc,
  GoogleCalendarTokenStatusDoc,
} from "../shared/types";

interface ConnectGoogleCalendarContext {
  uid: string;
  firestore: Firestore;
  googleOAuthWebClientId: string;
  googleOAuthClientSecret: string;
  logger: { log: (msg: string, obj?: object) => void; error: (msg: string, obj?: object) => void };
}

export async function connectGoogleCalendarBusiness(
  data: Partial<ConnectGoogleCalendarRequest> | undefined,
  ctx: ConnectGoogleCalendarContext
): Promise<ConnectGoogleCalendarResponse> {
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
    const tokenJson = (await tokenRes.json()) as GoogleOAuthTokenResponse | GoogleOAuthErrorResponse;
    if (!tokenRes.ok) {
      const err = tokenJson as GoogleOAuthErrorResponse;
      const msg = err.error_description || err.error || `HTTP ${tokenRes.status}`;
      throw new Error(msg);
    }

    const ok = tokenJson as GoogleOAuthTokenResponse;
    const refreshToken = ok.refresh_token;
    if (!refreshToken) {
      throw new Error(
        "No refresh token received. Revoke app access in Google Account and connect again."
      );
    }

    const tokenDoc: GoogleCalendarTokenDoc = {
      type: "Google Calendar",
      token: refreshToken,
      createdAt: FieldValue.serverTimestamp(),
      expired: false,
    };
    await firestore
      .collection("users")
      .doc(uid)
      .collection("tokens")
      .doc("google_calendar")
      .set(tokenDoc);

    const statusDoc: GoogleCalendarTokenStatusDoc = {
      type: "Google Calendar",
      status: "connected",
      expired: false,
      updatedAt: FieldValue.serverTimestamp(),
    };
    await firestore
      .collection("users")
      .doc(uid)
      .collection("tokens-last-status")
      .doc("google_calendar")
      .set(statusDoc);

    logger.log("connectGoogleCalendar: token stored", { uid });
    return { ok: true };
  } catch (err) {
    const e = err as Error;
    logger.error("connectGoogleCalendar: failed", { error: e?.message });
    throw new HttpsError("internal", e?.message || "Failed to store Calendar token.");
  }
}
