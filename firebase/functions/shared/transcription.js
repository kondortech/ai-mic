"use strict";

const path = require("path");
const os = require("os");

const {
  INPUTS_SEGMENT,
  RAW_AUDIO_FILENAME,
} = require("./constants");

/**
 * Parses storage path "<userId>/inputs/<noteUuid>/raw_audio.mp4" into { userId, noteUuid }.
 * Returns null if path doesn't match.
 */
function parseNotesAudioPath(objectName) {
  if (!objectName) return null;
  const parts = objectName.split("/");
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

module.exports = {
  parseNotesAudioPath,
  convertToFlac,
};
