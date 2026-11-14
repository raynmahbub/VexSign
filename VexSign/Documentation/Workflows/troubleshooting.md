# Distribution troubleshooting

- **Downloaded IPA won't install:** an IPA download is not an installation. Confirm the artifact is signed and exported for the relevant route, bundle/profile/certificate match, profile is current, and device is included if Ad Hoc. The current GitHub release IPA is unsigned; it is not directly installable.
- **Safari Install link is missing/fails:** confirm a valid HTTPS manifest/payload and a route-eligible signature. Test on an eligible real device. Do not switch to an ordinary developer certificate or disable verification.
- **TestFlight build unavailable:** distinguish upload accepted from processing, processing complete, beta review, tester group assignment and invitation. Inspect App Store Connect; do not infer success from a CI job.
- **Personal Team signing blocked:** Personal Team profiles expire quickly and have app/device/ID limits. Restricted capabilities such as Network Extension may not be available. The native signing path is not integrated; use Apple's supported Xcode flow or another eligible route. Do not enter an Apple ID password in VexSign.
- **Manifest rejected:** check signature key ID/trust root, schema, signature bytes, expiry, future timestamp, bundle ID, HTTPS URLs, hash length and minimum OS. A SHA256SUMS match alone does not prove authenticity.
- **Hash mismatch or interrupted download:** discard the temporary artifact and retry through the bounded download/recovery flow; never import the incomplete file.
- **Signing appears successful but install is pending:** review the installation task state. Signing complete, download complete, prompt opened, and installed are distinct outcomes. Preserve `unconfirmed` when iOS cannot provide proof.
- **Entitlement/profile mismatch:** use a profile with the exact App ID/capabilities or remove only explicitly optional features through a reviewed signing plan. Never fabricate entitlements.
- **Insufficient storage:** retain source and last known-good output, remove only inactive task-owned temp files, then retry.
