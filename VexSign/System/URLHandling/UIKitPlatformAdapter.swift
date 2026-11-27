import UIKit
import NimbleExtensions

/// Concrete iOS/UIKit implementation of `PlatformSystemAdapting`.
/// Isolates `UIApplication`, `UIAlertController`, `UIActivityViewController`,
/// `UIPasteboard`, haptics, and `Toast` presentation from Domain and Application code.
@MainActor
final class UIKitPlatformAdapter: PlatformSystemAdapting {
    func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    func pasteboardString() -> String? {
        UIPasteboard.general.string
    }

    func dismissKeyboard() {
        UIApplication.shared.endEditing()
    }

    func restartOrSuspendApp() {
        UIApplication.shared.suspendAndReopen()
    }

    func shareItems(_ items: [Any]) {
        UIActivityViewController.show(activityItems: items)
    }

    func notifySuccess(_ message: String, systemImage: String) {
        Toast.success(message, systemImage: systemImage)
    }

    func notifyInfo(_ message: String, systemImage: String) {
        Toast.info(message, systemImage: systemImage)
    }

    func notifyError(_ message: String, sticky: Bool) {
        Toast.error(message, duration: sticky ? .sticky : .long)
    }

    func presentDestructiveConfirmation(title: String, message: String, onConfirm: @escaping () -> Void) {
        DestructiveConfirm.present(title: title, message: message, confirm: onConfirm)
    }

    func presentYesNoAlert(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
        UIAlertController.showAlertWithCancel(
            title: title,
            message: message,
            actions: [
                UIAlertAction(title: confirmTitle, style: .destructive) { _ in
                    onConfirm()
                }
            ]
        )
    }

    func presentImportConsentAlert(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard let presenter = UIApplication.topViewController() else {
            // No presenter means no consent. Fail closed: report the decline so
            // staged private-key bytes are removed instead of left on disk.
            onCancel()
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in onConfirm() })
        alert.addAction(UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in onCancel() })
        presenter.present(alert, animated: true)
    }

    func presentErrorWithCopy(title: String, message: String) {
        UIAlertController.showErrorWithCopy(title: title, message: message)
    }

    /// Routed through `Haptics`: the platform adapter used to be a second implementation of
    /// the same feedback, with its own `prepare()` and its own main-thread assumption.
    func triggerHapticFeedback(success: Bool) {
        if success { Haptics.success() } else { Haptics.error() }
    }
}
