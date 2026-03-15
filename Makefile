.PHONY: deploy-functions

deploy-functions:
	npm install --prefix functions
	firebase deploy --only functions
