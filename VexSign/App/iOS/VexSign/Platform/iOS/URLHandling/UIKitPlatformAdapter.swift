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

    func presentErrorWithCopy(title: String, message: String) {
        UIAlertController.showErrorWithCopy(title: title, message: message)
    }

    func triggerHapticFeedback(success: Bool) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(success ? .success : .error)
    }
}
