// MARK: - SigningErrorMapperTests
/// Unit tests for the SigningErrorMapper error mapping logic.

import Foundation
import Testing
import NimbleExtensions
@testable import VexSign

@Suite("SigningErrorMapper Tests")
struct SigningErrorMapperTests {

    // MARK: - NativeSigning Backend Errors

    @Test("Maps alreadyInUse error correctly")
    func testAlreadyInUse() {
        let error = NativeAccountBackendError.alreadyInUse
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Signing Backend Busy"))
        #expect(mapped.message.contains("already in progress"))
        #expect(mapped.recovery.contains("Activity tab"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps consentRequired error correctly")
    func testConsentRequired() {
        let error = NativeAccountBackendError.consentRequired
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.title == .localized("Consent Required"))
        #expect(mapped.message.contains("Explicit consent"))
        #expect(mapped.recovery.contains("prompt for consent"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps providerFailed error correctly")
    func testProviderFailed() {
        let error = NativeAccountBackendError.providerFailed
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.title == .localized("Anisette Provider Error"))
        #expect(mapped.message.contains("anisette provider failed"))
        #expect(mapped.recovery.contains("Test the provider"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps authenticationFailed error correctly")
    func testAuthenticationFailed() {
        let error = NativeAccountBackendError.authenticationFailed
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.title == .localized("Authentication Failed"))
        #expect(mapped.message.contains("Apple ID authentication failed"))
        #expect(mapped.recovery.contains("Verify your Apple ID"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps unsupportedTeam error correctly")
    func testUnsupportedTeam() {
        let error = NativeAccountBackendError.unsupportedTeam
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Unsupported Team Type"))
        #expect(mapped.message.contains("not supported for free Apple ID"))
        #expect(mapped.recovery.contains("free or individual developer team"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps sessionExpired error correctly")
    func testSessionExpired() {
        let error = NativeAccountBackendError.sessionExpired
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Session Expired"))
        #expect(mapped.message.contains("expired and needs to be refreshed"))
        #expect(mapped.recovery.contains("Sign out and sign in again"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps storageUnavailable error correctly")
    func testStorageUnavailable() {
        let error = NativeAccountBackendError.storageUnavailable
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Secure Storage Unavailable"))
        #expect(mapped.message.contains("Keychain is unavailable"))
        #expect(mapped.recovery.contains("Restart the app"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - NativeSigning Errors

    @Test("Maps backendNotReady error correctly")
    func testBackendNotReady() {
        let error = NativeSigningError.backendNotReady
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Signing Backend Not Ready"))
        #expect(mapped.message.contains("hasn't been initialized"))
        #expect(mapped.recovery.contains("Configure the Anisette Provider"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps providerNotConfigured error correctly")
    func testProviderNotConfigured() {
        let error = NativeSigningError.providerNotConfigured
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.title == .localized("Anisette Provider Not Configured"))
        #expect(mapped.message.contains("No anisette provider is set up"))
        #expect(mapped.recovery.contains("Add a provider"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps noActiveContext error correctly")
    func testNoActiveContext() {
        let error = NativeSigningError.noActiveContext
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("No Active Signing Context"))
        #expect(mapped.message.contains("No Apple ID session is active"))
        #expect(mapped.recovery.contains("Sign in with your Apple ID"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Provisioning Failure Mapping

    @Test("Maps quota exceeded error correctly")
    func testQuotaExceeded() {
        let error = NativeSigningError.provisioningFailed("Quota exceeded: maximum 3 apps reached")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Provisioning Quota Exceeded"))
        #expect(mapped.message.contains("quota limits"))
        #expect(mapped.recovery.contains("Revoke unused apps"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps device not registered error correctly")
    func testDeviceNotRegistered() {
        let error = NativeSigningError.provisioningFailed("Device not found in Apple Developer portal")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Device Not Registered"))
        #expect(mapped.message.contains("not registered"))
        #expect(mapped.recovery.contains("registered in Settings"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps app ID conflict error correctly")
    func testAppIDConflict() {
        let error = NativeSigningError.provisioningFailed("App ID already exists: com.example.app")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("App ID Registration Failed"))
        #expect(mapped.message.contains("could not be registered"))
        #expect(mapped.recovery.contains("bundle identifier format"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps certificate limit error correctly")
    func testCertificateLimit() {
        let error = NativeSigningError.provisioningFailed("Maximum number of certificates reached")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Certificate Limit Reached"))
        #expect(mapped.message.contains("maximum number of development certificates"))
        #expect(mapped.recovery.contains("Revoke an unused development certificate"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps profile limit error correctly")
    func testProfileLimit() {
        let error = NativeSigningError.provisioningFailed("Profile limit exceeded")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Profile Limit Reached"))
        #expect(mapped.message.contains("Maximum number of provisioning profiles"))
        #expect(mapped.recovery.contains("Delete unused profiles"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps expired profile error correctly")
    func testExpiredProfile() {
        let error = NativeSigningError.provisioningFailed("Profile expired on 2024-01-01")
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.title == .localized("Provisioning Profile Expired/Invalid"))
        #expect(mapped.message.contains("expired or not valid"))
        #expect(mapped.recovery.contains("auto-renewal"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Zsign Failure Mapping

    @Test("Maps entitlements not supported error correctly")
    func testEntitlementsNotSupported() {
        let error = NativeSigningError.signingFailed("Entitlement aps-environment not supported")
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.title == .localized("Entitlements Not Supported"))
        #expect(mapped.message.contains("not supported by free Apple ID"))
        #expect(mapped.recovery.contains("Remove unsupported entitlements"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps certificate expired error correctly")
    func testCertificateExpired() {
        let error = NativeSigningError.signingFailed("Certificate expired on 2024-01-01")
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.title == .localized("Certificate Expired or Revoked"))
        #expect(mapped.message.contains("expired, not yet valid, or has been revoked"))
        #expect(mapped.recovery.contains("re-run provisioning"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps bundle ID mismatch error correctly")
    func testBundleIDMismatch() {
        let error = NativeSigningError.signingFailed("Profile bundle ID does not match app")
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.title == .localized("Profile Bundle ID Mismatch"))
        #expect(mapped.message.contains("doesn't match the app's bundle identifier"))
        #expect(mapped.recovery.contains("bundle ID matches"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps architecture error correctly")
    func testArchitectureError() {
        let error = NativeSigningError.signingFailed("lipo: can't figure out architecture")
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.title == .localized("Architecture Error"))
        #expect(mapped.message.contains("Failed to process the app's architectures"))
        #expect(mapped.recovery.contains("Enable 'Thin Mach-O Binaries'"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps IPA archive error correctly")
    func testIPAArchiveError() {
        let error = NativeSigningError.signingFailed("Zip file corrupted")
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.title == .localized("IPA Archive Error"))
        #expect(mapped.message.contains("corrupt, not a valid archive"))
        #expect(mapped.recovery.contains("Re-download the IPA"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Installation Failure Mapping

    @Test("Maps TrollStore error correctly")
    func testTrollStoreError() {
        let error = NativeSigningError.installationFailed("trollstore://install failed")
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.title == .localized("TrollStore Installation Failed"))
        #expect(mapped.message.contains("TrollStore could not install"))
        #expect(mapped.recovery.contains("TrollStore is installed"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps pairing error correctly")
    func testPairingError() {
        let error = NativeSigningError.installationFailed("Pairing file missing")
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.title == .localized("Device Pairing Required"))
        #expect(mapped.message.contains("not paired or the pairing file is missing"))
        #expect(mapped.recovery.contains("Settings → Installation → Pairing File"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps HTTPS SSL error correctly")
    func testHTTPSError() {
        let error = NativeSigningError.installationFailed("SSL certificate verify failed")
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.title == .localized("HTTPS Installation Error"))
        #expect(mapped.message.contains("HTTPS server certificate is not trusted"))
        #expect(mapped.recovery.contains("export the Root CA profile"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps network error correctly")
    func testNetworkError() {
        let error = NativeSigningError.installationFailed("Connection timeout")
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.title == .localized("Network Error"))
        #expect(mapped.message.contains("Could not reach the installation server"))
        #expect(mapped.recovery.contains("same Wi-Fi"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps already installed error correctly")
    func testAlreadyInstalled() {
        let error = NativeSigningError.installationFailed("App already installed")
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.title == .localized("App Already Installed"))
        #expect(mapped.message.contains("already installed"))
        #expect(mapped.recovery.contains("Delete the existing app"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Keychain Error Mapping

    @Test("Maps errSecAuthFailed correctly")
    func testKeychainAuthFailed() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -25291, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Authentication Failed"))
        #expect(mapped.message.contains("Keychain authentication failed"))
        #expect(mapped.recovery.contains("Face ID/Touch ID"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps errSecItemNotFound correctly")
    func testKeychainItemNotFound() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -25292, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Certificate/Key Not Found"))
        #expect(mapped.message.contains("not found in the Keychain"))
        #expect(mapped.recovery.contains("Re-import the .p12"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps errSecDuplicateItem correctly")
    func testKeychainDuplicateItem() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -25293, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Duplicate Keychain Item"))
        #expect(mapped.message.contains("already exists in the Keychain"))
        #expect(mapped.recovery.contains("Delete the existing certificate"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps errSecInteractionNotAllowed correctly")
    func testKeychainInteractionNotAllowed() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -25294, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Keychain Access Denied"))
        #expect(mapped.message.contains("not allowed to access the Keychain"))
        #expect(mapped.recovery.contains("Unlock the device"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Network Error Mapping

    @Test("Maps NSURLErrorNotConnectedToInternet correctly")
    func testNotConnectedToInternet() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.title == .localized("No Internet Connection"))
        #expect(mapped.message.contains("not connected to the internet"))
        #expect(mapped.recovery.contains("Connect to Wi-Fi"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps NSURLErrorTimedOut correctly")
    func testTimedOut() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Request Timed Out"))
        #expect(mapped.message.contains("timed out"))
        #expect(mapped.recovery.contains("Check your internet connection"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps NSURLErrorCannotFindHost correctly")
    func testCannotFindHost() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Cannot Reach Server"))
        #expect(mapped.message.contains("Could not connect to the server"))
        #expect(mapped.recovery.contains("anisette provider URL"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps NSURLErrorBadServerResponse correctly")
    func testBadServerResponse() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Invalid Server Response"))
        #expect(mapped.message.contains("unexpected response"))
        #expect(mapped.recovery.contains("Apple server issue"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Storage Error Mapping

    @Test("Maps NSFileReadNoSuchFileError correctly")
    func testFileNotFound() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("File Not Found"))
        #expect(mapped.message.contains("required file"))
        #expect(mapped.recovery.contains("Re-import the missing file"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps NSFileWriteNoPermissionError correctly")
    func testPermissionDenied() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Permission Denied"))
        #expect(mapped.message.contains("doesn't have permission"))
        #expect(mapped.recovery.contains("Restart the app"))
        #expect(mapped.isRecoverable == true)
    }

    @Test("Maps NSFileWriteOutOfSpaceError correctly")
    func testOutOfSpace() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        let mapped = SigningErrorMapper.map(error, context: .general)

        #expect(mapped.title == .localized("Out of Storage Space"))
        #expect(mapped.message.contains("storage is full"))
        #expect(mapped.recovery.contains("Free up space"))
        #expect(mapped.isRecoverable == true)
    }

    // MARK: - Context-Specific Defaults

    @Test("Returns correct default message for authentication context")
    func testAuthenticationContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .authentication)

        #expect(mapped.message == .localized("Failed to authenticate with Apple ID."))
        #expect(mapped.recovery == .localized("Verify credentials, check 2FA, ensure internet connection."))
    }

    @Test("Returns correct default message for provisioning context")
    func testProvisioningContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .provisioning)

        #expect(mapped.message == .localized("Failed to provision the app with Apple."))
        #expect(mapped.recovery == .localized("Check device registration, App ID limits, and quota. Retry provisioning."))
    }

    @Test("Returns correct default message for signing context")
    func testSigningContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .signing)

        #expect(mapped.message == .localized("Failed to sign the IPA."))
        #expect(mapped.recovery == .localized("Check certificate/profile validity, entitlements, and architecture settings."))
    }

    @Test("Returns correct default message for installation context")
    func testInstallationContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .installation)

        #expect(mapped.message == .localized("Failed to install the app on the device."))
        #expect(mapped.recovery == .localized("Check installation method, device pairing, and network connectivity."))
    }

    @Test("Returns correct default message for certificate status context")
    func testCertificateStatusContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .certificateStatus)

        #expect(mapped.message == .localized("Failed to check certificate revocation status."))
        #expect(mapped.recovery == .localized("Ensure internet for OCSP/CRL. Grant consent if prompted."))
    }

    @Test("Returns correct default message for background automation context")
    func testBackgroundAutomationContextDefaults() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "test"])
        let mapped = SigningErrorMapper.map(error, context: .backgroundAutomation)

        #expect(mapped.message == .localized("Background automation encountered an error."))
        #expect(mapped.recovery == .localized("Check automation history. Run manually from Settings → Automation."))
    }
}