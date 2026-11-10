/// What the user chose to do with a signed copy once the signing sheet has produced it.
///
/// The signed copy stays in the library for every choice. Whether it was kept used to be decided
/// here, and `done` without an automatic install answered no, which let Auto Cleanup delete the
/// copy the run had just produced. `PostSignArtifacts` decides what a finished run removes now,
/// and the signed copy is not something it can remove.
enum SigningCompletionAction {
    case done, install, share, library

    func shouldInstall(automaticInstall: Bool) -> Bool {
        automaticInstall || self == .install
    }
}
