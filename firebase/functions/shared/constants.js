"use strict";

module.exports = {
  INPUTS_SEGMENT: "inputs",
  RAW_AUDIO_FILENAME: "raw_audio.mp4",
  RAW_TEXT_FILENAME: "raw_text.txt",
  PLAN_FILENAME: "plan.json",
  TEMP_TRANSCODE_PREFIX: ".transcribe_temp/",
  AUDIO_EXTENSIONS: [".m4a", ".mp3", ".mp4", ".wav", ".flac", ".webm"],
  /** Speech-to-Text does not support M4A/MP4/AAC; we convert these to FLAC */
  NEEDS_CONVERSION: [".m4a", ".mp4"],
};
