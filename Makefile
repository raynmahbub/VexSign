NAME := VexSign
PLATFORM := iphoneos
SCHEMES := VexSign
# TMPDIR is unset in some environments (plain Linux CI, bare shells); without a
# fallback the paths below would resolve to "/$(NAME)" and fail on permissions.
TMP := $(if $(TMPDIR),$(TMPDIR),/tmp)/$(NAME)
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)
.PHONY: all clean test verify lint deploy-server strict-concurrency $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# Install-server TLS is generated and persisted on each device, not in an IPA.
$(SCHEMES):
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
	@echo "== distribution metadata =="
	@python3 tools/distribution-metadata.py
	@echo "== embedded-container packaging =="
	@python3 -m unittest discover -s EmbeddedContainer/tests -v
	@echo "== native-signing preparation =="
	@python3 -m unittest discover -s NativeSigning/tests -v

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
