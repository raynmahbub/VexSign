import UIKit
import NimbleExtensions

@MainActor
final class UIKitTemporaryFileSharing: TemporaryFileSharing {
    func shareFile(_ url: URL, completion: @escaping @MainActor () -> Void) throws {
        guard let presenter = UIApplication.topViewController(), presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented, presenter.presentedViewController == nil else {
            throw CocoaError(.userCancelled)
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion() }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        // UIKit can refuse presentation synchronously; no completion callback is
        // promised in that case, so the caller must be allowed to clean its lease.
        guard controller.presentingViewController != nil else { throw CocoaError(.userCancelled) }
    }
}
