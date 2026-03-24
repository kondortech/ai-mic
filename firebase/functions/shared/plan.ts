import { HttpsError } from "firebase-functions/v2/https";
import { buildPlanWithGemini } from "./genkit";
import { INPUTS_SEGMENT, PLAN_FILENAME } from "./constants";
import type {
  CalendarTimezoneEnum,
  CreateCalendarEventArguments,
  CreateNoteArguments,
  PlanAction,
  StoredPlan,
} from "./types";
import { CALENDAR_TIMEZONE_VALUES } from "./types";
import { isPlanActionLike, parsePlanJsonFromString } from "./types";

import type { Bucket } from "@google-cloud/storage";

interface BuildAndSavePlanParams {
  bucket: Bucket;
  uid: string;
  inputUuid: string;
  transcriptText: string;
  geminiKey: string;
  geminiModelName: string;
}

const VALID_TOOLS = ["create_note", "create_calendar_event"] as const;
type ValidTool = (typeof VALID_TOOLS)[number];

function isValidTool(s: string): s is ValidTool {
  return VALID_TOOLS.includes(s as ValidTool);
}

/** Normalize raw action to PlanAction (discriminated union). */
function toPlanAction(a: { tool: string; arguments?: Record<string, unknown> }): PlanAction {
  const tool = String(a.tool || "").trim();
  if (!isValidTool(tool)) {
    return { tool: "create_note", arguments: { title: "", text: tool || "(unknown tool)" } };
  }
  const args = a.arguments && typeof a.arguments === "object" ? a.arguments : {};
  const str = (k: string) => String(args[k] ?? "");

  if (tool === "create_note") {
    const arguments_: CreateNoteArguments = { title: str("title"), text: str("text") };
    return { tool: "create_note", arguments: arguments_ };
  }
  const tzRaw = str("timezone") || "local";
  const timezone: CalendarTimezoneEnum = CALENDAR_TIMEZONE_VALUES.includes(tzRaw as CalendarTimezoneEnum)
    ? (tzRaw as CalendarTimezoneEnum)
    : "local";
  const arguments_: CreateCalendarEventArguments = {
    title: str("title"),
    description: str("description"),
    start_time: str("start_time"),
    finish_time: str("finish_time"),
    timezone,
  };
  return { tool: "create_calendar_event", arguments: arguments_ };
}

export async function buildAndSavePlanOnly({
  bucket,
  uid,
  inputUuid,
  transcriptText,
  geminiKey,
  geminiModelName,
}: BuildAndSavePlanParams): Promise<{ planPath: string; actionsCount: number }> {
  const plan = await buildPlanWithGemini({
    transcriptText,
    nowIso: new Date().toISOString(),
    apiKey: geminiKey,
    modelName: geminiModelName,
  });
  const structuredPlan: StoredPlan = {
    actions: (plan.actions || []).map((a) => toPlanAction({ tool: a.tool, arguments: a.arguments })),
    empty_reason: plan.empty_reason ?? null,
    generated_at: new Date().toISOString(),
  };
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  await bucket.file(planPath).save(JSON.stringify(structuredPlan, null, 2), {
    metadata: { contentType: "application/json; charset=utf-8" },
  });
  return { planPath, actionsCount: structuredPlan.actions.length };
}

function sanitizePlan(rawPlan: unknown): StoredPlan {
  if (!rawPlan || typeof rawPlan !== "object" || Array.isArray(rawPlan)) {
    throw new HttpsError("invalid-argument", "Plan must be an object.");
  }
  const planObj = rawPlan as { actions?: unknown[]; empty_reason?: unknown };
  const actionsRaw = planObj.actions;
  const emptyReasonRaw = planObj.empty_reason;
  if (!Array.isArray(actionsRaw)) {
    throw new HttpsError("invalid-argument", "Plan.actions must be an array.");
  }

  const actions: PlanAction[] = actionsRaw
    .filter(isPlanActionLike)
    .map((a) =>
      toPlanAction({
        tool: String(a.tool || "").trim(),
        arguments: a.arguments && typeof a.arguments === "object" ? a.arguments : {},
      })
    );

  const emptyReason = emptyReasonRaw == null ? null : String(emptyReasonRaw).trim();

  if (actions.length === 0 && (!emptyReason || !emptyReason.length)) {
    throw new HttpsError(
      "invalid-argument",
      "Plan with empty actions must include non-empty empty_reason."
    );
  }
  if (actions.length > 0 && emptyReason) {
    throw new HttpsError(
      "invalid-argument",
      "Plan with actions must not include empty_reason."
    );
  }
  return {
    actions,
    empty_reason: actions.length === 0 ? emptyReason : null,
    generated_at: new Date().toISOString(),
  };
}

export async function savePlanJson({
  bucket,
  uid,
  inputUuid,
  plan,
}: {
  bucket: Bucket;
  uid: string;
  inputUuid: string;
  plan: StoredPlan;
}): Promise<{ planPath: string }> {
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  await bucket.file(planPath).save(JSON.stringify(plan, null, 2), {
    metadata: { contentType: "application/json; charset=utf-8" },
  });
  return { planPath };
}

export async function loadPlanJson({
  bucket,
  uid,
  inputUuid,
}: {
  bucket: Bucket;
  uid: string;
  inputUuid: string;
}): Promise<{ plan: StoredPlan; planPath: string }> {
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  const [content] = await bucket.file(planPath).download();
  const json = parsePlanJsonFromString(content.toString("utf8"));
  const plan = sanitizePlan(json);
  return { plan, planPath };
}

export { sanitizePlan };
