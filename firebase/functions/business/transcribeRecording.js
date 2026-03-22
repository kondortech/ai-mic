"use strict";

const path = require("path");
const fs = require("fs");
const os = require("os");
const speech = require("@google-cloud/speech");

const { HttpsError } = require("firebase-functions/v2/https");
const { FieldValue } = require("firebase-admin/firestore");

const {
  INPUTS_SEGMENT,
  RAW_AUDIO_FILENAME,
  RAW_TEXT_FILENAME,
  PLAN_FILENAME,
  TEMP_TRANSCODE_PREFIX,
  NEEDS_CONVERSION,
} = require("../shared/constants");
const { buildAndSavePlanOnly } = require("../shared/plan");
const { parseNotesAudioPath, convertToFlac } = require("../shared/transcription");

/**
 * @typedef {import('../generated/api.types').components['schemas']['TranscribeRecordingRequest']} TranscribeRecordingRequest
 * @typedef {import('../generated/api.types').components['schemas']['TranscribeRecordingResponse']} TranscribeRecordingResponse
 */

/**
 * Transcribe audio in Storage, save transcript and plan.
 * @param {TranscribeRecordingRequest} data
 * @param {{
 *   authUid: string,
 *   bucket: import('@google-cloud/storage').Bucket,
 *   bucketName: string,
 *   getGeminiApiKey: () => string,
 *   getGeminiModel: () => string,
 *   logger: import('firebase-functions/logger'),
 *   getFirestore: () => import('firebase-admin/firestore').Firestore,
 * }} ctx
 * @returns {Promise<TranscribeRecordingResponse>}
 */
async function transcribeRecordingBusiness(data, ctx) {
  const { authUid, bucket, bucketName, getGeminiApiKey, getGeminiModel, logger, getFirestore } = ctx;

  const noteUuid = data?.noteUuid;
  const storagePathFromInput = data?.storagePath;

  const storagePath =
    typeof noteUuid === "string" && noteUuid
      ? `${authUid}/${INPUTS_SEGMENT}/${noteUuid}/${RAW_AUDIO_FILENAME}`
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
  if (parsed.userId !== authUid) {
    throw new HttpsError("permission-denied", "You may only transcribe your own inputs.");
  }

  const { userId, noteUuid: parsedNoteUuid } = parsed;
  const rawTextPath = `${userId}/${INPUTS_SEGMENT}/${parsedNoteUuid}/${RAW_TEXT_FILENAME}`;

  let fileSize = 0;
  try {
    const [metadata] = await bucket.file(filePath).getMetadata();
    fileSize = Number(metadata?.size ?? 0);
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
    const isLongFile = fileSize > 10 * 1024 * 1024;

    const config = {
      languageCode: "en-US",
      alternativeLanguageCodes: ["es-ES", "de-DE", "ru-RU"],
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
    let detectedLanguage = null;

    const processResults = (results) => {
      const text = (results || [])
        .map((r) => (r.alternatives?.[0]?.transcript ?? ""))
        .filter(Boolean)
        .join("\n");
      const lang = (results || []).find((r) => r.languageCode)?.languageCode ?? config.languageCode;
      return { text, languageCode: lang };
    };

    if (isLongFile) {
      const [operation] = await speechClient.longRunningRecognize({
        config,
        audio,
      });
      const [response] = await operation.promise();
      const processed = processResults(response.results);
      transcriptText = processed.text;
      detectedLanguage = processed.languageCode;
    } else {
      const [response] = await speechClient.recognize({
        config,
        audio,
      });
      const processed = processResults(response.results);
      transcriptText = processed.text;
      detectedLanguage = processed.languageCode;
    }

    const textToSave = transcriptText.trim() || "(no speech detected)";

    const rawTextFile = bucket.file(rawTextPath);
    await rawTextFile.save(textToSave, {
      metadata: { contentType: "text/plain; charset=utf-8" },
    });

    const firestore = getFirestore();
    const inputUpdate = {
      status: "transcribed",
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (detectedLanguage) {
      inputUpdate.languageCode = detectedLanguage;
    }
    await firestore
      .collection("users")
      .doc(userId)
      .collection("inputs")
      .doc(parsedNoteUuid)
      .set(inputUpdate, { merge: true });

    const llmKey = getGeminiApiKey();
    const llmModel = getGeminiModel().trim() || "gemini-2.5-flash";
    let planPath = `${userId}/${INPUTS_SEGMENT}/${parsedNoteUuid}/${PLAN_FILENAME}`;
    let planHasActions = false;
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
        planHasActions = (planRes.actionsCount ?? 0) > 0;
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

    const planStatus = planHasActions ? "plan_created" : "no_plan_created";
    const planUpdate = { status: planStatus, updatedAt: FieldValue.serverTimestamp() };
    if (detectedLanguage) {
      planUpdate.languageCode = detectedLanguage;
    }
    await firestore
      .collection("users")
      .doc(userId)
      .collection("inputs")
      .doc(parsedNoteUuid)
      .set(planUpdate, { merge: true });

    logger.log("transcribeRecording: raw_text saved", {
      rawTextPath,
      length: textToSave.length,
      languageCode: detectedLanguage,
    });

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

module.exports = { transcribeRecordingBusiness };
