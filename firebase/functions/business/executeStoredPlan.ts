import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import type { Bucket } from "@google-cloud/storage";
import type { Firestore } from "firebase-admin/firestore";

import { loadPlanJson } from "../shared/plan";
import { executePlanActions } from "../shared/calendar";
import type {
  ExecuteStoredPlanRequest,
  ExecuteStoredPlanResponse,
  InputDocUpdate,
} from "../shared/types";

interface ExecuteStoredPlanContext {
  uid: string;
  bucket: Bucket;
  firestore: Firestore;
  googleOAuthWebClientId: string;
  googleOAuthClientSecret: string;
  logger: { info: (msg: string, obj?: object) => void };
}

export async function executeStoredPlanBusiness(
  data: Partial<ExecuteStoredPlanRequest> | undefined,
  ctx: ExecuteStoredPlanContext
): Promise<ExecuteStoredPlanResponse> {
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
    const err = e as Error;
    throw new HttpsError("failed-precondition", `Cannot read plan.json: ${err?.message || e}`);
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

  const inputUpdate: InputDocUpdate = {
    status: "plan_executed",
    updatedAt: FieldValue.serverTimestamp(),
  };
  await firestore
    .collection("users")
    .doc(uid)
    .collection("inputs")
    .doc(inputUuid)
    .set(inputUpdate, { merge: true });

  return {
    ok: true,
    executed: true,
    results,
  };
}
