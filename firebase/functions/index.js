"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");
const { getFirestore } = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

const { transcribeRecordingBusiness } = require("./business/transcribeRecording");
const { connectGoogleCalendarBusiness } = require("./business/connectGoogleCalendar");
const { disconnectGoogleCalendarBusiness } = require("./business/disconnectGoogleCalendar");
const { overwriteExecutionPlanBusiness } = require("./business/overwriteExecutionPlan");
const { executeStoredPlanBusiness } = require("./business/executeStoredPlan");

initializeApp();

const googleOAuthWebClientId = defineString("GOOGLE_OAUTH_WEB_CLIENT_ID", { default: "" });
const googleOAuthClientSecret = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");
const geminiApiKey = defineSecret("GEMINI_API_KEY");
const geminiModel = defineString("GEMINI_MODEL", { default: "gemini-2.5-flash" });

exports.transcribeRecording = onCall(
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
      {
        noteUuid: request.data?.noteUuid,
        storagePath: request.data?.storagePath,
      },
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

exports.connectGoogleCalendar = onCall(
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
      { serverAuthCode: request.data?.serverAuthCode },
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

exports.disconnectGoogleCalendar = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return disconnectGoogleCalendarBusiness(
    {},
    {
      uid: request.auth.uid,
      firestore: getFirestore(),
    }
  );
});

exports.overwriteExecutionPlan = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const bucket = getStorage().bucket();
  return overwriteExecutionPlanBusiness(
    {
      inputUuid: request.data?.inputUuid,
      plan: request.data?.plan,
    },
    {
      uid: request.auth.uid,
      bucket,
      logger,
    }
  );
});

exports.executeStoredPlan = onCall(
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
      { inputUuid: request.data?.inputUuid },
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
