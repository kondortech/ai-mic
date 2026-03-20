# AI Mic API

OpenAPI specification and generated types for Firebase Cloud Functions.

## Generate types

From `api/`:

```bash
make install    # npm install in api/
make generate   # TypeScript (Cloud Functions) + Dart → firebase/functions/generated + <repo-root>/generated/dart/
```

Or individually:

```bash
make generate-ts    # → ../firebase/functions/generated/api.types.ts
make generate-dart  # → ../generated/dart/
```

## Structure

- `openapi.yaml` - OpenAPI 3.0.3 spec (single source of truth)
- `<repo-root>/generated/dart/` - Dart package (`ai_mic_api`), import `package:ai_mic_api/api.dart`
- `firebase/functions/generated/api.types.ts` - TypeScript types for Cloud Functions (from `make generate-ts` or `npm run generate-api-types` in `firebase/functions`)

## Usage

- **Flutter**: Add `ai_mic_api` path dependency pointing at `../generated/dart`. Run `flutter pub get` in the app after regenerating.
- **Cloud Functions**: Regenerate types with `make generate-ts` from `api/` or `npm run generate-api-types` from `firebase/functions`. Business logic uses these models via JSDoc in `firebase/functions/business/`.
