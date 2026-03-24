import path from "path";
import fs from "fs";
import os from "os";
import speech from "@google-cloud/speech";
import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import type { Bucket } from "@google-cloud/storage";
import type { Firestore } from "firebase-admin/firestore";
import {
  INPUTS_SEGMENT,
  RAW_AUDIO_FILENAME,
  RAW_TEXT_FILENAME,
  PLAN_FILENAME,
  TEMP_TRANSCODE_PREFIX,
  NEEDS_CONVERSION,
} from "../shared/constants";
import { buildAndSavePlanOnly } from "../shared/plan";
import { parseNotesAudioPath, convertToFlac } from "../shared/transcription";
import type {
  TranscribeRecordingRequest,
  TranscribeRecordingResponse,
  StoredPlan,
  InputDocUpdate,
} from "../shared/types";

interface TranscribeRecordingContext {
  authUid: string;
  bucket: Bucket;
  bucketName: string;
  getGeminiApiKey: () => string;
  getGeminiModel: () => string;
  logger: { log: (msg: string, obj?: object) => void; error: (msg: string, obj?: object) => void; warn: (msg: string, obj?: object) => void };
  getFirestore: () => Firestore;
}

export async function transcribeRecordingBusiness(
  data: TranscribeRecordingRequest | undefined,
  ctx: TranscribeRecordingContext
): Promise<TranscribeRecordingResponse> {
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
  } catch {
    throw new HttpsError("not-found", "Recording file not found in storage.");
  }

  logger.log("transcribeRecording: starting", { filePath, userId, noteUuid: parsedNoteUuid, rawTextPath });

  const ext = path.extname(filePath).toLowerCase();
  const needsConversion = NEEDS_CONVERSION.includes(ext);
  let audioUri = `gs://${bucketName}/${filePath}`;
  let tempFlacPath: string | null = null;
  let tempInputPath: string | null = null;

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

    type SpeechEncoding = "FLAC" | "LINEAR16" | "MP3" | "WEBM_OPUS";
    const config: {
      languageCode: string;
      alternativeLanguageCodes: string[];
      enableAutomaticPunctuation: boolean;
      model: string;
      encoding?: SpeechEncoding;
      sampleRateHertz?: number;
    } = {
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
    let detectedLanguage: string | null = null;

    const processResults = (results: unknown) => {
      const arr = Array.isArray(results) ? results : [];
      const text = arr
        .map((r: { alternatives?: Array<{ transcript?: string | null }> }) => r.alternatives?.[0]?.transcript ?? "")
        .filter(Boolean)
        .join("\n");
      const lang = arr.find((r: { languageCode?: string }) => r.languageCode)?.languageCode ?? config.languageCode;
      return { text, languageCode: lang };
    };

    if (isLongFile) {
      const [operation] = await speechClient.longRunningRecognize({ config, audio });
      const [response] = await operation.promise();
      const processed = processResults(response?.results ?? []);
      transcriptText = processed.text;
      detectedLanguage = processed.languageCode;
    } else {
      const [response] = await speechClient.recognize({ config, audio });
      const processed = processResults(response?.results ?? []);
      transcriptText = processed.text;
      detectedLanguage = processed.languageCode;
    }

    const textToSave = transcriptText.trim() || "(no speech detected)";

    const rawTextFile = bucket.file(rawTextPath);
    await rawTextFile.save(textToSave, {
      metadata: { contentType: "text/plain; charset=utf-8" },
    });

    const firestore = getFirestore();
    const inputUpdate: InputDocUpdate = {
      status: "transcribed",
      updatedAt: FieldValue.serverTimestamp(),
      ...(detectedLanguage && { languageCode: detectedLanguage }),
    };
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
        const fallbackPlan: StoredPlan = {
          actions: [],
          empty_reason: "Processing skipped: missing GEMINI_API_KEY.",
          generated_at: new Date().toISOString(),
        };
        await bucket.file(planPath).save(JSON.stringify(fallbackPlan, null, 2), {
          metadata: { contentType: "application/json; charset=utf-8" },
        });
      }
    } catch (planErr) {
      const err = planErr as Error;
      logger.error("transcribeRecording: plan processing failed", {
        userId,
        noteUuid: parsedNoteUuid,
        error: err?.message,
      });
      const failedPlan: StoredPlan = {
        actions: [],
        empty_reason: `Processing failed: ${err?.message || String(planErr)}`,
        generated_at: new Date().toISOString(),
      };
      await bucket.file(planPath).save(JSON.stringify(failedPlan, null, 2), {
        metadata: { contentType: "application/json; charset=utf-8" },
      });
    }

    const planStatus = planHasActions ? "plan_created" : "no_plan_created";
    const planUpdate: InputDocUpdate = {
      status: planStatus,
      updatedAt: FieldValue.serverTimestamp(),
      ...(detectedLanguage && { languageCode: detectedLanguage }),
    };
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
    const e = err as Error;
    logger.error("transcribeRecording: failed", { filePath, rawTextPath, error: e.message });
    throw new HttpsError("internal", e.message || "Transcription failed.");
  } finally {
    if (tempFlacPath && fs.existsSync(tempFlacPath)) fs.unlinkSync(tempFlacPath);
    if (tempInputPath && fs.existsSync(tempInputPath)) fs.unlinkSync(tempInputPath);
    if (needsConversion) {
      const tempStoragePath = `${TEMP_TRANSCODE_PREFIX}${parsedNoteUuid}.flac`;
      try {
        await bucket.file(tempStoragePath).delete();
      } catch (e) {
        const ex = e as Error;
        logger.warn("transcribeRecording: temp FLAC delete failed", {
          tempStoragePath,
          error: ex?.message,
        });
      }
    }
  }
}
