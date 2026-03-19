const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const speech = require("@google-cloud/speech");
const logger = require("firebase-functions/logger");
const {
  exchangeServerAuthCode,
  persistTokensAfterCodeExchange,
  disconnectCalendar,
} = require("./google_calendar");

/** Same Web client ID as Flutter `kGoogleSignInWebClientId` (not secret). */
const googleOAuthWebClientId = defineString("GOOGLE_OAUTH_WEB_CLIENT_ID", { default: "" });
const googleOAuthClientSecret = defineSecret("GOOGLE_OAUTH_CLIENT_SECRET");
const path = require("path");
const fs = require("fs");
const os = require("os");

initializeApp();

// Storage path: <userId>/notes/<noteUuid>/raw_audio.mp4
// Transcript path: <userId>/notes/<noteUuid>/raw_text.txt
const NOTES_SEGMENT = "notes";
const RAW_AUDIO_FILENAME = "raw_audio.mp4";
const RAW_TEXT_FILENAME = "raw_text.txt";
const TEMP_TRANSCODE_PREFIX = ".transcribe_temp/";
const AUDIO_EXTENSIONS = [".m4a", ".mp3", ".mp4", ".wav", ".flac", ".webm"];
// Speech-to-Text does not support M4A/MP4/AAC; we convert these to FLAC
const NEEDS_CONVERSION = [".m4a", ".mp4"];

/**
 * Parses storage path "<userId>/notes/<noteUuid>/raw_audio.mp4" into { userId, noteUuid }.
 * Returns null if path doesn't match.
 */
function parseNotesAudioPath(objectName) {
  if (!objectName) return null;
  const parts = objectName.split("/");
  // userId / notes / noteUuid / raw_audio.mp4
  if (parts.length !== 4) return null;
  const [userId, segment, noteUuid, fileName] = parts;
  if (!userId || !noteUuid) return null;
  if (segment !== NOTES_SEGMENT) return null;
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
 * Or call with { storagePath } pointing to "<userId>/notes/<noteUuid>/raw_audio.mp4".
 * Requires the user to be signed in; may only transcribe files under their own recordings path.
 */
exports.transcribeRecording = onCall(
  {
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
        ? `${uid}/${NOTES_SEGMENT}/${noteUuid}/${RAW_AUDIO_FILENAME}`
        : storagePathFromInput;

    if (!storagePath || typeof storagePath !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "Provide noteUuid (recommended) or storagePath pointing to <userId>/notes/<noteUuid>/raw_audio.mp4."
      );
    }

    const filePath = storagePath.startsWith("/") ? storagePath.slice(1) : storagePath;
    const parsed = parseNotesAudioPath(filePath);
    if (!parsed) {
      throw new HttpsError(
        "invalid-argument",
        `Path must be <userId>/${NOTES_SEGMENT}/<noteUuid>/${RAW_AUDIO_FILENAME}.`
      );
    }
    if (parsed.userId !== uid) {
      throw new HttpsError("permission-denied", "You may only transcribe your own notes.");
    }

    const bucket = getStorage().bucket();
    const bucketName = bucket.name;
    const { userId, noteUuid: parsedNoteUuid } = parsed;
    const rawTextPath = `${userId}/${NOTES_SEGMENT}/${parsedNoteUuid}/${RAW_TEXT_FILENAME}`;

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
        .collection("notes")
        .doc(parsedNoteUuid)
        .set(
          { status: "transcribed", updatedAt: FieldValue.serverTimestamp() },
          { merge: true }
        );

      logger.log("transcribeRecording: raw_text saved", { rawTextPath, length: textToSave.length });

      return { ok: true, rawTextPath, transcriptLength: textToSave.length };
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
 * Connect Google Calendar: client sends serverAuthCode from Google Sign-In (Calendar scope + serverClientId).
 * Stores refresh token in users/{uid}/private/google_calendar (not readable by client).
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
      throw new HttpsError(
        "invalid-argument",
        "Missing serverAuthCode. Use Google Sign-In with Calendar scope and Web client ID."
      );
    }
    const clientId = googleOAuthWebClientId.value().trim();
    const clientSecret = googleOAuthClientSecret.value();
    if (!clientId || !clientSecret) {
      throw new HttpsError(
        "failed-precondition",
        "Set GOOGLE_OAUTH_WEB_CLIENT_ID and secret GOOGLE_OAUTH_CLIENT_SECRET. See docs/CALENDAR_SETUP.md."
      );
    }
    try {
      const tokens = await exchangeServerAuthCode({
        code: serverAuthCode,
        clientId,
        clientSecret,
      });
      const result = await persistTokensAfterCodeExchange(request.auth.uid, tokens);
      logger.log("connectGoogleCalendar: ok", { uid: request.auth.uid });
      return { ok: true, ...result };
    } catch (err) {
      logger.error("connectGoogleCalendar: failed", { error: err.message });
      throw new HttpsError("internal", err.message || "Failed to connect Calendar.");
    }
  }
);

/** Remove stored Calendar tokens (user disconnects). */
exports.disconnectGoogleCalendar = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  await disconnectCalendar(request.auth.uid);
  return { ok: true };
});
