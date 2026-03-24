// eslint-disable-next-line @typescript-eslint/no-explicit-any
let cachedGenkitAi: any = null;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let cachedGoogleAiPlugin: any = null;

export function extractJsonFromText(text: string | null | undefined): string | null {
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

export async function getGenkitClient(apiKey: string) {
  if (cachedGenkitAi && cachedGoogleAiPlugin) return { ai: cachedGenkitAi, googleAI: cachedGoogleAiPlugin };

  const [{ genkit }, { googleAI }] = await Promise.all([import("genkit"), import("@genkit-ai/google-genai")]);

  process.env.GOOGLE_GENAI_API_KEY = apiKey;
  const ai = genkit({
    plugins: [googleAI()],
  });
  cachedGenkitAi = ai;
  cachedGoogleAiPlugin = googleAI;
  return { ai, googleAI };
}

import type { LlmPlanActionRaw, LlmPlanResponseRaw } from "./types";

interface BuildPlanParams {
  transcriptText: string;
  nowIso: string;
  apiKey: string;
  modelName: string;
}

/** Result from LLM - arguments may need normalization to string values. */
interface BuildPlanResult {
  actions: Array<{ tool: string; arguments?: Record<string, unknown> }>;
  empty_reason: string | null;
  rawText: string;
}

export async function buildPlanWithGemini({ transcriptText, nowIso, apiKey, modelName }: BuildPlanParams): Promise<BuildPlanResult> {
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
- timezone (one of: local, UTC, America/New_York, America/Los_Angeles, America/Chicago, America/Denver, Europe/London, Europe/Paris, Europe/Berlin, Asia/Tokyo, Asia/Shanghai, Asia/Singapore, Australia/Sydney, Australia/Melbourne, Pacific/Auckland; default "local")

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
- For create_calendar_event always include timezone from the enum above. Use "local" when unknown.
- Keep note title concise.
`;
  const { ai, googleAI } = await getGenkitClient(apiKey);
  const response = await ai.generate({
    model: (googleAI as { model: (name: string) => unknown }).model(modelName),
    prompt,
    config: { temperature: 0.2 },
  });
  const text = (response?.text || "").trim();
  const jsonText = extractJsonFromText(text);
  if (!jsonText) throw new Error("LLM did not return JSON.");
  const parsed = JSON.parse(jsonText) as LlmPlanResponseRaw;
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
  const actions: BuildPlanResult["actions"] = parsed.actions
    .filter((a): a is LlmPlanActionRaw => a != null && typeof a === "object")
    .map((a) => ({
      tool: String(a.tool ?? ""),
      arguments: a.arguments && typeof a.arguments === "object" ? a.arguments : {},
    }));
  return {
    actions,
    empty_reason: typeof parsed.empty_reason === "string" ? parsed.empty_reason : null,
    rawText: text,
  };
}
