.PHONY: help install-functions deploy-functions deploy-firestore-rules deploy-storage-rules deploy-rules deploy-all set-calendar-secret set-llm-secret set-secrets deploy-functions-with-secret

# Optional: pass Firebase project from CLI, e.g.
# make deploy-functions PROJECT=ai-mic-18768
PROJECT ?=

ifdef PROJECT
FIREBASE_PROJECT_FLAG := --project $(PROJECT)
else
FIREBASE_PROJECT_FLAG :=
endif

help:
	@echo "Available targets:"
	@echo "  make install-functions"
	@echo "  make deploy-functions [PROJECT=<firebase-project-id>]"
	@echo "  make deploy-firestore-rules [PROJECT=<firebase-project-id>]"
	@echo "  make deploy-storage-rules [PROJECT=<firebase-project-id>]"
	@echo "  make deploy-rules [PROJECT=<firebase-project-id>]"
	@echo "  make deploy-all [PROJECT=<firebase-project-id>]"
	@echo "  make set-calendar-secret [PROJECT=<firebase-project-id>]"
	@echo "  make set-llm-secret [PROJECT=<firebase-project-id>]"
	@echo "  make set-secrets [PROJECT=<firebase-project-id>]"
	@echo "  make deploy-functions-with-secret [PROJECT=<firebase-project-id>]"

install-functions:
	npm install --prefix functions

deploy-functions: install-functions
	firebase deploy --only functions $(FIREBASE_PROJECT_FLAG)

deploy-firestore-rules:
	firebase deploy --only firestore:rules $(FIREBASE_PROJECT_FLAG)

deploy-storage-rules:
	firebase deploy --only storage $(FIREBASE_PROJECT_FLAG)

deploy-rules: deploy-firestore-rules deploy-storage-rules

# Reads local secret from functions/.env key:
# GOOGLE_OAUTH_CLIENT_SECRET_VALUE
# and updates Secret Manager secret:
# GOOGLE_OAUTH_CLIENT_SECRET
set-calendar-secret:
	@test -f functions/.env || (echo "functions/.env not found"; exit 1)
	@secret_value=$$(sed -n 's/^[[:space:]]*GOOGLE_OAUTH_CLIENT_SECRET_VALUE[[:space:]]*=[[:space:]]*//p' functions/.env | head -n 1); \
	if [ -z "$$secret_value" ]; then \
		echo "GOOGLE_OAUTH_CLIENT_SECRET_VALUE is missing in functions/.env"; \
		exit 1; \
	fi; \
	printf '%s' "$$secret_value" | firebase functions:secrets:set GOOGLE_OAUTH_CLIENT_SECRET --data-file - $(FIREBASE_PROJECT_FLAG)

set-llm-secret:
	@test -f functions/.env || (echo "functions/.env not found"; exit 1)
	@secret_value=$$(sed -n 's/^[[:space:]]*GEMINI_API_KEY_VALUE[[:space:]]*=[[:space:]]*//p' functions/.env | head -n 1); \
	if [ -z "$$secret_value" ]; then \
		echo "GEMINI_API_KEY_VALUE is missing in functions/.env"; \
		exit 1; \
	fi; \
	printf '%s' "$$secret_value" | firebase functions:secrets:set GEMINI_API_KEY --data-file - $(FIREBASE_PROJECT_FLAG)

set-secrets: set-calendar-secret set-llm-secret

# Helper flow: update secret first, then deploy functions.
deploy-functions-with-secret: set-secrets deploy-functions

deploy-all: deploy-functions-with-secret deploy-rules