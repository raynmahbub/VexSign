# Diagnostics, Crash Reporting and Performance Monitoring — implementation note

**Date:** 2026-11-26  
**Branch:** `arena/d2c05cf4-vexsign` (session branch; requested name `feature/diagnostics-observability` was not created automatically)  
**Scope:** app health, signing, IPA import, downloads, networking, device connectivity, installation, background work, automation, security validation, crash/hang diagnostics, performance instrumentation, troubleshooting UI, and export.

This note records what was actually inspected, what was changed, what was verified, and what can only be verified on a physical device. It is not a compliance certificate and does not claim production crash capture.

## 1. Audit of the current branch

Reviewed before editing: `VexSign/Services/Diagnostics/*`, `VexSign/Shared/Errors/VexSignError.swift`, `VexSign/Shared/Models/Results/OperationOutcome.swift`, `VexSign/Services/Tasks/*`, `VexSign/App/*`, `VexSign/Networking/*`, `VexSign/Features/Dashboard/{About,Diagnostics}/*`, `Config/BuildSettings/iOS/Info.plist`, `Makefile`, and `.github/workflows/ci.yml`.

Findings and disposition:

| Finding before this task | Disposition |
|---|---|
| Three Logger subsystems (`com.vexsign.app`, `com.vexsign`, `app.vexsign`) and only two signpost sites (`SourceFeedLoader`, `SourceCatalogStore`) | Structured events now use one stable per-category subsystem (`app.vexsign.<category>`); `OSSignposter` intervals added to package/firmware downloads. Existing signposts were left intact. |
| `VexSignError.log` interpolated message, context and underlying text as `.public` | Fixed: fixed code/category are public; every dynamic value is redacted and `.private`. `errorDescription` is redacted too. |
| No MetricKit subscriber or diagnostic payload handling | Added a local-only `MXMetricManagerSubscriber`; no crash SDK and no uploader. |
| Outcome records existed (bounded to 200), but there was no flat diagnostic history with stable codes and filters | `DiagnosticEvent` + bounded `DiagnosticEventJournal` added beside the existing outcome journal; the composition root writes both from one recorder closure. |
| Task-center failures were visible in history but not exportable as correlated diagnostic events | Terminal task transitions now emit events with the real task ID; `TaskCorrelationService` maps IDs to existing task titles for the UI. |
| Network failures logged host/error text without a structured safe context | `NetworkTransferAdapter` records scheme/host/port only (`URL.logSafeDescription`), HTTP status, phase and observed transfer duration. |
| Diagnostics Center had no event list, filters or MetricKit status | New native SwiftUI Troubleshooting Center with real events, categories/date/operation filters, task titles, MetricKit counts and filtered export. |
| Export had no structured events or filters | `diagnostic-events.json`, `filter.json` and filtered `operations.json` added; filtered exports omit free-form logs. |

Existing bounded stores were reused: `OperationOutcomeJournal` (200 records) and `UnifiedTaskCenter.historyLimit` (200 tasks) were not duplicated. The new journal is bounded to 250 events and 512 KB with one rotated generation.

## 2. Reference-source inspection and reuse decision

Every reference below was inspected through GitHub or Apple documentation. Licences were read before any reuse decision. **No source was copied, and no dependency was added.**

| Capability | Reference source | Implementation inspected | VexSign integration point | Required changes / decision | Validation |
|---|---|---|---|---|---|
| Stable subsystem/category logging | Apple, [Logging](https://developer.apple.com/documentation/os/logging); AltStore `AltStoreCore/Extensions/Logger+AltStore.swift` (AGPL-3.0) | Apple's unified logging guidance; AltStore's hardcoded `com.rileytestut.AltStore` subsystem avoids per-user bundle identifiers | `DiagnosticRecorder.emitToUnifiedLog`, `DiagnosticCategory.subsystem` | Use a fixed `app.vexsign.<category>` subsystem; public codes, private dynamic text. No AltStore code copied. | `test_diagnostics_observability_contracts.py`, `test_logging_message_policy.py` |
| Structured event identity and error codes | AltStore `AltStore/Operations/Errors/VerificationError.swift` and `OperationError.swift` (AGPL-3.0); SideStore `SideStore/Utils/dignostics/errors/ErrorProcessing.swift` (AGPL-3.0) | Grouped numeric/category codes, localized user descriptions, non-fatal user-friendly mappings | `DiagnosticEventCode`, `DiagnosticEvent`, `ErrorBoundary.classify`, `DiagnosticRecoveryGuide` | Stable `VEX-*` codes for known conditions; per-occurrence UUID. Existing `VexSignError` remains the only error hierarchy. | `DiagnosticEventTests` |
| Task/operation correlation | AltStore `ErrorLogViewController.swift` / `LoggedError` patterns; VexSign `UnifiedTaskCenter`, `TaskContext` | User-visible error log with task history; VexSign already stores `signingTaskID`/`importTaskID` | `UnifiedTaskCenter.transition`, `TaskCorrelationService`, `TroubleshootingCenterViewModel` | Terminal task failures/cancellations emit events; IDs map to real task titles. No guessed titles. | `test_diagnostics_observability_contracts.py`, `DiagnosticEventTests` |
| Crash / hang / CPU / launch diagnostics | Apple, [MetricKit](https://developer.apple.com/documentation/metrickit), [MXDiagnosticPayload](https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload), [MXMetricManagerSubscriber](https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber), [MXCrashDiagnostic](https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic), [MXHangDiagnostic](https://developer.apple.com/documentation/metrickit/mxhangdiagnostic), [MXAppLaunchDiagnostic](https://developer.apple.com/documentation/metrickit/mxapplaunchdiagnostic), [MXCPUExceptionDiagnostic](https://developer.apple.com/documentation/metrickit/mxcpuexceptiondiagnostic) | Payload delivery model and diagnostic subclasses; call stacks are available but were deliberately not read | `MetricKitDiagnosticsService`, `AppDelegate` registration, Troubleshooting Center counts | Records counts, time windows and measured durations only. No `jsonRepresentation`, no call stacks, no cloud upload, no claim of immediate capture. iOS controls delivery; a simulator receives no device reports. | Contract test; device validation still required |
| Optional external crash reporting / privacy options | Sentry Cocoa `Sources/SentryObjCCompat/SentryObjCPrivacyOptions.swift`, `SentryObjCMetricKitOptions.swift` (MIT, `LICENSE.md`) | `maskAllText`, view masking, opt-in MetricKit report selection | Decision recorded here; no code path | Rejected for now: external upload is not requested/authorized, and adding an SDK would change the privacy posture. Native MetricKit covers supported diagnostics locally. | `test_no_third_party_crash_or_network_debugger_dependency` |
| Signposted intervals and performance tests | Apple, [OSSignposter](https://developer.apple.com/documentation/os/ossignposter), [XCTest Performance Tests](https://developer.apple.com/documentation/xctest/performance-tests) | `beginInterval`/`endInterval`, `OSSignposter(logger:)`, `XCTClockMetric`/`XCTOSSignpostMetric` | `DiagnosticStopwatch`, `NetworkTransferAdapter`, `VexSignTests/.../DiagnosticFilterAndTimingTests.swift` | Real `ContinuousClock` durations plus Instruments intervals. No synthetic measurements, no thresholds asserted without a baseline. | Contract test; Instruments/XCTest baselines require Xcode |
| Safe network diagnostics | Pulse `Sources/Pulse/NetworkLogger/NetworkLogger+Redacting.swift` (MIT); Netfox (`LICENSE`, MIT) | Pulse redacts sensitive headers and query items; netfox is an on-device traffic viewer | `NetworkTransferAdapter`, `LogRedaction`, `URL.logSafeDescription` | Host/scheme/port, HTTP status, byte cap and observed duration only; never query, path, auth header or full URL. Production TLS unchanged; no MITM proxy. | Contract test, `test_logging_message_policy.py` |
| In-app log viewer / export UI | OSLogViewer `README.md`, `LICENCE.md` (MIT, Wesley de Groot) | SwiftUI OSLog history viewer/export concept | `TroubleshootingCenterView`, `DiagnosticBundleExporter` | Native view over VexSign's own journal, not an OSLog readout dependency: the app's structured events can be filtered and correlated with tasks. No OSLogViewer code copied. | Contract test |
| Signing / certificate workflow diagnostics | Feather `Feather/Utilities/Handlers/SigningHandler.swift`, `Feather/Utilities/CertificateReader.swift` (GPL-3.0); prior AltStore operation review | Operation-scoped UUID logging and OSLog categories; no raw signing-output reuse | `AutoSignManager` → `OperationOutcomeRecording` → `DiagnosticEvent.fromOutcome` | Existing VexSign signing stages are already instrumented; the new bridge makes them exportable and correlates by operation ID. | `DiagnosticEventTests`, contract test |

## 3. What was implemented

1. **Structured model** — `DiagnosticEvent.swift`: severity, category, stable code, occurrence ID, operation/task ID, timestamp, safe user text, developer detail, recovery suggestion, redacted metadata; sanitizer enforces length, key/ID shape and `LogRedaction`.
2. **Bounded journal** — `DiagnosticEventJournal.swift`: protected atomic writes, 250-event and 512 KB caps, one rotated generation, unversioned-array migration, corrupt-file quarantine, and filter-aware export.
3. **Privacy-aware logging** — `DiagnosticRecorder.swift` writes a structured OSLog line with public codes and private dynamic text, then persists through an injected closure. `VexSignError.log`/`errorDescription` no longer expose raw context.
4. **Correlation** — the composition root bridges every existing sign/import/install/download outcome into the event journal; terminal task-center transitions emit task-ID events; a service maps IDs to existing task titles.
5. **Crash/hang/CPU/launch** — `MetricKitDiagnosticsService.swift` registers `MXMetricManager.shared`, records only counts/measurements/time windows, and never reads call stacks or raw payloads.
6. **Performance** — `DiagnosticStopwatch.swift` combines `OSSignposter` intervals with `ContinuousClock` durations; package/firmware transfers are measured end-to-end.
7. **Network safety** — validated URL/transfer phases emit scheme/host/port, status, byte-phase and observed duration; no query, path or header values.
8. **Background and automation** — `AppDelegate` records launch, scheduling failures, unexpected task types and missing maintenance results with real task identifiers; `PersistentAutomationEngine` emits `VEX-AUTO-001` for failed scheduled jobs.
9. **Device connectivity and security validation** — `DeviceRegistryService.recordFailure` emits `VEX-DEV-001` with a stable failure code (never a UDID); failing (not unsupported) `SecurityDiagnosticsService` checks emit one event per check per service instance.
10. **UI** — Troubleshooting Center shows journal events, real task titles, MetricKit counts (or an honest empty state), category/date/task filters and a filtered export action.
11. **Export** — `DiagnosticBundleExporter` adds `diagnostic-events.json`, applies filters to events and outcomes, writes `filter.json`, and omits free-form logs for filtered exports.
12. **Recovery guidance** — every `VexSignError.Code` branch maps to static text naming a control that exists (Certificates, Task Center, Devices, Downloads, Repositories, Backup & Restore, Troubleshooting Center).
13. **Tests/CI** — Swift unit tests for sanitizer/journal/filters/timing plus a portable wiring contract registered in `Makefile` and `.github/workflows/ci.yml`.

## 4. Validation and limits

Actual validation on this checkout:

- `python3 Tools/Audit/test_diagnostics_observability_contracts.py`: **13 tests OK**.
- `make verify`: **83 gate(s) passed** (the new contract gate is included). The only advisory is `swiftc not found`, so Swift syntax checking was skipped.
- `make docs-check`: links OK, 8 docs tests OK, compatibility aliases/resolution files identical.
- Tree-sitter parse of 118 changed Swift files: **0 parse errors**. This is a parse check, not a compile or type-check.
- `git diff --check`: clean.
- `gh run list --branch arena/d2c05cf4-vexsign`: **no runs found**. No GitHub Actions run was triggered or completed in this session; no push was performed. CI results cannot be claimed from the local gates.

Where the sandbox has no Swift/Xcode toolchain, Swift syntax checking in `make verify` is advisory only: tree-sitter parsing and portable gates are **not** a compile, type-check or XCTest run.

Physical-device-only or production-only facts:

- MetricKit reports depend on iOS delivery, a real device and time; a zero count in the UI is not evidence that no crash occurred.
- Instruments signpost timelines and XCTest performance baselines require Xcode and a chosen device; no thresholds or baseline numbers are asserted here.
- Crash capture for crashes that terminate the process before any app callback remains system-controlled.
- External crash upload, cloud sync and network interception are deliberately absent; adding them needs a separate privacy/consent decision.

## 5. Manual device checklist

1. Install on a physical device, trigger a signing failure and confirm a `VEX-SIGN-*` event appears; correlate its operation ID with Task Center.
2. Fail a package download (offline, oversized, HTTP downgrade) and confirm the export contains host-only context and an HTTP status, never a query or path.
3. Record a `log stream --predicate 'subsystem BEGINSWITH "app.vexsign"'` session and confirm public codes are readable while detail is private.
4. After system-delivered MetricKit reports arrive, confirm the Troubleshooting Center count rises and that no call stacks appear in the export.
5. Export filtered and unfiltered bundles; confirm `filter.json`, `diagnostic-events.json` and `operations.json` reflect only the selected scope, and that filtered bundles contain no `logs.txt`/`activity.txt`.

## 6. Follow-ups not performed here

- Migrate to `MetricManager` (iOS 27+) async sequences when the deployment target moves; the subscriber used here matches iOS 17 but is deprecated in newer SDKs.
- Add XCTest/XCTMetric baselines only after measuring a real device with Xcode.
- Decide explicitly, with consent/privacy review, whether any external crash reporting is ever wanted.
