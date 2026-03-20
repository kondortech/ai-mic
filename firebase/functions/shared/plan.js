"use strict";

const { HttpsError } = require("firebase-functions/v2/https");
const { buildPlanWithGemini } = require("./genkit");
const {
  INPUTS_SEGMENT,
  PLAN_FILENAME,
} = require("./constants");

async function buildAndSavePlanOnly({
  bucket,
  uid,
  inputUuid,
  transcriptText,
  geminiKey,
  geminiModelName,
}) {
  const plan = await buildPlanWithGemini({
    transcriptText,
    nowIso: new Date().toISOString(),
    apiKey: geminiKey,
    modelName: geminiModelName,
  });
  const structuredPlan = {
    actions: plan.actions || [],
    empty_reason: plan.empty_reason ?? null,
    generated_at: new Date().toISOString(),
  };
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  await bucket.file(planPath).save(JSON.stringify(structuredPlan, null, 2), {
    metadata: { contentType: "application/json; charset=utf-8" },
  });
  return { planPath, actionsCount: structuredPlan.actions.length };
}

function sanitizePlan(rawPlan) {
  if (!rawPlan || typeof rawPlan !== "object") {
    throw new HttpsError("invalid-argument", "Plan must be an object.");
  }
  const actionsRaw = rawPlan.actions;
  const emptyReasonRaw = rawPlan.empty_reason;
  if (!Array.isArray(actionsRaw)) {
    throw new HttpsError("invalid-argument", "Plan.actions must be an array.");
  }

  const actions = actionsRaw
    .filter((a) => a && typeof a === "object")
    .map((a) => {
      const tool = String(a.tool || "").trim();
      const args = a.arguments && typeof a.arguments === "object" ? a.arguments : {};
      return {
        tool,
        arguments: Object.fromEntries(
          Object.entries(args).map(([k, v]) => [String(k), v == null ? "" : String(v)])
        ),
      };
    });

  const emptyReason =
    emptyReasonRaw == null ? null : String(emptyReasonRaw).trim();

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

async function savePlanJson({ bucket, uid, inputUuid, plan }) {
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  await bucket.file(planPath).save(JSON.stringify(plan, null, 2), {
    metadata: { contentType: "application/json; charset=utf-8" },
  });
  return { planPath };
}

async function loadPlanJson({ bucket, uid, inputUuid }) {
  const planPath = `${uid}/${INPUTS_SEGMENT}/${inputUuid}/${PLAN_FILENAME}`;
  const [content] = await bucket.file(planPath).download();
  const json = JSON.parse(content.toString("utf8"));
  const plan = sanitizePlan(json);
  return { plan, planPath };
}

module.exports = {
  buildAndSavePlanOnly,
  sanitizePlan,
  savePlanJson,
  loadPlanJson,
};
