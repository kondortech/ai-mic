import { FieldValue } from "firebase-admin/firestore";
import type { Firestore } from "firebase-admin/firestore";
import type {
  ExecutionResult,
  GoogleCalendarEventRequestBody,
  GoogleCalendarEventResponse,
  GoogleCalendarApiError,
  GoogleOAuthTokenResponse,
  GoogleOAuthErrorResponse,
  PlanAction,
  CalendarEventDoc,
  NoteDoc,
  InputRef,
  GoogleCalendarTokenDocRead,
} from "./types";

interface RefreshTokenParams {
  refreshToken: string;
  clientId: string;
  clientSecret: string;
}

export async function refreshGoogleAccessToken({ refreshToken, clientId, clientSecret }: RefreshTokenParams): Promise<string> {
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
  const json = (await res.json()) as GoogleOAuthTokenResponse | GoogleOAuthErrorResponse;
  if (!res.ok) {
    const err = json as GoogleOAuthErrorResponse;
    const msg = err.error_description || err.error || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  const ok = json as GoogleOAuthTokenResponse;
  if (!ok.access_token) throw new Error("No access token returned.");
  return ok.access_token;
}

interface SyncCalendarEventParams {
  accessToken: string;
  title: string;
  description: string;
  startTime: string;
  finishTime: string;
}

export async function syncCalendarEventToGoogle({
  accessToken,
  title,
  description,
  startTime,
  finishTime,
}: SyncCalendarEventParams): Promise<GoogleCalendarEventResponse> {
  const timezone = "UTC";
  const body: GoogleCalendarEventRequestBody = {
    summary: title,
    description: description || "",
    start: { dateTime: startTime, timeZone: timezone },
    end: { dateTime: finishTime, timeZone: timezone },
  };
  const res = await fetch("https://www.googleapis.com/calendar/v3/calendars/primary/events", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as GoogleCalendarEventResponse | GoogleCalendarApiError;
  if (!res.ok) {
    const err = json as GoogleCalendarApiError;
    const msg = err.error?.message || `Calendar HTTP ${res.status}`;
    throw new Error(msg);
  }
  return json as GoogleCalendarEventResponse;
}

interface ExecutePlanActionsParams {
  firestore: Firestore;
  uid: string;
  inputUuid: string;
  actions: PlanAction[];
  oauthClientId: string;
  oauthClientSecret: string;
}

export type { ExecutionResult } from "./types";

export async function executePlanActions({
  firestore,
  uid,
  inputUuid,
  actions,
  oauthClientId,
  oauthClientSecret,
}: ExecutePlanActionsParams): Promise<ExecutionResult[]> {
  const results: ExecutionResult[] = [];
  for (let i = 0; i < actions.length; i++) {
    const action = actions[i];
    const tool = action.tool;
    const inputRef: InputRef = { uuid: inputUuid, index: i };
    try {
      if (tool === "create_note") {
        const args = action.arguments;
        const noteRef = firestore.collection("users").doc(uid).collection("notes").doc();
        const noteDoc: NoteDoc = {
          title: String(args?.title || "").trim(),
          text: String(args?.text || "").trim(),
          input_ref: inputRef,
          created_at: FieldValue.serverTimestamp(),
        };
        await noteRef.set(noteDoc);
        results.push({ tool, ok: true, details: `created users/${uid}/notes/${noteRef.id}` });
        continue;
      }

      if (tool === "create_calendar_event") {
        const args = action.arguments;
        const title = String(args?.title || "").trim();
        const description = String(args?.description || "").trim();
        const startTime = String(args?.start_time || "").trim();
        const finishTime = String(args?.finish_time || "").trim();
        // "local" = user's timezone (unknown server-side) → fallback to UTC; otherwise use IANA
        const tz = args?.timezone === "local" ? "UTC" : String(args?.timezone || "UTC").trim();
        const timezone = tz || "UTC";
        if (!title || !startTime || !finishTime) {
          throw new Error("Missing title/start_time/finish_time for calendar event.");
        }
        const tokenSnap = await firestore
          .collection("users")
          .doc(uid)
          .collection("tokens")
          .doc("google_calendar")
          .get();
        const tokenData = tokenSnap.data() as GoogleCalendarTokenDocRead | undefined;
        const refreshToken = tokenData?.token;
        if (!refreshToken) {
          throw new Error("Google Calendar refresh token not found.");
        }
        const accessToken = await refreshGoogleAccessToken({
          refreshToken,
          clientId: oauthClientId,
          clientSecret: oauthClientSecret,
        });
        const googleEvent = await syncCalendarEventToGoogle({
          accessToken,
          title,
          description,
          startTime,
          finishTime,
        });
        const eventRef = firestore.collection("users").doc(uid).collection("calendar-events").doc();
        const eventDoc: CalendarEventDoc = {
          event_title: title,
          event_description: description,
          event_start_timestamp: startTime,
          event_end_timestamp: finishTime,
          timezone,
          input_ref: inputRef,
          created_at: FieldValue.serverTimestamp(),
          google_event_id: googleEvent?.id ?? null,
        };
        await eventRef.set(eventDoc);
        results.push({
          tool,
          ok: true,
          details: `created users/${uid}/calendar-events/${eventRef.id}`,
        });
        continue;
      }

      results.push({ tool, ok: false, details: "unsupported tool" });
    } catch (e) {
      const err = e as Error;
      results.push({
        tool,
        ok: false,
        details: err?.message || String(e),
      });
    }
  }
  return results;
}
