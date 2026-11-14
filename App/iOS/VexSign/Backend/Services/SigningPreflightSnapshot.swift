/// The review must authorize the same options, identity and issues that reach
/// the signer. This is not a fingerprint of source files or certificate bytes.
struct SigningPreflightSnapshot {
    let options: Options
    let certificateUUID: String?
    let issues: [PreflightIssue]

    func matches(options: Options, certificateUUID: String?, issues: [PreflightIssue]) -> Bool {
        self.options == options && self.certificateUUID == certificateUUID && self.issues == issues
    }
}
