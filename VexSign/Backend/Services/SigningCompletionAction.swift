/// A user-selected result action must keep the signed bundle alive until its
/// consumer has finished. Done alone retains the configured cleanup behavior.
enum SigningCompletionAction {
    case done, install, share, library

    func shouldInstall(automaticInstall: Bool) -> Bool {
        automaticInstall || self == .install
    }

    func keepsSignedApp(automaticInstall: Bool) -> Bool {
        automaticInstall || self != .done
    }
}
