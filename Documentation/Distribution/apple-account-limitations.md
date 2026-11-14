# Apple account and provisioning limitations

## Free Personal Team

Apple's membership comparison currently documents these Personal Team limits: up to 10 registered App IDs (expire after 7 days), 3 devices (expire after 7 days), up to 3 installed apps per device, and provisioning profiles that expire 7 days after issuance. The profile must be renewed/rebuilt/reinstalled using supported Apple tooling. See [Apple Developer Program membership comparison](https://developer.apple.com/support/compare-memberships/); re-check the official terms before relying on quota details.

An ordinary iOS app does not have a public Apple API that provides complete Personal Team provisioning/signing from the device. This repository's native account/authentication code is experimental: `Packages/NativeSigning/README.md`, `Documentation/Architecture/NATIVE_SIGNING_ARCHITECTURE.md`, `Documentation/Security/NATIVE_SIGNING_HANDOFF.md`, and `App/iOS/VexSign/Backend/Services/SigningMethodCapabilities.swift` explicitly leave the end-to-end signer unintegrated. Authentication or account inventory alone does not prove certificate issuance, valid profile CMS, local signing, or installation. VexSign does not collect Apple ID passwords for the new distribution subsystem and must not scrape the developer portal or automate private endpoints.

The supported alternative for a user who needs Personal Team signing today is Apple-supported Xcode provisioning on a Mac. For direct iPhone use, obtain an app through TestFlight or a legitimate distribution path instead. VexSign cannot honestly promise fully computer-free Personal Team provisioning until Apple provides a documented, permitted mechanism and the implementation passes device acceptance.

## Paid Developer Program

A paid team can create eligible Development, Ad Hoc, and App Store distribution identities/profiles within Apple's rules. Ad Hoc requires registered device UDIDs. Profile App ID, certificate inventory, expiration, entitlements and device scope must match. App Store distribution is for App Store Connect/TestFlight/App Store; it is not a general direct-OTA profile. Enterprise distribution is a separate Apple Developer Enterprise Program membership with organization-use constraints.

Imported signing identity support exists. VexSign must inspect the certificate class and provisioning profile rather than treating a `.p12` as proof of every distribution entitlement. Certificate revocation and profile expiry are distinct states.

## Enterprise, MDM and regional programs

Enterprise and MDM are organization-managed distribution routes, not user-facing public bypasses. MDM requires managed/enrolled devices and organization infrastructure. Alternative distribution capabilities are conditional on Apple's currently applicable region, program, OS and legal requirements; this project does not implement or claim those routes.

Never bypass device registration, signing, review, notarization or regional eligibility. When the method is not available, state the limitation and offer a supported alternative such as TestFlight.
