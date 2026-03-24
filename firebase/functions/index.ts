import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";
import { initializeApp } from "firebase-admin/app";
import { getStorage } from "firebase-admin/storage";
import { getFirestore } from "firebase-admin/firestore";
import logger from "firebase-functions/logger";

import { transcribeRecordingBusiness } from "./business/transcribeRecording";
import { connectGoogleCalendarBusiness } from "./business/connectGoogleCalendar";
import { disconnectGoogleCalendarBusiness } from "./business/disconnectGoogleCalendar";
import { overwriteExecutionPlanBusiness } from "./business/overwriteExecutionPlan";
import { executeStoredPlanBusiness } from "./business/executeStoredPlan";
import type {
  TranscribeRecordingRequest,
  ConnectGoogleCalendarRequest,
  DisconnectGoogleCalendarRequest,
  OverwriteExecutionPlanRequest,
  ExecuteStoredPlanRequest,
} from "./shared/types";

initializeApp();

const googleOAuthWebClientId = defineString("GOOGLE_OAUTH_WEB_CLIENT_ID", { default: "" });
const googleOAuthClientSecret = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");
const geminiApiKey = defineSecret("GEMINI_API_KEY");
const geminiModel = defineString("GEMINI_MODEL", { default: "gemini-2.5-flash" });

export const transcribeRecording = onCall(
  {
    secrets: [googleOAuthClientSecret, geminiApiKey],
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be signed in to transcribe.");
    }
    const bucket = getStorage().bucket();
    return transcribeRecordingBusiness(
      request.data as TranscribeRecordingRequest | undefined,
      {
        authUid: request.auth.uid,
        bucket,
        bucketName: bucket.name,
        getGeminiApiKey: () => geminiApiKey.value(),
        getGeminiModel: () => geminiModel.value(),
        logger,
        getFirestore,
      }
    );
  }
);

export const connectGoogleCalendar = onCall(
  {
    secrets: [googleOAuthClientSecret],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    return connectGoogleCalendarBusiness(
      request.data as Partial<ConnectGoogleCalendarRequest> | undefined,
      {
        uid: request.auth.uid,
        firestore: getFirestore(),
        googleOAuthWebClientId: googleOAuthWebClientId.value(),
        googleOAuthClientSecret: googleOAuthClientSecret.value(),
        logger,
      }
    );
  }
);

export const disconnectGoogleCalendar = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return disconnectGoogleCalendarBusiness(
    request.data as DisconnectGoogleCalendarRequest | undefined,
    {
      uid: request.auth.uid,
      firestore: getFirestore(),
    }
  );
});

export const overwriteExecutionPlan = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const bucket = getStorage().bucket();
  return overwriteExecutionPlanBusiness(
    request.data as Partial<OverwriteExecutionPlanRequest> & { plan?: unknown } | undefined,
    {
      uid: request.auth.uid,
      bucket,
      logger,
    }
  );
});

export const executeStoredPlan = onCall(
  {
    secrets: [googleOAuthClientSecret],
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const bucket = getStorage().bucket();
    return executeStoredPlanBusiness(
      request.data as Partial<ExecuteStoredPlanRequest> | undefined,
      {
        uid: request.auth.uid,
        bucket,
        firestore: getFirestore(),
        googleOAuthWebClientId: googleOAuthWebClientId.value(),
        googleOAuthClientSecret: googleOAuthClientSecret.value(),
        logger,
      }
    );
  }
);
