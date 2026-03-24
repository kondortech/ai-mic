import path from "path";
import os from "os";
import { INPUTS_SEGMENT, RAW_AUDIO_FILENAME } from "./constants";

export interface ParsedNotesAudioPath {
  userId: string;
  noteUuid: string;
}

/**
 * Parses storage path "<userId>/inputs/<noteUuid>/raw_audio.mp4" into { userId, noteUuid }.
 * Returns null if path doesn't match.
 */
export function parseNotesAudioPath(objectName: string | null | undefined): ParsedNotesAudioPath | null {
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
export async function convertToFlac(inputPath: string): Promise<string> {
  const ffmpegPath = require("ffmpeg-static") as string;
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const ffmpeg = require("fluent-ffmpeg");
  ffmpeg.setFfmpegPath(ffmpegPath);

  const outputPath = path.join(os.tmpdir(), `transcribe_${Date.now()}.flac`);
  await new Promise<void>((resolve, reject) => {
    ffmpeg(inputPath)
      .toFormat("flac")
      .audioChannels(1)
      .audioFrequency(16000)
      .on("end", () => resolve())
      .on("error", (err: unknown) => reject(err))
      .save(outputPath);
  });
  return outputPath;
}
