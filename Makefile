NAME := VexSign
PLATFORM := iphoneos
SCHEMES := VexSign
# Keep the distributable filename tied to the Xcode app version.
APP_VERSION ?= $(shell grep -m1 'MARKETING_VERSION = ' VexSign.xcodeproj/project.pbxproj | sed -E 's/.*MARKETING_VERSION = "?([^";]+)"?;.*/\1/')
IPA_FILE := packages/$(NAME)-$(APP_VERSION).ipa
# TMPDIR is unset in some environments (plain Linux CI, bare shells); without a
# fallback the paths below would resolve to "/$(NAME)" and fail on permissions.
TMP := $(if $(TMPDIR),$(TMPDIR),/tmp)/$(NAME)
# Optional job-owned verified binary cache; ordinary local builds keep Xcode defaults.
SPM_CACHE_PATH ?=
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)
.PHONY: test-server test-cloud help docs-check all clean bootstrap test verify lint deploy-server strict-concurrency audit-packages $(SCHEMES)

all: $(SCHEMES)

# Keep all as the default; help must never replace the IPA build.
help:
	@printf '%s\n' \
	  'make                  Build unsigned packages/VexSign-<version>.ipa (macOS/Xcode)' \
	  'make bootstrap        Validate toolchain and resolve Swift packages' \
	  'make verify           Portable repository checks and Python policy tests' \
	  'make docs-check       Check local Markdown file links (offline)' \
	  'make test             App simulator tests (macOS/Xcode)' \
	  'make device-smoke     Install/launch signed app on an explicitly selected physical device' \
	  'make test-server      Python backend tests (install server requirements first)' \
	  'make test-cloud       Cloud build, tests and contract drift check (npm ci first)' \
	  'make lint [FIX=1]     Optional SwiftLint report or corrections' \
	  'make strict-concurrency  Build local packages with concurrency diagnostics' \
	  'make audit-packages   Read-only upstream dependency audit (network)' \
	  'make deploy-server    Build optional server Docker image' \
	  'make clean            Remove local IPA staging/output'

docs-check:
	@python3 tools/check-docs.py
	@python3 tools/test_docs.py

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# Validate a fresh checkout and resolve packages without building.
#   make bootstrap
bootstrap:
	@bash tools/bootstrap.sh

# Install-server TLS is generated and persisted on each device, not in an IPA.
$(SCHEMES):
	xcodebuild \
	    $(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",) \
	    -workspace VexSign.xcworkspace \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -skipPackagePluginValidation \
	    VEXSIGN_SOURCE_COMMIT="$(shell git rev-parse HEAD)" \
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
	zip -r9 "$(IPA_FILE)" Payload

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
	swift build --package-path AltSourceKit -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors=false
	@echo "== NimbleKit (Swift 6 language mode: complete by default) =="
	swift build --package-path NimbleKit -Xswiftc -warnings-as-errors=false
	@echo "== app target =="
	@echo "Guarded by tools/concurrency-discipline.py (no new @unchecked Sendable / nonisolated(unsafe))."

# Everything that can be checked without Xcode: the same gates as CI's quick
# job, minus Swift syntax parsing. Use this before pushing; `make test` and
# `make` are the parts that need a toolchain.
#   make verify
verify: docs-check
	@python3 tools/test_ci_repair_agent.py
	@python3 tools/test_autopilot.py
	@python3 tools/test_release_assets.py
	@python3 tools/test_device_acceptance.py
	@echo "== quick check (syntax-independent) =="
	@python3 .github/scripts/quick_check.py --self-test
	@python3 .github/scripts/quick_check.py --no-swiftc
	@echo "== Xcode project structure =="
	@python3 tools/check-pbxproj.py
	@echo "== package graph (workspace/project pins) =="
	@python3 tools/check-package-graph.py
	@echo "== localisation catalogue =="
	@python3 tools/sync-strings.py --check
	@python3 tools/test_sync_strings.py
	@echo "== error discipline =="
	@python3 tools/error-discipline.py
	@echo "== singleton freeze =="
	@python3 tools/singleton-freeze.py
	@echo "== concurrency discipline =="
	@python3 tools/concurrency-discipline.py
	@echo "== workflow trigger policy =="
	@python3 tools/test_workflow_policy.py
	@python3 tools/test_workflow_trace_policy.py
	@python3 tools/test_build_provenance.py
	@python3 tools/test_package_graph.py
	@python3 tools/test_coverage_report.py
	@echo "== embedded-container packaging =="
	@python3 -m unittest discover -s EmbeddedContainer/tests -v
	@echo "== native-signing preparation =="
	@python3 -m unittest discover -s NativeSigning/PythonTests -v

# Read-only upstream check for the root Xcode SwiftPM requirements (Dependabot
# covers Package.swift, but not project.pbxproj). Never edits the project.
#   make audit-packages
audit-packages:
	@python3 tools/check-xcode-packages.py

# Style, on demand. Nothing in CI runs SwiftLint any more: the auto-fix commits
# it pushed onto pull requests were noise at best (see CHANGELOG.md).
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
	    $(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",) \
	    -workspace VexSign.xcworkspace \
	    -scheme VexSignTests \
	    -configuration Debug \
	    -destination "$$dest" \
	    -derivedDataPath "$(TMP)/TestDerivedData" \
	    -only-testing:VexSignTests \
	    -parallel-testing-enabled YES \
	    -parallel-testing-worker-count 2 \
	    -skipPackagePluginValidation \
	    -skipMacroValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    CODE_SIGNING_REQUIRED=NO \
	    CODE_SIGN_IDENTITY="" \
	    COMPILER_INDEX_STORE_ENABLE=NO \
	    ONLY_ACTIVE_ARCH=YES \
	    test

# Use an activated virtualenv, or override PYTHON=/path/to/venv/bin/python.
PYTHON ?= python3
test-server:
	cd server && $(PYTHON) -m pytest tests/ -q

# Do not silently install or update dependencies during a test run.
test-cloud:
	cd cloud-signing && npm run build && npm test && npm run contracts
	git diff --exit-code -- cloud-signing/openapi.json

.PHONY: device-smoke
device-smoke:
	@bash tools/device-smoke.sh
