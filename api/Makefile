.PHONY: help install generate generate-ts generate-dart clean

PROJECT_ROOT := ..
GENERATED_DIR := $(PROJECT_ROOT)/generated
# TypeScript types for Cloud Functions (openapi-typescript)
FIREBASE_FUNCTIONS_GENERATED_TS := $(PROJECT_ROOT)/firebase/functions/generated/api.types.ts
OPENAPI_SPEC := openapi.yaml

help:
	@echo "API generation targets:"
	@echo "  make install       Install api generation dependencies"
	@echo "  make generate      Generate TypeScript and Dart clients/models"
	@echo "  make generate-ts   Generate TypeScript types only → firebase/functions/generated/"
	@echo "  make generate-dart Generate Dart package only"
	@echo "  make clean         Remove generated artifacts"

install:
	npm install

generate: generate-ts generate-dart

generate-ts: install
	@mkdir -p $(dir $(FIREBASE_FUNCTIONS_GENERATED_TS))
	npx openapi-typescript $(OPENAPI_SPEC) -o $(FIREBASE_FUNCTIONS_GENERATED_TS)

generate-dart: install
	npx openapi-generator-cli generate \
		-i $(OPENAPI_SPEC) \
		-g dart \
		-o $(GENERATED_DIR)/dart \
		--additional-properties=pubName=ai_mic_api,pubVersion=1.0.0

clean:
	rm -rf $(GENERATED_DIR)/dart $(GENERATED_DIR)/typescript
	rm -f $(FIREBASE_FUNCTIONS_GENERATED_TS)
