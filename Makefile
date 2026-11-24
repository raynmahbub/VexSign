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
.PHONY: test-server test-cloud verify-services help docs-check project-wiring all clean bootstrap test verify typecheck lint format deploy-server strict-concurrency audit-packages hooks $(SCHEMES)

all: $(SCHEMES)

# Keep all as the default; help must never replace the IPA build.
help:
	@printf '%s\n' \
	  'make                  Build unsigned packages/VexSign-<version>.ipa (macOS/Xcode)' \
	  'make bootstrap        Validate toolchain and resolve Swift packages' \
	  'make verify           Portable repository checks and Python policy tests' \
	  'make typecheck        Type-check the app with xcodebuild (macOS/Xcode)' \
	  'make docs-check       Check local Markdown file links (offline)' \
	  'make test             App simulator tests (macOS/Xcode)' \
	  'make test SUITE=A,B   Only the named test classes (fast iterate loop)' \
	  'make test-device-foundation  Credential-free parser/storage/executor tests (macOS Swift)' \
	  'make test-packages   SideSign and NativeSigning test targets (macOS Swift)' \
	  'make device-smoke     Install/launch signed app on an explicitly selected physical device' \
	  'make test-server      Python backend tests (install server requirements first)' \
	  'make test-cloud       Cloud build, tests and contract drift check (npm ci first)' \
	  'make verify-services  Both service suites above, in one command' \
	  'make hooks            Install the pre-push hook that runs the fast gate' \
	  'make lint [FIX=1]     Optional SwiftLint report or corrections' \
	  'make format [FIX=1]   Optional swiftformat report or corrections' \
	  'make strict-concurrency  Build local packages with concurrency diagnostics' \
	  'make audit-packages   Read-only upstream dependency audit (network)' \
	  'make deploy-server    Build optional server Docker image' \
	  'make clean            Remove local IPA staging/output'

# Opt in to the pre-push hook: `git config core.hooksPath .githooks`, no global
# configuration and nothing installed into .git. Undo with `git config --unset core.hooksPath`.
hooks:
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@printf '%s\n' "pre-push hook installed: quick_check.py + sync-strings.py --check"
	@printf '%s\n' "undo with: git config --unset core.hooksPath"

docs-check:
	@python3 Tools/Validation/repository-validation/check-docs.py
	@python3 Tools/Validation/repository-validation/test_docs.py
	@python3 Tools/Validation/repository-validation/sync_repo_aliases.py --check

# The project is folder-synchronized, so a source move is a build change. This
# catches a moved resource or a nested sync root without needing Xcode.
project-wiring:
	@python3 Tools/Validation/repository-validation/check_project_wiring.py
	@python3 Tools/Validation/repository-validation/test_project_wiring.py

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# Validate a fresh checkout and resolve packages without building.
#   make bootstrap
bootstrap:
	@bash Tools/Scripts/bootstrap.sh

# `licenseplist` ships a build-tool plugin (`LicensePlistBuildTool`) that writes the
# licence list while the app builds. Xcode asks a human to approve a plugin the
# first time it sees one, and that approval lives in a user's DerivedData, not in a
# shared project, so every non-interactive build — CI and `make` alike — must skip
# the prompt. The plugin still runs; only the validation step is skipped. It is not
# a blanket trust: the package is pinned to an exact version (3.27.1) in
# `project.pbxproj` and to a revision in the checked-in `Package.resolved`, and
# `check-package-graph.py` fails if those disagree.
#
# Install-server TLS is generated and persisted on each device, not in an IPA.
$(SCHEMES):
	xcodebuild \
	    $(if $(SPM_CACHE_PATH),-packageCachePath "$(SPM_CACHE_PATH)",) \
	    -skipPackagePluginValidation \
	    -workspace VexSign.xcworkspace \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
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

# Self-hosted backend (Services/WebManager/API/). Keep this BELOW `all` — make builds the first
# target in the file, so a rule above it would hijack a bare `make` (which is
# what CI runs).
#   docker run -p 8080:8080 -e ADMIN_TOKEN=<secret> -v vexsign-repo:/data \
#     vexsign-server   # then add /repo/source.json as a source in the app
IMAGE ?= vexsign-server
deploy-server:
	@command -v docker >/dev/null 2>&1 || { \
		echo "docker is not installed; see Tools/Validation/security-validation/evidence/service-contracts.md for the deploy steps"; exit 1; }
	docker build --platform linux/amd64 -t $(IMAGE) Services/WebManager
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
	swift build --package-path Packages/AltSourceKit $(STRICT_CONCURRENCY_FLAGS)
	@echo "== NimbleKit (Swift 6 language mode: complete by default) =="
	swift build --package-path Packages/NimbleKit --sdk "$(IOS_SDK)" --triple $(IOS_TRIPLE)
	@echo "== app target =="
	@echo "Guarded by Tools/Validation/security-validation/concurrency-discipline.py (no new @unchecked Sendable / nonisolated(unsafe)),"
	@echo "and by Tools/Validation/security-validation/test_concurrency_audit.py (every escape needs a written invariant)."

# Everything that can be checked without Xcode: the same gates as CI's quick job.
# Swift syntax is parsed with swiftc when one is installed and reported as a skip
# when none is, so `make verify` now means the same thing on Linux and on macOS.
# The two CI gates that cannot run here need a tool most machines do not have and
# fail rather than skip: check-swift-format-drift.py (pinned swiftformat) and
# test_native_signing_core.py (OpenSSL 3 + sanitizers).
#
# Every gate runs even when an earlier one fails, and the failing ones are listed
# together at the end, so one broken check no longer costs another full pass.
#   make verify
verify: docs-check project-wiring
	@set -u; \
	failed=""; ran=0; \
	for entry in \
	  "#repository structure, aliases and assets" \
  "python3 Tools/Validation/repository-validation/check_project_wiring.py" \
	  "python3 Tools/Validation/repository-validation/test_repo_aliases.py" \
	  "python3 Tools/Validation/repository-validation/sync_repo_aliases.py --check" \
	  "python3 Tools/Validation/repository-validation/check_ios_icon_assets.py" \
	  "python3 Tools/Validation/security-validation/test_public_blur_policy.py" \
	  "python3 Tools/Validation/security-validation/test_private_launch_policy.py" \
	  "python3 Tools/Validation/security-validation/test_private_defaults_policy.py" \
	  "python3 Tools/Validation/security-validation/test_archive_extraction_policy.py" \
	  "python3 Tools/Validation/security-validation/test_webmanager_wiring.py" \
  "python3 Tools/Validation/security-validation/test_webmanager_doc_routes.py" \
	  "python3 Tools/Validation/security-validation/test_network_timeout_policy.py" \
	  "python3 Tools/Validation/security-validation/test_capability_disclosure.py" \
	  "python3 Tools/Validation/security-validation/test_logging_message_policy.py" \
	  "python3 Tools/Validation/security-validation/test_cross_file_privacy.py" \
	  "python3 Tools/Validation/security-validation/test_signing_identity_policy.py" \
	  "python3 Tools/Audit/test_integration_contracts.py" \
	  "python3 Tools/Audit/test_task_history_resilience.py" \
	  "python3 Tools/Validation/architecture-rules/test_architecture_boundaries.py" \
	  "python3 Tools/Validation/architecture-rules/test_feature_workspace_boundaries.py" \
	  "python3 Tools/Validation/architecture-rules/test_architecture_excellence.py" \
	  "python3 Tools/Validation/architecture-rules/test_repository_layout.py" \
	  "python3 Tools/Audit/test_performance_fixtures.py" \
	  "python3 Tools/Validation/repository-validation/test_ci_repair_agent.py" \
	  "python3 Tools/Validation/repository-validation/test_autopilot.py" \
	  "python3 Tools/Release/test_release_assets.py" \
	  "python3 Tools/Audit/test_device_acceptance.py" \
	  "python3 Tools/Fixtures/RenewalFixture/test_observation.py" \
	  "python3 Tools/Build/test_install.py" \
	  "python3 Tools/Build/test_slot_export.py" \
	  "python3 Tools/Validation/security-validation/test_native_promotion_evidence.py" \
	  "#quick check (syntax-independent)" \
	  "python3 .github/scripts/quick_check.py --self-test" \
	  "#Xcode project structure" \
	  "python3 Tools/Validation/repository-validation/check-pbxproj.py" \
	  "#package graph (workspace/project pins)" \
	  "python3 Tools/Validation/repository-validation/check-package-graph.py" \
	  "python3 Tools/Validation/repository-validation/test_xcode_package_audit.py" \
	  "#localisation catalogue" \
	  "python3 Tools/Validation/repository-validation/sync-strings.py --check" \
	  "python3 Tools/Validation/repository-validation/test_sync_strings.py" \
	  "#error discipline" \
	  "python3 Tools/Validation/security-validation/error-discipline.py" \
	  "#singleton freeze" \
	  "python3 Tools/Validation/security-validation/singleton-freeze.py" \
	  "#concurrency discipline" \
	  "python3 Tools/Validation/security-validation/concurrency-discipline.py" \
	  "#concurrency audit (every escape needs a reason)" \
	  "python3 Tools/Validation/security-validation/test_concurrency_audit.py" \
	  "#device foundation preparation/security wiring (not Swift tests)" \
	  "python3 Tools/Validation/security-validation/test_device_foundation.py" \
	  "python3 Tools/Validation/security-validation/test_install_monitoring_policy.py" \
	  "#native signing capability" \
	  "python3 Tools/Validation/security-validation/check-native-handoff.py" \
	  "#CMS fixture contract" \
	  "python3 Packages/NativeSigning/Fixtures/make_cms_fixture.py --check | tail -1" \
	  "#workflow trigger policy" \
	  "python3 Tools/Validation/repository-validation/test_workflow_policy.py" \
	  "python3 Tools/Validation/repository-validation/test_workflow_trace_policy.py" \
	  "python3 Tools/Validation/repository-validation/test_build_provenance.py" \
	  "python3 Tools/Validation/repository-validation/test_package_graph.py" \
	  "python3 Tools/Validation/repository-validation/test_coverage_report.py" \
	  "python3 Tools/Validation/repository-validation/test_swift6_build_regressions.py" \
	  "#style configuration (editorconfig/swiftformat/swiftlint agree)" \
	  "python3 Tools/Validation/repository-validation/test_style_config.py" \
	  "#accessibility: fixed point sizes stay where they were declared" \
	  "python3 Tools/Validation/repository-validation/test_accessibility_baseline.py" \
	  "#accessibility: icon-only buttons carry a name" \
	  "python3 Tools/Validation/repository-validation/test_icon_button_labels.py" \
	  "#error copy: an Error enum that can reach a screen carries a sentence" \
	  "python3 Tools/Validation/repository-validation/test_error_message_policy.py" \
	  "#haptics: UIKit feedback generators live in Haptics, nowhere else" \
	  "python3 Tools/Validation/repository-validation/test_haptics_policy.py" \
	  "#motion: animations go through AppMotion so Reduce Motion is honoured" \
	  "python3 Tools/Validation/repository-validation/test_motion_policy.py" \
	  "#keyboard: a form with text fields can always dismiss the keyboard" \
	  "python3 Tools/Validation/repository-validation/test_keyboard_dismissal_policy.py" \
	  "#colours: literals live in VexSign/DesignSystem/Colors, not in views" \
	  "python3 Tools/Validation/repository-validation/test_color_policy.py" \
	  "#injection: the container graph is injected in one place" \
	  "python3 Tools/Validation/repository-validation/test_environment_injection_policy.py" \
	  "#swift indentation backlog ratchet (tabs may shrink, never grow)" \
	  "python3 Tools/Validation/repository-validation/test_swift_indentation_ratchet.py" \
	  "#detached-task inventory ratchet (unowned work may shrink, never grow)" \
	  "python3 Tools/Validation/repository-validation/test_detached_task_audit.py" \
	  "#strict-concurrency ratchet (first-party diagnostics may shrink, never grow)" \
	  "python3 Tools/Validation/repository-validation/test_strict_concurrency_ratchet.py" \
	  "#swift style drift gate (changed lines only)" \
	  "python3 Tools/Validation/repository-validation/test_swift_format_drift.py" \
	  "#service runtimes (CI, images and blueprint agree)" \
	  "python3 Tools/Validation/repository-validation/test_runtime_policy.py" \
	  "#embedded-container packaging" \
	  "python3 -m unittest discover -s Services/Integrations/tests -v" \
	  "#native-signing preparation" \
	  "python3 -m unittest discover -s Packages/NativeSigning/PythonTests -v" \
	  "#modern-device source boundaries" \
	  "python3 Packages/DeviceBridge/test_prepare.py" \
	  "#cross-service relay & cloud contracts" \
	  "python3 Tools/Audit/test_cloud_signing_contract.py" \
	  "python3 Tools/Audit/test_webmanager_relay_contract.py" \
	  "python3 .github/scripts/quick_check.py --root ." ; do \
	  case "$$entry" in \
	    \#*) printf '\n== %s ==\n' "$${entry#\#}"; continue ;; \
	  esac; \
	  printf '  %s\n' "$$entry"; \
	  ran=$$((ran + 1)); \
	  if ! bash -c "$$entry"; then failed="$$failed|$$entry"; fi; \
	done; \
	printf '\n'; \
	if [ -z "$$failed" ]; then printf '✅ %d gate(s) passed\n' "$$ran"; exit 0; fi; \
	printf '❌ some gates failed:\n' >&2; \
	printf '%s\n' "$$failed" | tr '|' '\n' | sed '/^$$/d' | sed 's/^/   /' >&2; \
	exit 1

# Type-check the app target. This is the one thing `make verify` cannot do: its Swift
# step parses syntax when a `swiftc` is installed and reports a skip when none is, and
# every other gate reads text. Without this, CI's build job is the first place a type
# error shows - minutes after the edit that caused it.
#   make typecheck
#   make typecheck DESTINATION="generic/platform=iOS"
DESTINATION ?= generic/platform=iOS Simulator
typecheck:
	@command -v xcodebuild >/dev/null 2>&1 || { \
		echo "typecheck needs xcodebuild (macOS). make verify does not compile Swift,"; \
		echo "so without a toolchain only CI's build job will catch a type error."; \
		exit 1; }
	xcodebuild \
	    -skipPackagePluginValidation \
	    -workspace VexSign.xcworkspace \
	    -scheme VexSign \
	    -configuration Debug \
	    -destination "$(DESTINATION)" \
	    -derivedDataPath "$(TMP)/TypecheckDerivedData" \
	    CODE_SIGNING_ALLOWED=NO \
	    COMPILER_INDEX_STORE_ENABLE=NO \
	    -quiet \
	    build

# Exact production parser/storage/executor sources, no binary dependency or Apple
# credentials. macOS permissions/backup tests do not establish iOS Data Protection,
# native ABI, device trust, transport or physical installation acceptance.
.PHONY: test-device-foundation
test-device-foundation:
	@test "$$(uname -s)" = Darwin && command -v swift >/dev/null 2>&1 || { \
		echo "test-device-foundation needs macOS with Swift/Xcode; no tests were run."; exit 1; }
	@python3 Tools/Validation/security-validation/prepare_device_foundation.py
	swift test --package-path .build/device-foundation

# Credential-free behavioral tests of the production native signing core.
# Needs C++17 and OpenSSL 3 development files; never downloads dependencies.
# Use VEXSIGN_NATIVE_SANITIZERS=1 for ASan+UBSan. This is not iOS/Apple trust
# or physical-device acceptance; the Security bridge is exercised by make test.
.PHONY: test-signing-core
test-signing-core:
	@python3 Tools/Validation/security-validation/test_native_signing_core.py

# The two first-party packages ship their own test targets: `Packages/SideSign/Tests`
# and `Packages/NativeSigning/Tests` (~318 cases). They run in
# `embedded-container.yml` on macOS for a change that touches `Packages/**`, which left anyone
# editing a package locally to read the workflow to find out they existed.
#   make test-packages
.PHONY: test-packages
test-packages:
	@test "$$(uname -s)" = Darwin && command -v swift >/dev/null 2>&1 || { \
		echo "test-packages needs macOS with Swift/Xcode; no tests were run."; exit 1; }
	swift test --package-path Packages/SideSign
	swift test --package-path Packages/NativeSigning

# Read-only upstream check for the root Xcode SwiftPM requirements. Dependabot
# reads Package.swift (the three Packages/ manifests in .github/dependabot.yml)
# but not project.pbxproj, so the app's own package requirements are checked here.
# Never edits the project.
#   make audit-packages
audit-packages:
	@python3 Tools/Validation/repository-validation/check-xcode-packages.py

# Style, on demand. Nothing in CI runs SwiftLint any more: the auto-fix commits
# it pushed onto pull requests were noise at best.
# `--strict` promotes warnings to errors, and the tree carries a large pre-existing
# backlog (`line_length` alone counts in the thousands, including files that were
# already in scope), so lint a path you are editing rather than expecting a green
# whole-tree run: `swiftlint --strict VexSign/App/Infrastructure/...`.
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
# Which suites to run. Empty means the whole target, which is what CI runs.
#
#   make test                                  # all 2,300 tests, ~30 min
#   make test SUITE=RenewalScheduleTests       # one class, seconds after the build
#   make test SUITE=RenewalScheduleTests,WebManagerAccessTests
#
# Hand-assembling that `-only-testing` list is what people get wrong (workspace,
# scheme, signing flags, derived-data path), and a mistyped suite silently runs
# zero tests. The comment is the only reason this variable exists.
SUITE ?=
comma := ,
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
	    -skipPackagePluginValidation \
	    -workspace VexSign.xcworkspace \
	    -scheme VexSignTests \
	    -configuration Debug \
	    -destination "$$dest" \
	    -derivedDataPath "$(TMP)/TestDerivedData" \
	    $(if $(strip $(SUITE)),$(foreach suite,$(subst $(comma), ,$(SUITE)),-only-testing:VexSignTests/$(strip $(suite))),-only-testing:VexSignTests) \
	    -parallel-testing-enabled YES \
	    -parallel-testing-worker-count 2 \
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
	cd Services/WebManager/API && $(PYTHON) -m pytest ../Tests/ -q

# Do not silently install or update dependencies during a test run.
test-cloud:
	@before=$$(shasum -a 256 Services/Cloud/openapi.json 2>/dev/null || sha256sum Services/Cloud/openapi.json); \
	(cd Services/Cloud && npm run build && npm test && npm run contracts) && \
	after=$$(shasum -a 256 Services/Cloud/openapi.json 2>/dev/null || sha256sum Services/Cloud/openapi.json); \
	if [ "$$before" != "$$after" ]; then \
		echo "openapi.json was out of date; commit the regenerated Services/Cloud/openapi.json" >&2; \
		git diff -- Services/Cloud/openapi.json; \
		exit 1; \
	fi

# Both service suites, for changes that touch the install server or the cloud API.
# They are separate from `verify` because they need their own toolchains (pip, npm)
# and `verify` must stay runnable on a machine with neither; together they are what
# keeps the documented request/response shapes in WEBTOOLS.md honest.
verify-services: test-server test-cloud

.PHONY: device-smoke
device-smoke:
	@bash Tools/Scripts/device-smoke.sh
