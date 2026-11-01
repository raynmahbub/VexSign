import UIKit
import NimbleExtensions

/// Manual-import review only. Automated/background imports keep their existing
/// behavior. Matching metadata is not proof of identical archive contents.
@MainActor
enum ImportDuplicateReview {
    private struct Review {
        let app: AppInfoPresentable
        let completion: (AppInfoPresentable, Bool) -> Void
    }
    private static var pending: [Review] = []
    private static var processing = false

    nonisolated static func matches(identifier: String?, version: String?, otherIdentifier: String?, otherVersion: String?) -> Bool {
        guard let identifier, !identifier.isEmpty, let version, !version.isEmpty else { return false }
        return identifier == otherIdentifier && version == otherVersion
    }

    /// Bool is true only when the newly imported copy was retained.
    static func resolve(_ app: AppInfoPresentable, completion: @escaping (AppInfoPresentable, Bool) -> Void) {
        pending.append(Review(app: app, completion: completion))
        guard !processing else { return }
        processing = true
        presentNext()
    }

    private static func presentNext() {
        guard let review = pending.first else {
            processing = false
            return
        }
        let app = review.app
        let locks = AppLockManager.shared
        let existing = Storage.shared.getAllApps().first { candidate in
            guard !candidate.isSigned, candidate.uuid != app.uuid, let uuid = candidate.uuid else { return false }
            return !locks.isAppHidden(uuid) && (!locks.isAppLocked(uuid) || locks.isSessionUnlocked(uuid))
                && matches(identifier: app.identifier, version: app.version,
                           otherIdentifier: candidate.identifier, otherVersion: candidate.version)
        }
        guard let existing, UIApplication.shared.applicationState == .active,
              let presenter = UIApplication.topViewController(), !(presenter is UIAlertController) else {
            finish(app, retainedNewCopy: true)
            return
        }
        let alert = UIAlertController(
            title: .localized("Matching copy in Library"),
            message: .localized("An imported copy has the same bundle identifier and version. Its contents may differ. Keep both, or discard only this new import and use the existing copy. Nothing is replaced."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: .localized("Keep Both"), style: .cancel) { [weak alert] _ in
            afterDismissal(of: alert) { finish(app, retainedNewCopy: true) }
        })
        alert.addAction(UIAlertAction(title: .localized("Use Existing"), style: .default) { [weak alert] _ in
            afterDismissal(of: alert) {
                guard let uuid = existing.uuid, let current = Storage.shared.app(withUuid: uuid),
                      !locks.isAppHidden(uuid), (!locks.isAppLocked(uuid) || locks.isSessionUnlocked(uuid)) else {
                    finish(app, retainedNewCopy: true)
                    return
                }
                Storage.shared.deleteApp(for: app)
                finish(current, retainedNewCopy: false)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func finish(_ app: AppInfoPresentable, retainedNewCopy: Bool) {
        guard !pending.isEmpty else { return }
        let review = pending.removeFirst()
        review.completion(app, retainedNewCopy)
        // Keep processing true during the callback: reentrant resolve() only enqueues.
        DispatchQueue.main.async { presentNext() }
    }

    private static func afterDismissal(of alert: UIAlertController?, work: @escaping () -> Void) {
        // Alert action callbacks precede automatic dismissal. Inspect the transition
        // on the next run-loop turn, not after an assumed animation duration.
        DispatchQueue.main.async { [weak alert] in
            guard let alert, alert.presentingViewController != nil else { return work() }
            if let coordinator = alert.transitionCoordinator,
               coordinator.viewController(forKey: .from) === alert,
               coordinator.animate(alongsideTransition: nil, completion: { _ in work() }) {
                return
            }
            // Reduce Motion / nonanimated path: UIKit owns the completion callback.
            alert.dismiss(animated: false, completion: work)
        }
    }
}
