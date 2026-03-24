/**
 * Central type definitions for JSON marshalling/unmarshalling and API contracts.
 * API request/response schemas are re-exported from generated/api.types.
 */

import type { FieldValue } from "firebase-admin/firestore";
import type { components } from "../generated/api.types";

// =============================================================================
// API Schemas (from OpenAPI / generated)
// =============================================================================

export type TranscribeRecordingRequest = components["schemas"]["TranscribeRecordingRequest"];
export type TranscribeRecordingResponse = components["schemas"]["TranscribeRecordingResponse"];
export type ConnectGoogleCalendarRequest = components["schemas"]["ConnectGoogleCalendarRequest"];
export type ConnectGoogleCalendarResponse = components["schemas"]["ConnectGoogleCalendarResponse"];
export type DisconnectGoogleCalendarRequest = components["schemas"]["DisconnectGoogleCalendarRequest"];
export type DisconnectGoogleCalendarResponse = components["schemas"]["DisconnectGoogleCalendarResponse"];
export type OverwriteExecutionPlanRequest = components["schemas"]["OverwriteExecutionPlanRequest"];
export type OverwriteExecutionPlanResponse = components["schemas"]["OverwriteExecutionPlanResponse"];
export type ExecuteStoredPlanRequest = components["schemas"]["ExecuteStoredPlanRequest"];
export type ExecuteStoredPlanResponse = components["schemas"]["ExecuteStoredPlanResponse"];
export type ExecutionPlan = components["schemas"]["ExecutionPlan"];
export type PlanAction = components["schemas"]["PlanAction"];
export type CreateNotePlanAction = components["schemas"]["CreateNotePlanAction"];
export type CreateCalendarEventPlanAction = components["schemas"]["CreateCalendarEventPlanAction"];
export type CreateNoteArguments = components["schemas"]["CreateNoteArguments"];
export type CreateCalendarEventArguments = components["schemas"]["CreateCalendarEventArguments"];
export type CalendarTimezoneEnum = components["schemas"]["CalendarTimezoneEnum"];
export type ExecutionResult = components["schemas"]["ExecutionResult"];

/** Valid timezone values for calendar events. "local" = user's local timezone. */
export const CALENDAR_TIMEZONE_VALUES: CalendarTimezoneEnum[] = [
  "local",
  "UTC",
  "America/New_York",
  "America/Los_Angeles",
  "America/Chicago",
  "America/Denver",
  "Europe/London",
  "Europe/Paris",
  "Europe/Berlin",
  "Asia/Tokyo",
  "Asia/Shanghai",
  "Asia/Singapore",
  "Australia/Sydney",
  "Australia/Melbourne",
  "Pacific/Auckland",
];

// =============================================================================
// Stored plan.json (Storage) - same shape as ExecutionPlan
// =============================================================================

export type StoredPlan = ExecutionPlan;

// =============================================================================
// Google OAuth 2.0 API responses (JSON from token endpoint)
// =============================================================================

/** Success response from POST https://oauth2.googleapis.com/token (authorization_code) */
export interface GoogleOAuthTokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  token_type?: string;
  scope?: string;
}

/** Error response from Google OAuth token endpoint */
export interface GoogleOAuthErrorResponse {
  error?: string;
  error_description?: string;
}

export type GoogleOAuthTokenApiResponse = GoogleOAuthTokenResponse | GoogleOAuthErrorResponse;

// =============================================================================
// Google Calendar API (JSON request/response)
// =============================================================================

/** Request body for POST calendar/v3/calendars/primary/events */
export interface GoogleCalendarEventRequestBody {
  summary: string;
  description: string;
  start: { dateTime: string; timeZone: string };
  end: { dateTime: string; timeZone: string };
}

/** Success response from Calendar API event create */
export interface GoogleCalendarEventResponse {
  id?: string;
  summary?: string;
  // ... other fields we don't use
}

/** Error response from Google Calendar API */
export interface GoogleCalendarApiError {
  error?: { message?: string; code?: number };
}

// =============================================================================
// Firestore document shapes (what we write to Firestore)
// =============================================================================

export interface InputRef {
  uuid: string;
  index: number;
}

/** users/{uid}/tokens/google_calendar */
export interface GoogleCalendarTokenDoc {
  type: "Google Calendar";
  token: string;
  createdAt: FieldValue;
  expired: boolean;
}

/** users/{uid}/tokens-last-status/google_calendar */
export interface GoogleCalendarTokenStatusDoc {
  type: "Google Calendar";
  status: "connected" | "not connected";
  expired: boolean;
  updatedAt: FieldValue;
}

/** users/{uid}/inputs/{inputId} - partial update fields */
export interface InputDocUpdate {
  status?: "transcribed" | "plan_created" | "no_plan_created" | "plan_executed";
  languageCode?: string;
  updatedAt: FieldValue;
}

/** users/{uid}/notes/{noteId} */
export interface NoteDoc {
  title: string;
  text: string;
  input_ref: InputRef;
  created_at: FieldValue;
}

/** users/{uid}/calendar-events/{eventId} */
export interface CalendarEventDoc {
  event_title: string;
  event_description: string;
  event_start_timestamp: string;
  event_end_timestamp: string;
  timezone: string;
  input_ref: InputRef;
  created_at: FieldValue;
  google_event_id: string | null;
}

/** users/{uid}/tokens/google_calendar - minimal for read (token can be expired) */
export interface GoogleCalendarTokenDocRead {
  type?: string;
  token?: string;
  expired?: boolean;
}

// =============================================================================
// LLM plan response (raw JSON from Genkit/Gemini - before sanitization)
// =============================================================================

/** Raw parsed JSON from LLM - arguments may be unknown types until sanitized */
export interface LlmPlanActionRaw {
  tool?: unknown;
  arguments?: Record<string, unknown>;
}

export interface LlmPlanResponseRaw {
  actions?: unknown[];
  empty_reason?: string | null;
}

// =============================================================================
// JSON parse helpers (typed unmarshalling)
// =============================================================================

/** Safely parse JSON string to unknown. Use with type guards or validation. */
export function parseJsonSafe(text: string): unknown {
  return JSON.parse(text) as unknown;
}

/** Parse plan.json from storage - returns raw unknown; caller must sanitize. */
export function parsePlanJsonFromString(content: string): unknown {
  return parseJsonSafe(content);
}

/** Type guard: is value a non-null object with optional actions array */
export function isPlanLike(value: unknown): value is { actions?: unknown[]; empty_reason?: unknown } {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

/** Type guard: is value a PlanAction-like object */
export function isPlanActionLike(value: unknown): value is { tool?: unknown; arguments?: Record<string, unknown> } {
  return value != null && typeof value === "object" && !Array.isArray(value);
}
