NAME := VexSign
PLATFORM := iphoneos
SCHEMES := VexSign
# TMPDIR is unset in some environments (plain Linux CI, bare shells); without a
# fallback the paths below would resolve to "/$(NAME)" and fail on permissions.
TMP := $(if $(TMPDIR),$(TMPDIR),/tmp)/$(NAME)
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)
# --- Local install server TLS identity --------------------------------------
#
# The local server serves itms-services over HTTPS, so every build needs a
# certificate and key in deps/. There are two ways to get one, and a build must
# never end up with neither:
#
#   make            -> deps: reuse deps/, else GENERATE a development identity
#                           locally and offline (Scripts/local-tls)
#   make deps-release -> fetch the published pack and verify its digest against
#                           Scripts/local-tls/pinned-pack.sha256; mismatches and
#                           network failures stop the build
#
# `make deps-pin` writes that digest. See docs/RELEASING.md.
CERT_PACK_URL ?= https://vexsign-install.vexsign.workers.dev/pack.json
LOCAL_TLS := Scripts/local-tls
PIN_FILE := $(LOCAL_TLS)/pinned-pack.sha256
PINNED_SHA := $(shell sed -n 's/^sha256:\([0-9a-f]\{64\}\)$$/\1/p' $(PIN_FILE) 2>/dev/null | tail -1)

.PHONY: all deps deps-dev deps-release deps-pin clean test verify lint deploy-server strict-concurrency $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# Offline and idempotent: an identity that is already in deps/ is kept, so a
# tester's trusted CA profile does not go stale on the next incremental build.
deps:
	@if [ -f deps/server.crt ] && [ -f deps/server.pem ] && [ -f deps/commonName.txt ]; then \
		echo "deps: using the TLS identity already in deps/"; \
		if command -v openssl >/dev/null 2>&1 && \
		   ! openssl x509 -in deps/server.crt -noout -checkend 86400 >/dev/null 2>&1; then \
			echo "warning: the bundled TLS certificate expires within a day."; \
			echo "         Run 'make deps-release' (pinned) or 'make deps-dev' to replace it."; \
		fi; \
	else \
		echo "deps: no TLS identity in deps/ — generating a development identity offline"; \
		sh $(LOCAL_TLS)/make-dev-identity.sh deps || exit 1; \
	fi

# Always regenerate: a fresh development identity, for when the trusted one is stale.
deps-dev:
	@rm -f deps/server.crt deps/server.pem deps/commonName.txt deps/tls-identity.txt
	@sh $(LOCAL_TLS)/make-dev-identity.sh deps

# The release path. Fails loudly, by design, when the identity cannot be fetched or
# is not the one that was reviewed — silently shipping a different key is worse.
deps-release:
	@if [ -z "$(PINNED_SHA)" ]; then \
		echo ""; \
		echo "error: no pinned digest in $(PIN_FILE)."; \
		echo "       Run 'make deps-pin' once, review the change and commit it (docs/RELEASING.md)."; \
		echo "       Release builds must not ship an identity nobody reviewed."; \
		exit 1; \
	fi
	@mkdir -p "$(TMP)"
	@CERT_PACK_URL="$(CERT_PACK_URL)" sh $(LOCAL_TLS)/fetch-release-identity.sh "$(TMP)/tls-release" || exit 1
	@python3 $(LOCAL_TLS)/pack_digest.py --verify "$(TMP)/tls-release" "$(PINNED_SHA)" || exit 1
	@rm -rf deps && mkdir -p deps && cp "$(TMP)/tls-release"/* deps/ && chmod 600 deps/server.pem
	@echo "deps: release TLS identity installed from $(CERT_PACK_URL)"

# Fetches the pack, prints its digest and rewrites the pin file. The diff is the review.
deps-pin:
	@mkdir -p "$(TMP)"
	@CERT_PACK_URL="$(CERT_PACK_URL)" sh $(LOCAL_TLS)/fetch-release-identity.sh "$(TMP)/tls-pin" || exit 1
	@digest="$$(python3 $(LOCAL_TLS)/pack_digest.py "$(TMP)/tls-pin")" || exit 1; \
	{ \
		echo "# Pinned release TLS identity for the local install server."; \
		echo "#"; \
		echo "# 'make deps-release' fetches the pack and refuses to build unless the digest"; \
		echo "# matches the single sha256 line below. Regenerate with 'make deps-pin' and"; \
		echo "# review the diff: a changed digest means every IPA from this commit ships a"; \
		echo "# different key, and every installed Root CA profile may need re-trusting."; \
		echo "#"; \
		echo "# source = $(CERT_PACK_URL)"; \
		echo "# cn     = $$(cat "$(TMP)/tls-pin/commonName.txt")"; \
		echo "# pinned = $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
		echo "sha256:$$digest"; \
	} > $(PIN_FILE); \
	echo "pinned: sha256:$$digest"; \
	echo "review $(PIN_FILE) and commit it — that diff is the decision."

$(SCHEMES): deps
	xcodebuild \
	    -project VexSign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -skipPackagePluginValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	rm -rf Payload
	rm -rf $(STAGE)/
	mkdir -p $(STAGE)/Payload

	mv "$(APP)/$@.app" "$(STAGE)/Payload/$@.app"

	chmod -R 0755 "$(STAGE)/Payload/$@.app"
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$@.app"

	cp deps/* "$(STAGE)/Payload/$@.app/" || true

	rm -rf "$(STAGE)/Payload/$@.app/_CodeSignature"
	ln -sf "$(STAGE)/Payload" Payload
	
	mkdir -p packages
	zip -r9 "packages/$@.ipa" Payload

# Self-hosted backend (server/). Keep this BELOW `all` — make builds the first
# target in the file, so a rule above it would hijack a bare `make` (which is
# what CI runs).
#   docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -v vexsign-repo:/data \
#     vexsign-server   # then add /repo/source.json as a source in the app
IMAGE ?= vexsign-server
deploy-server:
	@command -v docker >/dev/null 2>&1 || { \
		echo "docker is not installed; see server/README.md for the deploy steps"; exit 1; }
	docker build --platform linux/amd64 -t $(IMAGE) server
	@echo "Built $(IMAGE). Run it with:"
	@echo "  docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -e REPO_STORE_DIR=/data \\"
	@echo "    -v vexsign-repo:/data $(IMAGE)"

# The leaf-first half of Swift 6 adoption, as a command rather than a promise.
# Compiles the two first-party packages with complete concurrency checking and prints what is
# left. Warnings only — this is a report, not a gate, so it can be run on a branch that is still
# being cleaned up.  Exit code is the build's, so a clean run is a real signal.
#   make strict-concurrency
strict-concurrency:
	@echo "== AltSourceKit (StrictConcurrency, warnings only) =="
	swift build --package-path AltSourceKit -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors=false 2>&1 | \
		grep -E "warning:|error:" | sed 's|^.*/AltSourceKit/|AltSourceKit/|' | sort -u || true
	@echo "== NimbleKit (Swift 6 language mode: complete by default) =="
	swift build --package-path NimbleKit -Xswiftc -warnings-as-errors=false 2>&1 | \
		grep -E "warning:|error:" | sed 's|^.*/NimbleKit/|NimbleKit/|' | sort -u || true
	@echo "== app target =="
	@echo "Guarded by tools/concurrency-discipline.py (no new @unchecked Sendable / nonisolated(unsafe))."

# Everything that can be checked without Xcode: six gates corresponding to CI’s quick job (without Swift syntax parsing).
# Use this before pushing instead of remembering six commands; `make test` is the half that needs a
# toolchain.  See docs/TEST_PLAN.md for the order the rest of the testing phase runs in.
#   make verify
verify:
	@echo "== quick check (syntax-independent) =="
	@python3 .github/scripts/quick_check.py --no-swiftc
	@echo "== localisation catalogue =="
	@python3 tools/sync-strings.py --check
	@echo "== error discipline =="
	@python3 tools/error-discipline.py
	@echo "== singleton freeze =="
	@python3 tools/singleton-freeze.py
	@echo "== concurrency discipline =="
	@python3 tools/concurrency-discipline.py
	@echo "== workflow trigger policy =="
	@python3 tools/test_workflow_policy.py

# Style, on demand. Nothing in CI runs SwiftLint any more: the auto-fix commits
# it pushed onto pull requests were noise at best (see docs/STABILIZATION_BASELINE.md).
#   make lint              # report (fails on any violation)
#   make lint FIX=1        # auto-correct in place, then review the diff
lint:
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint is not installed: brew install swiftlint"; exit 1; }
	@if [ "$(FIX)" = "1" ]; then swiftlint --fix; else swiftlint --strict; fi

# Unit tests. Same command the CI `tests` job runs (.github/workflows/ci.yml);
# a second way to run the suite should never exist.
# The simulator is resolved at run time so this does not rot when Xcode renames
# its device list.
#   make test                     # newest available iPhone simulator
#   make test SIMULATOR="platform=iOS Simulator,name=iPhone 16"   # explicit
SIMULATOR ?= auto
test:
	@if [ "$(SIMULATOR)" = "auto" ]; then \
		dest="$$(python3 .github/scripts/select_simulator.py --print-id 2>/dev/null)"; \
		if [ -z "$$dest" ]; then \
			echo "No iPhone simulator available. Install an iOS runtime in Xcode -> Settings -> Components,"; \
			echo "or pass SIMULATOR=\"platform=iOS Simulator,name=<device>\" explicitly."; \
			exit 1; \
		fi; \
		dest="platform=iOS Simulator,id=$$dest"; \
	else \
		dest="$(SIMULATOR)"; \
	fi; \
	echo "Testing on $$dest"; \
	xcodebuild \
	    -workspace VexSign.xcworkspace \
	    -scheme VexSignTests \
	    -configuration Debug \
	    -destination "$$dest" \
	    -derivedDataPath "$(TMP)/TestDerivedData" \
	    -only-testing:VexSignTests \
	    -parallel-testing-enabled NO \
	    -skipPackagePluginValidation \
	    -skipMacroValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    CODE_SIGNING_REQUIRED=NO \
	    CODE_SIGN_IDENTITY="" \
	    COMPILER_INDEX_STORE_ENABLE=NO \
	    test
