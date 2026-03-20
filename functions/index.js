const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const speech = require("@google-cloud/speech");
const logger = require("firebase-functions/logger");

const path = require("path");
const fs = require("fs");
const os = require("os");

initializeApp();

// Storage path: <userId>/inputs/<noteUuid>/raw_audio.mp4
// Transcript path: <userId>/inputs/<noteUuid>/raw_text.txt
const INPUTS_SEGMENT = "inputs";
const RAW_AUDIO_FILENAME = "raw_audio.mp4";
const RAW_TEXT_FILENAME = "raw_text.txt";
const PLAN_FILENAME = "plan.json";
const TEMP_TRANSCODE_PREFIX = ".transcribe_temp/";
const AUDIO_EXTENSIONS = [".m4a", ".mp3", ".mp4", ".wav", ".flac", ".webm"];
// Speech-to-Text does not support M4A/MP4/AAC; we convert these to FLAC
const NEEDS_CONVERSION = [".m4a", ".mp4"];
const googleOAuthWebClientId = defineString("GOOGLE_OAUTH_WEB_CLIENT_ID", { default: "" });
const googleOAuthClientSecret = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");
const geminiApiKey = defineSecret("GEMINI_API_KEY");
const geminiModel = defineString("GEMINI_MODEL", { default: "gemini-2.5-flash" });
let cachedGenkitAi = null;
let cachedGoogleAiPlugin = null;

function extractJsonFromText(text) {
  if (!text || typeof text !== "string") return null;
  const fenced = text.match(/```json\s*([\s\S]*?)\s*```/i);
  if (fenced?.[1]) return fenced[1];
  const firstBrace = text.indexOf("{");
  const lastBrace = text.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    return text.slice(firstBrace, lastBrace + 1);
  }
  return null;
}

async function getGenkitClient(apiKey) {
  if (cachedGenkitAi && cachedGoogleAiPlugin) return { ai: cachedGenkitAi, googleAI: cachedGoogleAiPlugin };

  // Genkit packages are ESM; load lazily from CommonJS entrypoint.
  const [{ genkit }, { googleAI }] = await Promise.all([
    import("genkit"),
    import("@genkit-ai/google-genai"),
  ]);

  process.env.GOOGLE_GENAI_API_KEY = apiKey;
  const ai = genkit({
    plugins: [googleAI()],
  });
  cachedGenkitAi = ai;
  cachedGoogleAiPlugin = googleAI;
  return { ai, googleAI };
}

async function buildPlanWithGemini({ transcriptText, nowIso, apiKey, modelName }) {
  const prompt = `
You are a planner that decides tool actions from a transcribed voice note.
Current time (ISO): ${nowIso}

Available tools:
1) create_note
Arguments:
- title (short title)
- text (note text)

2) create_calendar_event
Arguments:
- title
- description
- start_time (DateTime, ISO-8601 string)
- finish_time (DateTime, ISO-8601 string)
- timezone (string, default "local")

Input transcript:
"""${transcriptText}"""

Return STRICT JSON only in this format:
{
  "actions": [
    {
      "tool": "create_note" | "create_calendar_event",
      "arguments": { ... }
    }
  ],
  "empty_reason": null
}

OR (when no actions are needed):
{
  "actions": [],
  "empty_reason": "reason why no actions should be executed"
}

Rules:
- Always return valid JSON object.
- If transcript is not actionable, return empty actions + non-empty empty_reason.
- Use explicit DateTime strings for start_time and finish_time.
- For create_calendar_event always include timezone. Default it to "local" when unknown.
- Keep note title concise.
`;
  const { ai, googleAI } = await getGenkitClient(apiKey);
  const response = await ai.generate({
    model: googleAI.model(modelName),
    prompt,
    config: { temperature: 0.2 },
  });
  const text = (response?.text || "").trim();
  const jsonText = extractJsonFromText(text);
  if (!jsonText) throw new Error("LLM did not return JSON.");
  const parsed = JSON.parse(jsonText);
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed?.actions)) {
    throw new Error("LLM JSON missing actions array.");
  }
  if (parsed.actions.length === 0) {
    if (typeof parsed.empty_reason !== "string" || !parsed.empty_reason.trim()) {
      throw new Error("LLM JSON missing empty_reason for empty plan.");
    }
  } else if (parsed.empty_reason != null) {
    throw new Error("LLM JSON must not set empty_reason when actions are present.");
  }
  return {
    actions: parsed.actions,
    empty_reason: typeof parsed.empty_reason === "string" ? parsed.empty_reason : null,
    rawText: text,
  };
}

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

/**
 * Parses storage path "<userId>/inputs/<noteUuid>/raw_audio.mp4" into { userId, noteUuid }.
 * Returns null if path doesn't match.
 */
function parseNotesAudioPath(objectName) {
  if (!objectName) return null;
  const parts = objectName.split("/");
  // userId / inputs / noteUuid / raw_audio.mp4
  if (parts.length !== 4) return null;
  const [userId, segment, noteUuid, fileName] = parts;
  if (!userId || !noteUuid) return null;
  if (segment !== INPUTS_SEGMENT) return null;
  if (fileName !== RAW_AUDIO_FILENAME) return null;
  return { userId, noteUuid };
}

/**
 * Convert M4A/MP4 to FLAC using ffmpeg. Returns path to the FLAC file.
 */
async function convertToFlac(inputPath) {
  const ffmpegPath = require("ffmpeg-static");
  const ffmpeg = require("fluent-ffmpeg");
  ffmpeg.setFfmpegPath(ffmpegPath);

  const outputPath = path.join(os.tmpdir(), `transcribe_${Date.now()}.flac`);
  await new Promise((resolve, reject) => {
    ffmpeg(inputPath)
      .toFormat("flac")
      .audioChannels(1)
      .audioFrequency(16000)
      .on("end", resolve)
      .on("error", reject)
      .save(outputPath);
  });
  return outputPath;
}


/**
 * Callable function: transcribe an audio recording in Storage and save the transcript.
 * Call with { noteUuid } (recommended).
 * Or call with { storagePath } pointing to "<userId>/inputs/<noteUuid>/raw_audio.mp4".
 * Requires the user to be signed in; may only transcribe files under their own recordings path.
 */
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
    const uid = request.auth.uid;

    const noteUuid = request.data?.noteUuid;
    const storagePathFromInput = request.data?.storagePath;

    const storagePath =
      (typeof noteUuid === "string" && noteUuid)
        ? `${uid}/${INPUTS_SEGMENT}/${noteUuid}/${RAW_AUDIO_FILENAME}`
        : storagePathFromInput;

    if (!storagePath || typeof storagePath !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "Provide noteUuid (recommended) or storagePath pointing to <userId>/inputs/<noteUuid>/raw_audio.mp4."
      );
    }

    const filePath = storagePath.startsWith("/") ? storagePath.slice(1) : storagePath;
    const parsed = parseNotesAudioPath(filePath);
    if (!parsed) {
      throw new HttpsError(
        "invalid-argument",
        `Path must be <userId>/${INPUTS_SEGMENT}/<noteUuid>/${RAW_AUDIO_FILENAME}.`
      );
    }
    if (parsed.userId !== uid) {
      throw new HttpsError("permission-denied", "You may only transcribe your own inputs.");
    }

    const bucket = getStorage().bucket();
    const bucketName = bucket.name;
    const { userId, noteUuid: parsedNoteUuid } = parsed;
    const rawTextPath = `${userId}/${INPUTS_SEGMENT}/${parsedNoteUuid}/${RAW_TEXT_FILENAME}`;

    let fileSize = 0;
    let contentType = "";
    try {
      const [metadata] = await bucket.file(filePath).getMetadata();
      fileSize = Number(metadata?.size ?? 0);
      contentType = metadata?.contentType ?? "";
    } catch (err) {
      throw new HttpsError("not-found", "Recording file not found in storage.");
    }

    logger.log("transcribeRecording: starting", { filePath, userId, noteUuid: parsedNoteUuid, rawTextPath });

    const ext = path.extname(filePath).toLowerCase();
    const needsConversion = NEEDS_CONVERSION.includes(ext);
    let audioUri = `gs://${bucketName}/${filePath}`;
    let tempFlacPath = null;
    let tempInputPath = null;

    try {
      if (needsConversion) {
        tempInputPath = path.join(os.tmpdir(), `input_${parsedNoteUuid}${ext}`);
        await bucket.file(filePath).download({ destination: tempInputPath });
        tempFlacPath = await convertToFlac(tempInputPath);
        const tempStoragePath = `${TEMP_TRANSCODE_PREFIX}${parsedNoteUuid}.flac`;
        await bucket.upload(tempFlacPath, {
          destination: tempStoragePath,
          metadata: { contentType: "audio/flac" },
        });
        audioUri = `gs://${bucketName}/${tempStoragePath}`;
      }

      const speechClient = new speech.SpeechClient();
      const isLongFile = fileSize > 10 * 1024 * 1024; // 10 MB -> use long running

      const config = {
        languageCode: "en-US",
        enableAutomaticPunctuation: true,
        model: "default",
      };

      if (audioUri.endsWith(".flac")) {
        config.encoding = "FLAC";
        config.sampleRateHertz = 16000;
      } else if (filePath.endsWith(".wav")) {
        config.encoding = "LINEAR16";
        config.sampleRateHertz = 16000;
      } else if (filePath.endsWith(".mp3")) {
        config.encoding = "MP3";
      } else if (filePath.endsWith(".webm")) {
        config.encoding = "WEBM_OPUS";
      }

      const audio = { uri: audioUri };

      let transcriptText = "";

      if (isLongFile) {
        const [operation] = await speechClient.longRunningRecognize({
          config,
          audio,
        });
        const [response] = await operation.promise();
        transcriptText = (response.results || [])
          .map((r) => (r.alternatives?.[0]?.transcript ?? ""))
          .filter(Boolean)
          .join("\n");
      } else {
        const [response] = await speechClient.recognize({
          config,
          audio,
        });
        transcriptText = (response.results || [])
          .map((r) => (r.alternatives?.[0]?.transcript ?? ""))
          .filter(Boolean)
          .join("\n");
      }

      const textToSave = transcriptText.trim() || "(no speech detected)";

      const rawTextFile = bucket.file(rawTextPath);
      await rawTextFile.save(textToSave, {
        metadata: { contentType: "text/plain; charset=utf-8" },
      });

      const firestore = getFirestore();
      await firestore
        .collection("users")
        .doc(userId)
        .collection("inputs")
        .doc(parsedNoteUuid)
        .set(
          { status: "transcribed", updatedAt: FieldValue.serverTimestamp() },
          { merge: true }
        );

      const llmKey = geminiApiKey.value();
      const llmModel = geminiModel.value().trim() || "gemini-1.5-flash";
      let planPath = `${userId}/${INPUTS_SEGMENT}/${parsedNoteUuid}/${PLAN_FILENAME}`;
      try {
        if (llmKey) {
          const planRes = await buildAndSavePlanOnly({
            bucket,
            uid: userId,
            inputUuid: parsedNoteUuid,
            transcriptText: textToSave,
            geminiKey: llmKey,
            geminiModelName: llmModel,
          });
          planPath = planRes.planPath;
        } else {
          const fallbackPlan = {
            actions: [],
            empty_reason: "Processing skipped: missing GEMINI_API_KEY.",
            generated_at: new Date().toISOString(),
          };
          await bucket.file(planPath).save(JSON.stringify(fallbackPlan, null, 2), {
            metadata: { contentType: "application/json; charset=utf-8" },
          });
        }
      } catch (planErr) {
        logger.error("transcribeRecording: plan processing failed", {
          userId,
          noteUuid: parsedNoteUuid,
          error: planErr?.message,
        });
        const failedPlan = {
          actions: [],
          empty_reason: `Processing failed: ${planErr?.message || String(planErr)}`,
          generated_at: new Date().toISOString(),
        };
        await bucket.file(planPath).save(JSON.stringify(failedPlan, null, 2), {
          metadata: { contentType: "application/json; charset=utf-8" },
        });
      }

      await firestore
        .collection("users")
        .doc(userId)
        .collection("inputs")
        .doc(parsedNoteUuid)
        .set(
          { status: "plan_created", updatedAt: FieldValue.serverTimestamp() },
          { merge: true }
        );

      logger.log("transcribeRecording: raw_text saved", { rawTextPath, length: textToSave.length });

      return { ok: true, rawTextPath, planPath, transcriptLength: textToSave.length };
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      logger.error("transcribeRecording: failed", { filePath, rawTextPath, error: err.message });
      throw new HttpsError("internal", err.message || "Transcription failed.");
    } finally {
      if (tempFlacPath && fs.existsSync(tempFlacPath)) fs.unlinkSync(tempFlacPath);
      if (tempInputPath && fs.existsSync(tempInputPath)) fs.unlinkSync(tempInputPath);
      if (needsConversion) {
        const tempStoragePath = `${TEMP_TRANSCODE_PREFIX}${parsedNoteUuid}.flac`;
        try {
          await bucket.file(tempStoragePath).delete();
        } catch (e) {
          logger.warn("transcribeRecording: temp FLAC delete failed", {
            tempStoragePath,
            error: e?.message,
          });
        }
      }
    }
  }
);

/**
 * Connect Google Calendar and store refresh token in:
 * users/<uid>/tokens/<google_calendar>
 * {
 *   type: "Google Calendar",
 *   token: <refresh_token>,
 *   createdAt: <timestamp>,
 *   expired: false
 * }
 */
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

    const serverAuthCode = request.data?.serverAuthCode;
    if (!serverAuthCode || typeof serverAuthCode !== "string") {
      throw new HttpsError("invalid-argument", "Missing serverAuthCode.");
    }

    const clientId = googleOAuthWebClientId.value().trim();
    const clientSecret = googleOAuthClientSecret.value();
    if (!clientId || !clientSecret) {
      throw new HttpsError(
        "failed-precondition",
        "Set GOOGLE_OAUTH_WEB_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET."
      );
    }

    try {
      const body = new URLSearchParams({
        code: serverAuthCode,
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: "authorization_code",
      });

      const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body,
      });
      const tokenJson = await tokenRes.json();
      if (!tokenRes.ok) {
        const msg = tokenJson.error_description || tokenJson.error || `HTTP ${tokenRes.status}`;
        throw new Error(msg);
      }

      const refreshToken = tokenJson.refresh_token;
      if (!refreshToken) {
        throw new Error(
          "No refresh token received. Revoke app access in Google Account and connect again."
        );
      }

      await getFirestore()
        .collection("users")
        .doc(request.auth.uid)
        .collection("tokens")
        .doc("google_calendar")
        .set({
          type: "Google Calendar",
          token: refreshToken,
          createdAt: FieldValue.serverTimestamp(),
          expired: false,
        });

      await getFirestore()
        .collection("users")
        .doc(request.auth.uid)
        .collection("tokens-last-status")
        .doc("google_calendar")
        .set({
          type: "Google Calendar",
          status: "connected",
          expired: false,
          updatedAt: FieldValue.serverTimestamp(),
        });

      logger.log("connectGoogleCalendar: token stored", { uid: request.auth.uid });
      return { ok: true };
    } catch (err) {
      logger.error("connectGoogleCalendar: failed", { error: err?.message });
      throw new HttpsError("internal", err?.message || "Failed to store Calendar token.");
    }
  }
);

/** Mark Calendar token as disconnected and update status doc. */
exports.disconnectGoogleCalendar = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const uid = request.auth.uid;
  const firestore = getFirestore();
  await firestore
    .collection("users")
    .doc(uid)
    .collection("tokens")
    .doc("google_calendar")
    .set(
      {
        type: "Google Calendar",
        expired: true,
      },
      { merge: true }
    );

  await firestore
    .collection("users")
    .doc(uid)
    .collection("tokens-last-status")
    .doc("google_calendar")
    .set(
      {
        type: "Google Calendar",
        status: "not connected",
        expired: true,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

  return { ok: true };
});

exports.overwriteExecutionPlan = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const uid = request.auth.uid;
  const inputUuid = String(request.data?.inputUuid || "").trim();
  if (!inputUuid) {
    throw new HttpsError("invalid-argument", "Missing inputUuid.");
  }
  const sanitized = sanitizePlan(request.data?.plan);
  const bucket = getStorage().bucket();
  const saved = await savePlanJson({
    bucket,
    uid,
    inputUuid,
    plan: sanitized,
  });

  logger.info("overwriteExecutionPlan called", {
    uid: request.auth?.uid ?? null,
    inputUuid: request.data?.inputUuid ?? null,
    hasPlan: !!request.data?.plan,
    actionsCount: Array.isArray(request.data?.plan?.actions)
      ? request.data.plan.actions.length
      : null,
    planKeys: request.data?.plan ? Object.keys(request.data.plan) : [],
  });
  return { ok: true, planPath: saved.planPath, actionsCount: sanitized.actions.length };
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
    const uid = request.auth.uid;
    const inputUuid = String(request.data?.inputUuid || "").trim();
    if (!inputUuid) {
      throw new HttpsError("invalid-argument", "Missing inputUuid.");
    }

    const bucket = getStorage().bucket();
    let plan;
    try {
      const loaded = await loadPlanJson({ bucket, uid, inputUuid });
      plan = loaded.plan;
    } catch (e) {
      throw new HttpsError("failed-precondition", `Cannot read plan.json: ${e?.message || e}`);
    }
    logger.info("executeStoredPlan called", {
      uid: request.auth?.uid ?? null,
      inputUuid: request.data?.inputUuid ?? null,
    });

    if (!Array.isArray(plan.actions) || plan.actions.length === 0) {
      return {
        ok: true,
        executed: false,
        reason: plan.empty_reason || "Plan has no actions.",
        results: [],
      };
    }

    const clientId = googleOAuthWebClientId.value().trim();
    const clientSecret = googleOAuthClientSecret.value();
    const results = await executePlanActions({
      firestore: getFirestore(),
      uid,
      inputUuid,
      actions: plan.actions,
      oauthClientId: clientId,
      oauthClientSecret: clientSecret,
    });
    logger.info("executeStoredPlan results", {
      uid: request.auth?.uid ?? null,
      inputUuid: request.data?.inputUuid ?? null,
      results,
    });
    await getFirestore()
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
);
