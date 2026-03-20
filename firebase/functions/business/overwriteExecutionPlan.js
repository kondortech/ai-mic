"use strict";

const { HttpsError } = require("firebase-functions/v2/https");
const { sanitizePlan, savePlanJson } = require("../shared/plan");

/**
 * @typedef {import('../generated/api.types').components['schemas']['OverwriteExecutionPlanRequest']} OverwriteExecutionPlanRequest
 * @typedef {import('../generated/api.types').components['schemas']['OverwriteExecutionPlanResponse']} OverwriteExecutionPlanResponse
 */

/**
 * Save a custom plan for an input.
 * @param {OverwriteExecutionPlanRequest} data
 * @param {{
 *   uid: string,
 *   bucket: import('@google-cloud/storage').Bucket,
 *   logger: import('firebase-functions/logger'),
 * }} ctx
 * @returns {Promise<OverwriteExecutionPlanResponse>}
 */
async function overwriteExecutionPlanBusiness(data, ctx) {
  const { uid, bucket, logger } = ctx;

  const inputUuid = String(data?.inputUuid || "").trim();
  if (!inputUuid) {
    throw new HttpsError("invalid-argument", "Missing inputUuid.");
  }

  const sanitized = sanitizePlan(data?.plan);

  const saved = await savePlanJson({
    bucket,
    uid,
    inputUuid,
    plan: sanitized,
  });

  logger.info("overwriteExecutionPlan called", {
    uid,
    inputUuid: data?.inputUuid ?? null,
    hasPlan: !!data?.plan,
    actionsCount: Array.isArray(data?.plan?.actions) ? data.plan.actions.length : null,
    planKeys: data?.plan ? Object.keys(data.plan) : [],
  });

  return { ok: true, planPath: saved.planPath, actionsCount: sanitized.actions.length };
}

module.exports = { overwriteExecutionPlanBusiness };
