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
.PHONY: test-server test-cloud help docs-check all clean bootstrap test verify lint format deploy-server strict-concurrency audit-packages $(SCHEMES)

all: $(SCHEMES)

# Keep all as the default; help must never replace the IPA build.
help:
	@printf '%s\n' \
	  'make                  Build unsigned packages/VexSign-<version>.ipa (macOS/Xcode)' \
	  'make bootstrap        Validate toolchain and resolve Swift packages' \
	  'make verify           Portable repository checks and Python policy tests' \
	  'make docs-check       Check local Markdown file links (offline)' \
	  'make test             App simulator tests (macOS/Xcode)' \
	  'make test-device-foundation  Credential-free parser/storage/executor tests (macOS Swift)' \
	  'make device-smoke     Install/launch signed app on an explicitly selected physical device' \
	  'make test-server      Python backend tests (install server requirements first)' \
	  'make test-cloud       Cloud build, tests and contract drift check (npm ci first)' \
	  'make lint [FIX=1]     Optional SwiftLint report or corrections' \
	  'make format [FIX=1]   Optional swiftformat report or corrections' \
	  'make strict-concurrency  Build local packages with concurrency diagnostics' \
	  'make audit-packages   Read-only upstream dependency audit (network)' \
	  'make deploy-server    Build optional server Docker image' \
	  'make clean            Remove local IPA staging/output'

docs-check:
	@python3 VexSign/Tools/Validation/repository-validation/check-docs.py
	@python3 VexSign/Tools/Validation/repository-validation/test_docs.py
	@python3 VexSign/Tools/Validation/repository-validation/sync_repo_aliases.py --check

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# Validate a fresh checkout and resolve packages without building.
#   make bootstrap
bootstrap:
	@bash VexSign/Tools/Scripts/bootstrap.sh

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

# Self-hosted backend (VexSign/Services/WebManager/API/). Keep this BELOW `all` — make builds the first
# target in the file, so a rule above it would hijack a bare `make` (which is
# what CI runs).
#   docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -v vexsign-repo:/data \
#     vexsign-server   # then add /repo/source.json as a source in the app
IMAGE ?= vexsign-server
deploy-server:
	@command -v docker >/dev/null 2>&1 || { \
		echo "docker is not installed; see VexSign/Services/WebManager/README.md for the deploy steps"; exit 1; }
	docker build --platform linux/amd64 -t $(IMAGE) VexSign/Services/WebManager
	@echo "Built $(IMAGE). Run it with:"
	@echo "  docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -e REPO_STORE_DIR=/data \\"
	@echo "    -v vexsign-repo:/data $(IMAGE)"

# The leaf-first half of Swift 6 adoption, as a command rather than a promise.
# Compiles the two first-party packages with complete concurrency checking and prints what is
# left. Warnings only — this is a report, not a gate, so it can be run on a branch that is still
# being cleaned up.  Exit code is the build's, so a clean run is a real signal.
#   make strict-concurrency
# swiftc has no `-warnings-as-errors=false`; passing it fails with
# "unknown argument" before a single file is type-checked. Warnings are already
# non-fatal unless `-warnings-as-errors` is given, so the diagnostics this target
# is supposed to report need no extra flag.
#
# Both packages are iOS/tvOS-only: neither declares a macOS platform, and
# AltSourceKit imports SwiftUI. A bare host `swift build` therefore cannot work,
# so they are built against the iOS SDK. Warnings stay non-fatal; this is a
# report, not a gate.
IOS_SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_TRIPLE ?= arm64-apple-ios17.0
STRICT_CONCURRENCY_FLAGS = $(if $(IOS_SDK),--sdk "$(IOS_SDK)") --triple $(IOS_TRIPLE) -Xswiftc -strict-concurrency=complete

strict-concurrency:
	@echo "== AltSourceKit (StrictConcurrency, warnings only) =="
	swift build --package-path VexSign/Packages/AltSourceKit $(STRICT_CONCURRENCY_FLAGS)
	@echo "== NimbleKit (Swift 6 language mode: complete by default) =="
	swift build --package-path VexSign/Packages/NimbleKit --sdk "$(IOS_SDK)" --triple $(IOS_TRIPLE)
	@echo "== app target =="
	@echo "Guarded by VexSign/Tools/Validation/security-validation/concurrency-discipline.py (no new @unchecked Sendable / nonisolated(unsafe)),"
	@echo "and by VexSign/Tools/Validation/security-validation/test_concurrency_audit.py (every escape needs a written invariant)."

# Everything that can be checked without Xcode: the same gates as CI's quick
# job, minus Swift syntax parsing. Use this before pushing; `make test` and
# `make` are the parts that need a toolchain.
#   make verify
verify: docs-check
	@python3 VexSign/Tools/Validation/repository-validation/test_repo_aliases.py
	@python3 VexSign/Tools/Validation/repository-validation/check_ios_icon_assets.py
	@python3 VexSign/Tools/Validation/security-validation/test_public_blur_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_private_launch_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_private_defaults_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_archive_extraction_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_network_timeout_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_logging_message_policy.py
	@python3 VexSign/Tools/Validation/security-validation/test_cross_file_privacy.py
	@python3 VexSign/Tools/Validation/security-validation/test_signing_identity_policy.py
	@python3 VexSign/Tools/Development/test_integration_contracts.py
	@python3 VexSign/Tools/Validation/architecture-rules/test_architecture_boundaries.py
	@python3 VexSign/Tools/Validation/architecture-rules/test_feature_workspace_boundaries.py
	@python3 VexSign/Tools/Validation/architecture-rules/test_feature_preservation.py
	@python3 VexSign/Tools/Validation/architecture-rules/test_architecture_excellence.py
	@python3 VexSign/Tools/Validation/architecture-rules/test_repository_layout.py
	@python3 VexSign/Tools/Development/test_performance_fixtures.py
	@python3 VexSign/Tools/Validation/repository-validation/test_ci_repair_agent.py
	@python3 VexSign/Tools/Validation/repository-validation/test_autopilot.py
	@python3 VexSign/Tools/Release/test_release_assets.py
	@python3 VexSign/Tools/Development/test_device_acceptance.py
	@python3 VexSign/Tools/Validation/security-validation/test_native_promotion_evidence.py
	@echo "== quick check (syntax-independent) =="
	@python3 .github/scripts/quick_check.py --self-test
	@python3 .github/scripts/quick_check.py --no-swiftc
	@echo "== Xcode project structure =="
	@python3 VexSign/Tools/Validation/repository-validation/check-pbxproj.py
	@echo "== package graph (workspace/project pins) =="
	@python3 VexSign/Tools/Validation/repository-validation/check-package-graph.py
	@python3 VexSign/Tools/Validation/repository-validation/test_xcode_package_audit.py
	@echo "== localisation catalogue =="
	@python3 VexSign/Tools/Validation/repository-validation/sync-strings.py --check
	@python3 VexSign/Tools/Validation/repository-validation/test_sync_strings.py
	@echo "== error discipline =="
	@python3 VexSign/Tools/Validation/security-validation/error-discipline.py
	@echo "== singleton freeze =="
	@python3 VexSign/Tools/Validation/security-validation/singleton-freeze.py
	@echo "== concurrency discipline =="
	@python3 VexSign/Tools/Validation/security-validation/concurrency-discipline.py
	@echo "== concurrency audit (every escape needs a reason) =="
	@python3 VexSign/Tools/Validation/security-validation/test_concurrency_audit.py
	@echo "== device foundation preparation/security wiring (not Swift tests) =="
	@python3 VexSign/Tools/Validation/security-validation/test_device_foundation.py
	@python3 VexSign/Tools/Validation/security-validation/test_install_monitoring_policy.py
	@echo "== native signing capability =="
	@python3 VexSign/Tools/Validation/security-validation/check-native-handoff.py
	@echo "== CMS fixture contract =="
	@python3 VexSign/Packages/NativeSigning/Fixtures/make_cms_fixture.py --check | tail -1
	@echo "== workflow trigger policy =="
	@python3 VexSign/Tools/Validation/repository-validation/test_workflow_policy.py
	@python3 VexSign/Tools/Validation/repository-validation/test_workflow_trace_policy.py
	@python3 VexSign/Tools/Validation/repository-validation/test_build_provenance.py
	@python3 VexSign/Tools/Validation/repository-validation/test_package_graph.py
	@python3 VexSign/Tools/Validation/repository-validation/test_coverage_report.py
	@python3 VexSign/Tools/Validation/repository-validation/test_swift6_build_regressions.py
	@echo "== style configuration (editorconfig/swiftformat/swiftlint agree) =="
	@python3 VexSign/Tools/Validation/repository-validation/test_style_config.py
	@echo "== swift style drift gate (changed lines only) =="
	@python3 VexSign/Tools/Validation/repository-validation/test_swift_format_drift.py
	@echo "== service runtimes (CI, images and blueprint agree) =="
	@python3 VexSign/Tools/Validation/repository-validation/test_runtime_policy.py
	@echo "== embedded-container packaging =="
	@python3 -m unittest discover -s VexSign/Integrations/tests -v
	@echo "== native-signing preparation =="
	@python3 -m unittest discover -s VexSign/Packages/NativeSigning/PythonTests -v
	@echo "== modern-device source boundaries =="
	@python3 VexSign/Packages/DeviceBridge/test_prepare.py

# Exact production parser/storage/executor sources, no binary dependency or Apple
# credentials. macOS permissions/backup tests do not establish iOS Data Protection,
# native ABI, device trust, transport or physical installation acceptance.
.PHONY: test-device-foundation
test-device-foundation:
	@test "$$(uname -s)" = Darwin && command -v swift >/dev/null 2>&1 || { \
		echo "test-device-foundation needs macOS with Swift/Xcode; no tests were run."; exit 1; }
	@python3 VexSign/Tools/Validation/security-validation/prepare_device_foundation.py
	swift test --package-path .build/device-foundation

# Credential-free behavioral tests of the production native signing core.
# Needs C++17 and OpenSSL 3 development files; never downloads dependencies.
# Use VEXSIGN_NATIVE_SANITIZERS=1 for ASan+UBSan. This is not iOS/Apple trust
# or physical-device acceptance; the Security bridge is exercised by make test.
.PHONY: test-signing-core
test-signing-core:
	@python3 VexSign/Tools/Validation/security-validation/test_native_signing_core.py

# Read-only upstream check for the root Xcode SwiftPM requirements. Dependabot
# reads Package.swift (the three VexSign/Packages/ manifests in .github/dependabot.yml)
# but not project.pbxproj, so the app's own package requirements are checked here.
# Never edits the project.
#   make audit-packages
audit-packages:
	@python3 VexSign/Tools/Validation/repository-validation/check-xcode-packages.py

# Style, on demand. Nothing in CI runs SwiftLint any more: the auto-fix commits
# it pushed onto pull requests were noise at best (see CHANGELOG.md).
# `--strict` promotes warnings to errors, and the tree carries a large pre-existing
# backlog (`line_length` alone counts in the thousands, including files that were
# already in scope), so lint a path you are editing rather than expecting a green
# whole-tree run: `swiftlint --strict VexSign/App/iOS/Infrastructure/...`.
#   make lint              # report (fails on any violation)
#   make lint FIX=1        # auto-correct in place, then review the diff
lint:
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint is not installed: brew install swiftlint"; exit 1; }
	@if [ "$(FIX)" = "1" ]; then swiftlint --fix; else swiftlint --strict; fi

# swiftformat for consistent code style
#   make format            # report (fails on any violation)
#   make format FIX=1      # auto-correct in place
format:
	@command -v swiftformat >/dev/null 2>&1 || { \
		echo "swiftformat is not installed: brew install swiftformat"; exit 1; }
	@if [ "$(FIX)" = "1" ]; then swiftformat .; else swiftformat --lint .; fi

# Unit tests. Same command the CI `tests` job runs (.github/workflows/ci.yml);
# a second way to run the suite should never exist. The simulator uses a local
# ad-hoc signature for Keychain entitlements, never an Apple signing identity.
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
	    CODE_SIGNING_ALLOWED=YES \
	    CODE_SIGNING_REQUIRED=YES \
	    CODE_SIGN_IDENTITY="-" \
	    AD_HOC_CODE_SIGNING_ALLOWED=YES \
	    COMPILER_INDEX_STORE_ENABLE=NO \
	    ONLY_ACTIVE_ARCH=YES \
	    test

# Use an activated virtualenv, or override PYTHON=/path/to/venv/bin/python.
PYTHON ?= python3
test-server:
	cd VexSign/Services/WebManager/API && $(PYTHON) -m pytest ../Tests/ -q

# Do not silently install or update dependencies during a test run.
test-cloud:
	cd VexSign/Services/Cloud && npm run build && npm test && npm run contracts
	git diff --exit-code -- VexSign/Services/Cloud/openapi.json

.PHONY: device-smoke
device-smoke:
	@bash VexSign/Tools/Scripts/device-smoke.sh
