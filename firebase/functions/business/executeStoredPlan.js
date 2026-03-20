"use strict";

const { HttpsError } = require("firebase-functions/v2/https");
const { FieldValue } = require("firebase-admin/firestore");

const { loadPlanJson } = require("../shared/plan");
const { executePlanActions } = require("../shared/calendar");

/**
 * @typedef {import('../generated/api.types').components['schemas']['ExecuteStoredPlanRequest']} ExecuteStoredPlanRequest
 * @typedef {import('../generated/api.types').components['schemas']['ExecuteStoredPlanResponse']} ExecuteStoredPlanResponse
 */

/**
 * Load and execute the plan for an input.
 * @param {ExecuteStoredPlanRequest} data
 * @param {{
 *   uid: string,
 *   bucket: import('@google-cloud/storage').Bucket,
 *   firestore: import('firebase-admin/firestore').Firestore,
 *   googleOAuthWebClientId: string,
 *   googleOAuthClientSecret: string,
 *   logger: import('firebase-functions/logger'),
 * }} ctx
 * @returns {Promise<ExecuteStoredPlanResponse>}
 */
async function executeStoredPlanBusiness(data, ctx) {
  const { uid, bucket, firestore, googleOAuthWebClientId, googleOAuthClientSecret, logger } = ctx;

  const inputUuid = String(data?.inputUuid || "").trim();
  if (!inputUuid) {
    throw new HttpsError("invalid-argument", "Missing inputUuid.");
  }

  let plan;
  try {
    const loaded = await loadPlanJson({ bucket, uid, inputUuid });
    plan = loaded.plan;
  } catch (e) {
    throw new HttpsError("failed-precondition", `Cannot read plan.json: ${e?.message || e}`);
  }

  logger.info("executeStoredPlan called", {
    uid,
    inputUuid: data?.inputUuid ?? null,
  });

  if (!Array.isArray(plan.actions) || plan.actions.length === 0) {
    return {
      ok: true,
      executed: false,
      reason: plan.empty_reason || "Plan has no actions.",
      results: [],
    };
  }

  const clientId = googleOAuthWebClientId.trim();
  const clientSecret = googleOAuthClientSecret;
  const results = await executePlanActions({
    firestore,
    uid,
    inputUuid,
    actions: plan.actions,
    oauthClientId: clientId,
    oauthClientSecret: clientSecret,
  });

  logger.info("executeStoredPlan results", {
    uid,
    inputUuid: data?.inputUuid ?? null,
    results,
  });

  await firestore
    .collection("users")
    .doc(uid)
    .collection("inputs")
    .doc(inputUuid)
    .set(
      { status: "plan_executed", updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );

  return {
    ok: true,
    executed: true,
    results,
  };
}

module.exports = { executeStoredPlanBusiness };
