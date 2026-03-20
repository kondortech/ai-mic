"use strict";

const { FieldValue } = require("firebase-admin/firestore");

async function refreshGoogleAccessToken({ refreshToken, clientId, clientSecret }) {
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
  if (!json.access_token) throw new Error("No access token returned.");
  return json.access_token;
}

async function syncCalendarEventToGoogle({
  accessToken,
  title,
  description,
  startTime,
  finishTime,
}) {
  const timezone = "UTC";
  const body = {
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
  const json = await res.json();
  if (!res.ok) {
    const msg = json?.error?.message || `Calendar HTTP ${res.status}`;
    throw new Error(msg);
  }
  return json;
}

async function executePlanActions({
  firestore,
  uid,
  inputUuid,
  actions,
  oauthClientId,
  oauthClientSecret,
}) {
  const results = [];
  for (const action of actions) {
    const tool = action.tool;
    const args = action.arguments || {};
    try {
      if (tool === "create_note") {
        const noteRef = firestore.collection("users").doc(uid).collection("notes").doc();
        await noteRef.set({
          title: String(args.title || "").trim(),
          text: String(args.text || "").trim(),
          input_uuid: inputUuid,
          created_at: FieldValue.serverTimestamp(),
        });
        results.push({ tool, ok: true, details: `created users/${uid}/notes/${noteRef.id}` });
        continue;
      }

      if (tool === "create_calendar_event") {
        const title = String(args.title || "").trim();
        const description = String(args.description || "").trim();
        const startTime = String(args.start_time || "").trim();
        const finishTime = String(args.finish_time || "").trim();
        const timezone = "UTC";
        if (!title || !startTime || !finishTime) {
          throw new Error("Missing title/start_time/finish_time for calendar event.");
        }
        const tokenSnap = await firestore
          .collection("users")
          .doc(uid)
          .collection("tokens")
          .doc("google_calendar")
          .get();
        const refreshToken = tokenSnap.data()?.token;
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
        await eventRef.set({
          event_title: title,
          event_description: description,
          event_start_timestamp: startTime,
          event_end_timestamp: finishTime,
          timezone,
          input_uuid: inputUuid,
          created_at: FieldValue.serverTimestamp(),
          google_event_id: googleEvent?.id || null,
        });
        results.push({
          tool,
          ok: true,
          details: `created users/${uid}/calendar-events/${eventRef.id}`,
        });
        continue;
      }

      results.push({ tool, ok: false, details: "unsupported tool" });
    } catch (e) {
      results.push({
        tool,
        ok: false,
        details: e?.message || String(e),
      });
    }
  }
  return results;
}

module.exports = {
  refreshGoogleAccessToken,
  syncCalendarEventToGoogle,
  executePlanActions,
};
