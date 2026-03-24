export const INPUTS_SEGMENT = "inputs";
export const RAW_AUDIO_FILENAME = "raw_audio.mp4";
export const RAW_TEXT_FILENAME = "raw_text.txt";
export const PLAN_FILENAME = "plan.json";
export const TEMP_TRANSCODE_PREFIX = ".transcribe_temp/";
export const AUDIO_EXTENSIONS = [".m4a", ".mp3", ".mp4", ".wav", ".flac", ".webm"];
/** Speech-to-Text does not support M4A/MP4/AAC; we convert these to FLAC */
export const NEEDS_CONVERSION = [".m4a", ".mp4"];
