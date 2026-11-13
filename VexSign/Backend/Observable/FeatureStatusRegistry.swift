//
//  FeatureStatusRegistry.swift
//  VexSign
//
//  The end-to-end feature status system. Each major feature is tracked as a
//  pipeline — setting → persisted value → real consumer — with an honest
//  status instead of a blanket "supported".
//
//  Statuses:
//    implemented  The full chain is wired in code and exercised by unit tests
//                 where it can be (Settings → persistence → consumer).
//    needsDevice  Wired end-to-end, but the last mile (signing/installing on
//                 real hardware) could not be validated in CI and needs a
//                 device pass.
//
//  The registry powers Settings → About → Feature Status.
//

import Foundation
import NimbleExtensions

enum FeatureStatus: String, CaseIterable {
	case implemented
	case needsDevice

	var title: String {
		switch self {
		case .implemented: .localized("Implemented")
		case .needsDevice: .localized("Needs device validation")
		}
	}
}

struct FeatureStatusEntry: Identifiable {
	let id: String
	let name: String
	/// The setting / preference that controls it.
	let setting: String
	/// Where the value is persisted.
	let persistedAs: String
	/// The real consumer that acts on it.
	let consumer: String
	let status: FeatureStatus
}

enum FeatureStatusRegistry {
	/// The critical signing/install/update pipeline, in pipeline order.
	static let entries: [FeatureStatusEntry] = [
		FeatureStatusEntry(
			id: "forced-signing",
			name: "Forced signing",
			setting: "Advanced Signing → Force Sign All",
			persistedAs: "Options (signing_options, Core Data / OptionsManager)",
			consumer: "SigningHandler → Zsign",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "sdk-macho",
			name: "SDK spoofing / Mach-O changes",
			setting: "Signing Options → SDK & Mach-O",
			persistedAs: "Options (OptionsManager)",
			consumer: "SigningHandler.modify() → Info.plist & Mach-O patching",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "auto-sign-download",
			name: "Auto-sign on download",
			setting: "Automation → Sign after download",
			persistedAs: "VexSign.autoSign… keys",
			consumer: "DownloadManager → AutoSignManager.sign()",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "compat-optout",
			name: "Compatibility opt-out clearing",
			setting: "Signing Options → Compatibility",
			persistedAs: "Options (OptionsManager)",
			consumer: "SigningHandler.modify() on update/re-sign",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "profile-compatibility",
			name: "Profile compatibility",
			setting: "Signing → Start Signing (preflight) · certificate picker badge",
			persistedAs: "Nothing — computed from the decoded profile, the p12 and the signing options",
			consumer: "PreflightChecks → ProfileCompatibility → PreflightIssue / CertificatesCellView",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "extension-coverage",
			name: "Extension coverage audit",
			setting: "Signing → Remove App Extensions (stripped extensions are never requirements)",
			persistedAs: "Nothing — each nested bundle's Info.plist and embedded.mobileprovision are read per run",
			consumer: "NestedBundleAudit → SigningHandler (signing log) · PreflightChecks / SigningView (coverage target)",
			status: .implemented
		),
		// Separate from the audit above: the audit only reads bundles, this writes a different
		// profile into each extension. No signed app with extension profiles has been installed
		// and launched on a device yet (issue #137 is still open), so it is not "implemented".
		FeatureStatusEntry(
			id: "extension-profiles",
			name: "Per-extension provisioning profiles",
			setting: "Certificates → certificate → Extension Profiles (optional additional profiles)",
			persistedAs: "Profile files beside the certificate's own profile, read per run",
			consumer: "AdditionalProfiles → ProfileApplicationIdentifierMatcher → ZsignEngine (one profile per nested bundle)",
			status: .needsDevice
		),
		FeatureStatusEntry(
			id: "signature-verification",
			name: "Post-sign verification",
			setting: "Signing log (every sign) · Install Without Signing (blocks)",
			persistedAs: "SignatureVerifier.Report on SigningHandler.verification (not persisted)",
			consumer: "SigningHandler.modify → SignatureVerifier → DirectInstaller",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "community-certificates",
			name: "Community certificate catalogue",
			setting: "Settings → Certificates → + → Community Certificates (Unofficial)",
			persistedAs: "UserDefaults nexCerts.acknowledgedHost (the acknowledged host, not a flag)",
			consumer: "NexCerts.fetchCatalog/importCertificate via CommunityCertificatesView",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "backup-encryption",
			name: "Encrypted backup",
			setting: "Settings → Backup & Restore → Create Backup → Password",
			persistedAs: "VEXBK2 container (ContentKey wrapped by password or Keychain backup.deviceKey)",
			consumer: "BackupCrypto.sealFile/unsealFile → BackupManager.makeBackup/open",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "certificate-revocation",
			name: "Certificate revocation check",
			setting: "Settings → Certificates → Certificate Health → Validate with System OCSP",
			persistedAs: "VexSign.certificate.revocationSnapshots (status, detail, date only)",
			consumer: "CertificateInspector (SecPolicyCreateRevocation, OCSP) → CertificateStatusManager",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "webmanager-access",
			name: "Web Manager access control",
			setting: "Settings → Web Manager → Require Password / Allow This Network",
			persistedAs: "VexSign.webManager.{auth,user,pass→Keychain,bindMode,allowUnauthenticatedLAN}",
			consumer: "WebManagerAccessPolicy → WebManagerServer bind + middleware",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "webmanager-cert-export",
			name: "Web Manager certificate export",
			setting: "Settings → Web Manager → Allow Certificate Download",
			persistedAs: "VexSign.webManager.certificateExport",
			consumer: "WebManagerServer.allowsCertificateExport → /api/certs/:uuid/download",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "webmanager-token",
			name: "Web Manager API token",
			setting: "Settings → Web Manager → API Token",
			persistedAs: "Keychain (webManager.apiToken), legacy VexSign.apiToken migrated",
			consumer: "WebManagerAuthMiddleware + WebManagerSensitiveAccessMiddleware",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "per-app-cert",
			name: "Per-app certificate selection",
			setting: "App context → Signing certificate",
			persistedAs: "Per-app options / PerAppUpdateRules.pinnedCertificateUUID",
			consumer: "PackageSigningCoordinator.signPackage(certificate:) → Zsign",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "quick-sign",
			name: "Quick Sign",
			setting: "Home → Quick Sign row",
			persistedAs: "— (immediate action)",
			consumer: "PackageImportService.importPackage → SigningView",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "resign-reinstall",
			name: "Re-sign / re-install",
			setting: "Library → app → Re-sign",
			persistedAs: "— (library action)",
			consumer: "PackageSigningCoordinator.signPackage → InstallQueue",
			status: .needsDevice
		),
		FeatureStatusEntry(
			id: "library-status",
			name: "Library install state & signer identity",
			setting: "Library → row badge · app info → Signature · Signing → Start Signing (preflight)",
			persistedAs: "Nothing persisted — the device answer and the stored bundle's CMS are read on demand and cached for 30 s",
			consumer: "LibraryStatusStore → LibraryCellView / LibraryInfoView · PreflightChecks.signerIdentity → CertificateIdentity → BundleSignature",
			status: .needsDevice
		),
		FeatureStatusEntry(
			id: "asset-modification",
			name: "Asset / file modifications",
			setting: "Signing customization, IPA Explorer",
			persistedAs: "Per-app options + IPA Explorer edits",
			consumer: "SigningHandler / IPAExplorer file replacement",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "dynamic-island",
			name: "Dynamic Island download controls",
			setting: "Downloads settings",
			persistedAs: "Live Activity state (DownloadManager+LiveActivity)",
			consumer: "DownloadProgressAttributes activity + app-group commands",
			status: .needsDevice
		),
		FeatureStatusEntry(
			id: "strict-hiding",
			name: "Strict app hiding",
			setting: "Settings → Security → Hidden Apps Vault",
			persistedAs: "AppLockManager hidden/strictly-hidden sets",
			consumer: "Library / Home filters (lockManager.isStrictlyHidden)",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "tab-structure",
			name: "Custom tab navigation and compact labels",
			setting: "Settings → Tab Bar (launch tab, tab order/visibility, labels)",
			persistedAs: "TabBarPreferences (ordered tabs, hidden tabs, required Home/Settings, showLabels)",
			consumer: "TabbarView / every tab destination",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "appearance",
			name: "Appearance (theme, font, animations)",
			setting: "Settings → Appearance",
			persistedAs: "AppearanceStore (VexSign.visualTheme / fontFamily / fontScale / flareAnimations)",
			consumer: "App root environment, Theme tokens, button styles",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "offline-catalog",
			name: "Offline repository catalog",
			setting: "Automatic (last-known-good snapshots)",
			persistedAs: "SourceSnapshots/ (Application Support)",
			consumer: "SourcesViewModel prefill + stale marking",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "unified-tasks",
			name: "Unified task pipeline",
			setting: "Downloads → Task Center",
			persistedAs: "UnifiedTaskHistory.json (outcomes only)",
			consumer: "DownloadManager mirror, PackageSigningCoordinator.signPackage, InstallQueue",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "per-app-rules",
			name: "Per-app update rules",
			setting: "Updates → context menu → Update Rules",
			persistedAs: "VexSign.perAppUpdateRules",
			consumer: "AppUpdateChecker.precomputeAllUpdates",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "source-health",
			name: "Source health monitoring",
			setting: "App Store → Repositories → Source Health",
			persistedAs: "SourcePreferences health records",
			consumer: "SourcesViewModel refresh outcomes",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "https-sources",
			name: "HTTPS-only repository transport",
			setting: "Settings → Security (HTTP opt-in)",
			persistedAs: "VexSign.sources.allowInsecureHTTP",
			consumer: "SourceURLPolicy (add + refresh)",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "encrypted-backup",
			name: "Encrypted backup & restore",
			setting: "Settings → Backup",
			persistedAs: ".vexbackup (AES-GCM, PBKDF2 200k)",
			consumer: "BackupManager + BackupCrypto",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "download-integrity",
			name: "Download integrity (published size / hash)",
			setting: "The source's own `size` (a hash when a source publishes one)",
			persistedAs: "Download.integrity — in memory, per download, never cached",
			consumer: "DownloadManager.handlePackageFile → DownloadIntegrity → the import gate",
			status: .needsDevice
		),
		FeatureStatusEntry(
			id: "signed-sources",
			name: "Signed repositories (Ed25519 provenance)",
			setting: "A `vexsign` member in the repository's source.json",
			persistedAs: "VexSign.sourceProvenance (badge cache; the check runs every refresh)",
			consumer: "SourceProvenanceVerifier → SourceFeedLoader (refresh refused on a bad signature)",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "install-preflight",
			name: "Install-method preflight",
			setting: "Settings → Installation (method picker + prerequisites)",
			persistedAs: "VexSign.installationMethod · server certificate · pairing file",
			consumer: "InstallPreflight → InstallationView rows",
			status: .implemented
		),
		FeatureStatusEntry(
			id: "scheduled-auto-updates",
			name: "Scheduled automatic update signing",
			setting: "Updates → Favorites & Auto Updates · Sources → Pause Automatic Updates · Automation → Check Frequency",
			persistedAs: "UpdateMatchingPreferences + SourcePreferences + BackgroundAutomationPreferences",
			consumer: "BackgroundAutomation → AppUpdateChecker → UpdateAllManager → InstallQueue",
			status: .needsDevice
		)
	]

	static var implementedCount: Int { entries.filter { $0.status == .implemented }.count }
	static var needsDeviceCount: Int { entries.filter { $0.status == .needsDevice }.count }
}
