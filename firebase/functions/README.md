# Firebase Cloud Functions

This directory contains Firebase Cloud Functions for the AI Mic project. It is **not** part of the Flutter app bundle.

- Install dependencies: `npm install`
- Generate OpenAPI TypeScript types into `generated/api.types.ts`: `npm run generate-api-types` (from this directory)
- Deploy: `firebase deploy --only functions` (from project root) — runs `generate-api-types` on predeploy
- Emulator: `npm run serve` (from this directory) or `firebase emulators:start --only functions` (from project root)

## Layout

- `index.js` — callable definitions (`onCall`); auth and wiring only
- `business/*.js` — domain logic; request/response shapes match `generated/api.types.ts` (JSDoc)
- `shared/*.js` — helpers (plans, calendar, transcription, Genkit)
