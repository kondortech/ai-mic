import { HttpsError } from "firebase-functions/v2/https";
import type { Bucket } from "@google-cloud/storage";

import { sanitizePlan, savePlanJson } from "../shared/plan";
import type { OverwriteExecutionPlanRequest, OverwriteExecutionPlanResponse } from "../shared/types";

interface OverwriteExecutionPlanContext {
  uid: string;
  bucket: Bucket;
  logger: { info: (msg: string, obj?: object) => void };
}

export async function overwriteExecutionPlanBusiness(
  data: Partial<Pick<OverwriteExecutionPlanRequest, "inputUuid">> & { plan?: unknown } | undefined,
  ctx: OverwriteExecutionPlanContext
): Promise<OverwriteExecutionPlanResponse> {
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

  const plan = data?.plan as { actions?: unknown[] } | undefined;
  logger.info("overwriteExecutionPlan called", {
    uid,
    inputUuid: data?.inputUuid ?? null,
    hasPlan: !!data?.plan,
    actionsCount: Array.isArray(plan?.actions) ? plan.actions.length : null,
    planKeys: data?.plan && typeof data.plan === "object" ? Object.keys(data.plan as object) : [],
  });

  return { ok: true, planPath: saved.planPath, actionsCount: sanitized.actions.length };
}
