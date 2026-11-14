// MARK: - SigningErrorMapper
/// Maps low-level errors (Apple portal, Zsign, Keychain, network) to
/// user-friendly, actionable messages with recovery guidance.

import Foundation
import CoreData
import NativeSigning
import NimbleExtensions

struct SigningErrorMapper {
    /// Maps any error to a user-friendly SigningError with recovery suggestions.
    static func map(_ error: Error, context: SigningContext = .general) -> SigningError {
        let nsError = error as NSError

        // NativeSigning backend errors
        if let nativeError = error as? NativeAccountBackendError {
            return mapNativeBackendError(nativeError, context: context)
        }

        // NativeSigning specific errors
        if let signingError = error as? NativeSigningError {
            return mapNativeSigningError(signingError, context: context)
        }

        // Keychain errors
        if isKeychainError(nsError) {
            return mapKeychainError(nsError, context: context)
        }

        // Network/Transport errors
        if isNetworkError(nsError) {
            return mapNetworkError(nsError, context: context)
        }

        // Zsign/Crypto errors
        if isZsignError(nsError) || isCryptoError(nsError) {
            return mapZsignFailure(nsError.localizedDescription, context: context)
        }

        // Core Data / Storage errors
        if isStorageError(nsError) {
            return mapStorageError(nsError, context: context)
        }

        // Generic fallback
        return SigningError(
            title: error.localizedDescription,
            message: context.defaultMessage,
            recovery: context.defaultRecovery,
            isRecoverable: true
        )
    }

    // MARK: - NativeSigning Backend Errors

    private static func mapNativeBackendError(_ error: NativeAccountBackendError, context: SigningContext) -> SigningError {
        switch error {
        case .alreadyInUse:
            return SigningError(
                title: .localized("Signing Backend Busy"),
                message: .localized("Another signing operation is already in progress. Please wait for it to complete or cancel it first."),
                recovery: .localized("Check the Activity tab for running tasks and cancel if needed, then retry."),
                isRecoverable: true
            )
        case .busy:
            return SigningError(
                title: .localized("Operation In Progress"),
                message: .localized("The native signing backend is currently processing another request."),
                recovery: .localized("Wait a moment and retry. If stuck, restart the app."),
                isRecoverable: true
            )
        case .closed:
            return SigningError(
                title: .localized("Backend Unavailable"),
                message: .localized("The signing backend has been shut down. This may happen after signing out or a configuration change."),
                recovery: .localized("Go to Settings → Signing Methods and re-configure the Free Apple ID provider."),
                isRecoverable: true
            )
        case .unsupportedRuntime:
            return SigningError(
                title: .localized("Unsupported Environment"),
                message: .localized("Native signing requires the primary VexSign app runtime. It is not available in guest or prototype builds."),
                recovery: .localized("Ensure you are running the standard VexSign app, not a guest/embedded build."),
                isRecoverable: false
            )
        case .invalidConfiguration:
            return SigningError(
                title: .localized("Invalid Configuration"),
                message: .localized("The anisette provider or backend configuration is invalid."),
                recovery: .localized("Check Settings → Signing Methods → Free Apple ID → Anisette Provider. Ensure the endpoint is correct and reachable."),
                isRecoverable: true
            )
        case .consentRequired:
            return SigningError(
                title: .localized("Consent Required"),
                message: .localized("Explicit consent is required before the anisette provider can be contacted."),
                recovery: .localized("The app will prompt for consent automatically. If not, try signing in again."),
                isRecoverable: true
            )
        case .providerChanged:
            return SigningError(
                title: .localized("Provider Configuration Changed"),
                message: .localized("The anisette provider configuration has changed since the operation started."),
                recovery: .localized("Restart the authentication flow from Settings → Signing Methods."),
                isRecoverable: true
            )
        case .providerFailed:
            return SigningError(
                title: .localized("Anisette Provider Error"),
                message: .localized("The anisette provider failed to return valid headers. This may be a server issue or network problem."),
                recovery: .localized("Test the provider in Settings → Signing Methods → Free Apple ID → Anisette Provider. Check server logs if self-hosted."),
                isRecoverable: true
            )
        case .accountAlreadyActive:
            return SigningError(
                title: .localized("Account Already Signed In"),
                message: .localized("An Apple ID session is already active. Sign out first to switch accounts."),
                recovery: .localized("Go to Settings → Signing Methods → Free Apple ID and tap Sign Out, then sign in with the new account."),
                isRecoverable: true
            )
        case .noSavedAccount:
            return SigningError(
                title: .localized("No Saved Session"),
                message: .localized("No previous Apple ID session was found to resume."),
                recovery: .localized("Sign in with your Apple ID from Settings → Signing Methods → Free Apple ID."),
                isRecoverable: true
            )
        case .resumeRequired:
            return SigningError(
                title: .localized("Session Resume Required"),
                message: .localized("The previous session requires explicit resume due to a cleanup or configuration change."),
                recovery: .localized("Sign out and sign in again to establish a fresh session."),
                isRecoverable: true
            )
        case .cleanupRequired:
            return SigningError(
                title: .localized("Cleanup Required"),
                message: .localized("Previous operations left incomplete state that needs cleanup before proceeding."),
                recovery: .localized("Go to Settings → Signing Methods → Diagnostics and tap 'Check Native Signing Health', then retry."),
                isRecoverable: true
            )
        case .authenticationFailed:
            return SigningError(
                title: .localized("Authentication Failed"),
                message: .localized("Apple ID authentication failed. This may be due to incorrect credentials, 2FA issues, or Apple server problems."),
                recovery: .localized("Verify your Apple ID and password. Ensure 2FA is working. Check Apple System Status page for outages."),
                isRecoverable: true
            )
        case .unsupportedTeam:
            return SigningError(
                title: .localized("Unsupported Team Type"),
                message: .localized("The selected team type is not supported for free Apple ID signing (e.g., enterprise teams)."),
                recovery: .localized("Select a free or individual developer team. Enterprise teams require paid certificates."),
                isRecoverable: true
            )
        case .sessionExpired:
            return SigningError(
                title: .localized("Session Expired"),
                message: .localized("The Apple ID session has expired and needs to be refreshed."),
                recovery: .localized("Sign out and sign in again to establish a new session."),
                isRecoverable: true
            )
        case .storageUnavailable:
            return SigningError(
                title: .localized("Secure Storage Unavailable"),
                message: .localized("The Keychain is unavailable. This may happen after a device restart or if Keychain access was revoked."),
                recovery: .localized("Restart the app. If persistent, restart the device. Check Settings → Face ID & Passcode for Keychain access."),
                isRecoverable: true
            )
        }
    }

    // MARK: - NativeSigning Errors

    private static func mapNativeSigningError(_ error: NativeSigningError, context: SigningContext) -> SigningError {
        switch error {
        case .backendNotReady:
            return SigningError(
                title: .localized("Signing Backend Not Ready"),
                message: .localized("The native signing backend hasn't been initialized yet."),
                recovery: .localized("Configure the Anisette Provider in Settings → Signing Methods → Free Apple ID, then try again."),
                isRecoverable: true
            )
        case .providerNotConfigured:
            return SigningError(
                title: .localized("Anisette Provider Not Configured"),
                message: .localized("No anisette provider is set up. Free Apple ID signing requires an anisette server."),
                recovery: .localized("Add a provider in Settings → Signing Methods → Free Apple ID → Anisette Provider."),
                isRecoverable: true
            )
        case .noActiveContext:
            return SigningError(
                title: .localized("No Active Signing Context"),
                message: .localized("No Apple ID session is active. You must sign in first."),
                recovery: .localized("Sign in with your Apple ID from Settings → Signing Methods → Free Apple ID."),
                isRecoverable: true
            )
        case .noSelectedTeam:
            return SigningError(
                title: .localized("No Team Selected"),
                message: .localized("Authentication succeeded but no team was selected."),
                recovery: .localized("Complete the team selection step during sign-in, or sign out and sign in again."),
                isRecoverable: true
            )
        case .provisioningFailed(let msg):
            return mapProvisioningFailure(msg, context: context)
        case .signingFailed(let msg):
            return mapZsignFailure(msg, context: context)
        case .installationFailed(let msg):
            return mapInstallationFailure(msg, context: context)
        }
    }

    private static func mapProvisioningFailure(_ message: String, context: SigningContext) -> SigningError {
        let lower = message.lowercased()

        // Specific limits first: "certificate limit" and "profile limit" also
        // contain the generic words matched by the quota branch below.
        if lower.contains("certificate") && (lower.contains("limit") || lower.contains("max")) {
            return SigningError(
                title: .localized("Certificate Limit Reached"),
                message: .localized("You have reached the maximum number of development certificates for this team."),
                recovery: .localized("Revoke an unused development certificate in the Apple Developer portal (Certificates → Development), then retry."),
                isRecoverable: true
            )
        }

        if lower.contains("profile") && (lower.contains("limit") || lower.contains("max")) {
            return SigningError(
                title: .localized("Profile Limit Reached"),
                message: .localized("Maximum number of provisioning profiles reached for this team."),
                recovery: .localized("Delete unused profiles in the Apple Developer portal (Profiles → Development), then retry."),
                isRecoverable: true
            )
        }

        if lower.contains("device") && (lower.contains("not found") || lower.contains("invalid") || lower.contains("unregistered")) {
            return SigningError(
                title: .localized("Device Not Registered"),
                message: .localized("The device UDID is not registered with your Apple Developer account, or the registration failed."),
                recovery: .localized("Ensure the device is registered in Settings → Signing Methods during provisioning, or register it manually in the Apple Developer portal."),
                isRecoverable: true
            )
        }

        if lower.contains("app id") && (lower.contains("not found") || lower.contains("invalid") || lower.contains("duplicate") || lower.contains("already exists") || lower.contains("conflict")) {
            return SigningError(
                title: .localized("App ID Registration Failed"),
                message: .localized("The bundle identifier could not be registered. It may already exist, be invalid, or exceed limits."),
                recovery: .localized("Check the bundle identifier format (reverse DNS). If it exists, try a different one or revoke the old App ID in the Apple Developer portal."),
                isRecoverable: true
            )
        }

        if lower.contains("quota") || lower.contains("limit") || lower.contains("maximum") {
            return SigningError(
                title: .localized("Provisioning Quota Exceeded"),
                message: .localized("Apple has rejected the provisioning request due to quota limits (e.g., max 3 apps, 100 devices, 10 App IDs)."),
                recovery: .localized("Revoke unused apps/devices/App IDs from the Apple Developer portal, then retry. Free accounts are limited to 3 active apps."),
                isRecoverable: true
            )
        }

        if lower.contains("expired") || lower.contains("not valid") {
            return SigningError(
                title: .localized("Provisioning Profile Expired/Invalid"),
                message: .localized("The provisioning profile is expired or not valid for the current date/device."),
                recovery: .localized("The app will attempt auto-renewal. If manual, re-run provisioning from Settings → Signing Methods."),
                isRecoverable: true
            )
        }

        return SigningError(
            title: .localized("Provisioning Failed"),
            message: message,
            recovery: .localized("Check the Activity Log for details. Common issues: quota limits, device registration, App ID conflicts, or network errors."),
            isRecoverable: true
        )
    }

    private static func mapZsignFailure(_ message: String, context: SigningContext) -> SigningError {
        let lower = message.lowercased()

        if lower.contains("entitlement") || lower.contains("aps-environment") || lower.contains("keychain") || lower.contains("icloud") || lower.contains("app.group") {
            return SigningError(
                title: .localized("Entitlements Not Supported"),
                message: .localized("The app requests entitlements not supported by free Apple ID provisioning (push notifications, iCloud, App Groups, Keychain sharing)."),
                recovery: .localized("Remove unsupported entitlements from the app, or use a paid certificate which supports all entitlements."),
                isRecoverable: true
            )
        }

        if lower.contains("certificate") && (lower.contains("expired") || lower.contains("not valid") || lower.contains("revoked")) {
            return SigningError(
                title: .localized("Certificate Expired or Revoked"),
                message: .localized("The signing certificate is expired, not yet valid, or has been revoked by Apple."),
                recovery: .localized("For free Apple ID: re-run provisioning to create a new certificate. For paid: import a valid .p12/.mobileprovision."),
                isRecoverable: true
            )
        }

        if lower.contains("profile") && (lower.contains("mismatch") || lower.contains("not match") || lower.contains("bundle")) {
            return SigningError(
                title: .localized("Profile Bundle ID Mismatch"),
                message: .localized("The provisioning profile doesn't match the app's bundle identifier."),
                recovery: .localized("Ensure the app's bundle ID matches the one used during provisioning. Re-run provisioning with the correct bundle ID."),
                isRecoverable: true
            )
        }

        if lower.contains("architecture") || lower.contains("thin") || lower.contains("arm64") || lower.contains("lipo") {
            return SigningError(
                title: .localized("Architecture Error"),
                message: .localized("Failed to process the app's architectures. This may happen with universal binaries or unsupported architectures."),
                recovery: .localized("Enable 'Thin Mach-O Binaries' in signing options to strip non-ARM64 slices, or ensure the app has ARM64 code."),
                isRecoverable: true
            )
        }

        if lower.contains("zip") || lower.contains("archive") || lower.contains("extract") || lower.contains("corrupt") {
            return SigningError(
                title: .localized("IPA Archive Error"),
                message: .localized("The IPA file is corrupt, not a valid archive, or uses unsupported compression."),
                recovery: .localized("Re-download the IPA from a trusted source. Ensure it's a valid .ipa file, not a .zip or other format."),
                isRecoverable: true
            )
        }

        return SigningError(
            title: .localized("Signing Failed"),
            message: message,
            recovery: .localized("Check Activity Log for the exact failing step. Common fixes: enable Thin Mach-O, check entitlements, verify certificate/profile validity."),
            isRecoverable: true
        )
    }

    private static func mapInstallationFailure(_ message: String, context: SigningContext) -> SigningError {
        let lower = message.lowercased()

        if lower.contains("trollstore") {
            return SigningError(
                title: .localized("TrollStore Installation Failed"),
                message: .localized("TrollStore could not install the app. It may not be installed, the IPA may be incompatible, or the URL scheme failed."),
                recovery: .localized("Ensure TrollStore is installed on iOS 14.0–16.6.1. Try opening TrollStore manually first. The IPA must be properly signed."),
                isRecoverable: true
            )
        }

        if lower.contains("pairing") || lower.contains("trust") || lower.contains("lockdown") {
            return SigningError(
                title: .localized("Device Pairing Required"),
                message: .localized("The device is not paired or the pairing file is missing/invalid."),
                recovery: .localized("Go to Settings → Installation → Pairing File and import a valid pairing file from Xcode or Apple Configurator."),
                isRecoverable: true
            )
        }

        if lower.contains("https") || lower.contains("ssl") || lower.contains("tls") || lower.contains("certificate") {
            return SigningError(
                title: .localized("HTTPS Installation Error"),
                message: .localized("The local HTTPS server certificate is not trusted by the device."),
                recovery: .localized("Go to Settings → Installation → Server & SSL, export the Root CA profile, install it in Settings → General → VPN & Device Management, and enable Full Trust."),
                isRecoverable: true
            )
        }

        if lower.contains("network") || lower.contains("connection") || lower.contains("timeout") || lower.contains("unreachable") {
            return SigningError(
                title: .localized("Network Error"),
                message: .localized("Could not reach the installation server. The device and computer must be on the same network."),
                recovery: .localized("Ensure both device and computer are on the same Wi-Fi. Check firewall settings. Try USB pairing instead."),
                isRecoverable: true
            )
        }

        if lower.contains("already installed") || lower.contains("duplicate") {
            return SigningError(
                title: .localized("App Already Installed"),
                message: .localized("An app with the same bundle identifier is already installed on the device."),
                recovery: .localized("Delete the existing app from the device first, then retry installation. Or use a different bundle ID."),
                isRecoverable: true
            )
        }

        return SigningError(
            title: .localized("Installation Failed"),
            message: message,
            recovery: .localized("Check the installation method (HTTPS, USB/IDevice, TrollStore). Verify device connectivity and pairing."),
            isRecoverable: true
        )
    }

    // MARK: - Keychain Errors

    private static func isKeychainError(_ error: NSError) -> Bool {
        let keychainDomains = ["NSOSStatusErrorDomain", "com.apple.security"]
        let keychainCodes = [-25291, -25292, -25293, -25294, -25295, -25299, -25300, -25301, -25302, -25303, -25304, -25305, -25306, -25307, -25308]
        return keychainDomains.contains(error.domain) || keychainCodes.contains(error.code)
    }

    private static func mapKeychainError(_ error: NSError, context: SigningContext) -> SigningError {
        switch error.code {
        case -25291: // errSecAuthFailed
            return SigningError(
                title: .localized("Authentication Failed"),
                message: .localized("Keychain authentication failed. The item may require a password or biometric that wasn't provided."),
                recovery: .localized("Ensure Face ID/Touch ID is set up. If using a password-protected certificate, enter the correct password."),
                isRecoverable: true
            )
        case -25292: // errSecItemNotFound
            return SigningError(
                title: .localized("Certificate/Key Not Found"),
                message: .localized("The requested certificate, key, or profile was not found in the Keychain."),
                recovery: .localized("Re-import the .p12 certificate and .mobileprovision profile. Check Settings → Certificates."),
                isRecoverable: true
            )
        case -25293: // errSecDuplicateItem
            return SigningError(
                title: .localized("Duplicate Keychain Item"),
                message: .localized("A certificate or key with the same identifier already exists in the Keychain."),
                recovery: .localized("Delete the existing certificate from Settings → Certificates, then re-import."),
                isRecoverable: true
            )
        case -25294: // errSecInteractionNotAllowed
            return SigningError(
                title: .localized("Keychain Access Denied"),
                message: .localized("The app is not allowed to access the Keychain item (requires user interaction)."),
                recovery: .localized("Unlock the device and ensure VexSign has Keychain access. Restart the app if needed."),
                isRecoverable: true
            )
        case -25295: // errSecDecode
            return SigningError(
                title: .localized("Keychain Data Corrupt"),
                message: .localized("The Keychain item could not be decoded. It may be corrupted or from an incompatible version."),
                recovery: .localized("Delete and re-import the certificate/profile. If persistent, reset Keychain data for VexSign."),
                isRecoverable: true
            )
        case -25300: // errSecParam
            return SigningError(
                title: .localized("Invalid Keychain Parameters"),
                message: .localized("Invalid parameters passed to Keychain operation."),
                recovery: .localized("This is an internal error. Please report it with the error code."),
                isRecoverable: false
            )
        default:
            return SigningError(
                title: .localized("Keychain Error"),
                message: .localized("A Keychain error occurred: %@ (Code: %d)", arguments: error.localizedDescription, error.code),
                recovery: .localized("Try restarting the app. If persistent, restart the device and re-import certificates."),
                isRecoverable: true
            )
        }
    }

    // MARK: - Network Errors

    private static func isNetworkError(_ error: NSError) -> Bool {
        let networkDomains = ["NSURLErrorDomain", "NSPOSIXErrorDomain", "kCFErrorDomainCFNetwork"]
        return networkDomains.contains(error.domain) || error.domain == NSURLErrorDomain
    }

    private static func mapNetworkError(_ error: NSError, context: SigningContext) -> SigningError {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet:
                return SigningError(
                    title: .localized("No Internet Connection"),
                    message: .localized("The device is not connected to the internet. Apple ID authentication and provisioning require internet access."),
                    recovery: .localized("Connect to Wi-Fi or cellular data and retry."),
                    isRecoverable: true
                )
            case NSURLErrorTimedOut:
                return SigningError(
                    title: .localized("Request Timed Out"),
                    message: .localized("The request to Apple's servers or the anisette provider timed out."),
                    recovery: .localized("Check your internet connection. Try again. If persistent, the Apple servers may be slow."),
                    isRecoverable: true
                )
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return SigningError(
                    title: .localized("Cannot Reach Server"),
                    message: .localized("Could not connect to the server (Apple or anisette provider)."),
                    recovery: .localized("Check the anisette provider URL in Settings. Ensure the server is running and reachable."),
                    isRecoverable: true
                )
            case NSURLErrorBadServerResponse:
                return SigningError(
                    title: .localized("Invalid Server Response"),
                    message: .localized("The server returned an unexpected response."),
                    recovery: .localized("This may indicate an Apple server issue or an invalid anisette provider. Try again later."),
                    isRecoverable: true
                )
            case NSURLErrorUserAuthenticationRequired:
                return SigningError(
                    title: .localized("Authentication Required"),
                    message: .localized("The server requires authentication that wasn't provided."),
                    recovery: .localized("Check the anisette provider configuration. It should not require authentication."),
                    isRecoverable: true
                )
            default:
                return SigningError(
                    title: .localized("Network Error"),
                    message: .localized("A network error occurred: %@", arguments: error.localizedDescription),
                    recovery: .localized("Check your internet connection and try again."),
                    isRecoverable: true
                )
            }
        }

        return SigningError(
            title: .localized("Network Error"),
            message: error.localizedDescription,
            recovery: .localized("Check your internet connection and try again."),
            isRecoverable: true
        )
    }

    // MARK: - Zsign/Crypto Errors

    private static func isZsignError(_ error: NSError) -> Bool {
        return error.domain.contains("zsign") || error.domain.contains("Zsign")
    }

    private static func isCryptoError(_ error: NSError) -> Bool {
        return error.domain.contains("Crypto") || error.domain.contains("crypto")
    }

    // MARK: - Storage Errors

    private static func isStorageError(_ error: NSError) -> Bool {
        return error.domain == NSCocoaErrorDomain &&
               (error.code == NSFileReadNoSuchFileError ||
                error.code == NSFileWriteNoPermissionError ||
                error.code == NSFileWriteOutOfSpaceError ||
                error.code == NSManagedObjectValidationError)
    }

    private static func mapStorageError(_ error: NSError, context: SigningContext) -> SigningError {
        switch error.code {
        case NSFileReadNoSuchFileError:
            return SigningError(
                title: .localized("File Not Found"),
                message: .localized("A required file (IPA, certificate, profile) could not be found."),
                recovery: .localized("Re-import the missing file. Check Settings → Certificates or re-download the IPA."),
                isRecoverable: true
            )
        case NSFileWriteNoPermissionError:
            return SigningError(
                title: .localized("Permission Denied"),
                message: .localized("The app doesn't have permission to write to the required location."),
                recovery: .localized("Restart the app. If persistent, check iOS Settings → VexSign for file access permissions."),
                isRecoverable: true
            )
        case NSFileWriteOutOfSpaceError:
            return SigningError(
                title: .localized("Out of Storage Space"),
                message: .localized("The device storage is full. Cannot save IPA, certificate, or profile."),
                recovery: .localized("Free up space in Settings → General → iPhone Storage, then retry."),
                isRecoverable: true
            )
        default:
            return SigningError(
                title: .localized("Storage Error"),
                message: error.localizedDescription,
                recovery: .localized("Restart the app and try again."),
                isRecoverable: true
            )
        }
    }
}

// MARK: - SigningError

struct SigningError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recovery: String
    let isRecoverable: Bool

    static func == (lhs: SigningError, rhs: SigningError) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - SigningContext

enum SigningContext {
    case general
    case authentication
    case provisioning
    case signing
    case installation
    case certificateStatus
    case backgroundAutomation

    var defaultMessage: String {
        switch self {
        case .general: return .localized("An unexpected error occurred during the signing operation.")
        case .authentication: return .localized("Failed to authenticate with Apple ID.")
        case .provisioning: return .localized("Failed to provision the app with Apple.")
        case .signing: return .localized("Failed to sign the IPA.")
        case .installation: return .localized("Failed to install the app on the device.")
        case .certificateStatus: return .localized("Failed to check certificate revocation status.")
        case .backgroundAutomation: return .localized("Background automation encountered an error.")
        }
    }

    var defaultRecovery: String {
        switch self {
        case .general: return .localized("Check the Activity Log for details. Try restarting the app and retrying.")
        case .authentication: return .localized("Verify credentials, check 2FA, ensure internet connection.")
        case .provisioning: return .localized("Check device registration, App ID limits, and quota. Retry provisioning.")
        case .signing: return .localized("Check certificate/profile validity, entitlements, and architecture settings.")
        case .installation: return .localized("Check installation method, device pairing, and network connectivity.")
        case .certificateStatus: return .localized("Ensure internet for OCSP/CRL. Grant consent if prompted.")
        case .backgroundAutomation: return .localized("Check automation history. Run manually from Settings → Automation.")
        }
    }
}