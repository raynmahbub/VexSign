import Foundation

/// Authorization is typed and recursive. A profile is a capability ceiling, not
/// an entitlement template. Unknown capabilities must match literally.
enum ProfileEntitlementAuthorization {
    private static let wildcardKeys: Set<String> = [
        "keychain-access-groups", "com.apple.developer.associated-domains",
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier"
    ]

    static func allows(_ requested: Any, granted: Any, key: String) -> Bool {
        allows(requested, granted: granted, key: key, depth: 0)
    }

    private static func allows(_ requested: Any, granted: Any, key: String, depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        if let wanted = requested as? [Any] {
            guard let available = granted as? [Any], wanted.count <= 1024, available.count <= 1024 else { return false }
            return wanted.allSatisfy { item in available.contains { allows(item, granted: $0, key: key, depth: depth + 1) } }
        }
        if let wanted = requested as? [String: Any] {
            guard let available = granted as? [String: Any], wanted.count <= 1024 else { return false }
            return wanted.allSatisfy { name, value in
                available[name].map { allows(value, granted: $0, key: name, depth: depth + 1) } ?? false
            }
        }
        if let wanted = requested as? String, let available = granted as? String {
            if key == "keychain-access-groups", wanted.contains("*") { return false }
            if wanted == available { return true }
            guard wildcardKeys.contains(key), available.filter({ $0 == "*" }).count == 1,
                  available.hasSuffix("*"), !wanted.contains("*") else { return false }
            let stem = String(available.dropLast())
            return wanted.hasPrefix(stem) && wanted.count > stem.count
        }
        if let wanted = requested as? NSNumber, let available = granted as? NSNumber {
            let wantedBool = type(of: wanted) == type(of: NSNumber(value: true))
            let availableBool = type(of: available) == type(of: NSNumber(value: true))
            guard wantedBool == availableBool else { return false }
            // Not asking for a privilege is allowed when that privilege is granted.
            return wantedBool ? (!wanted.boolValue || available.boolValue) : wanted == available
        }
        if let wanted = requested as? Data, let available = granted as? Data { return wanted == available }
        if let wanted = requested as? Date, let available = granted as? Date { return wanted == available }
        return false
    }

    /// Identity entitlements must describe the new signer, while bundle IDs and
    /// requested capabilities remain intact. Shared group names are not invented.
    static func planned(_ requested: [String: Any], profile: Certificate, bundleIdentifier: String,
                        isolateKeychainGroups: Bool = false) -> [String: Any]? {
        guard isBoundedPropertyList(requested),
              let appID = profile.Entitlements?["application-identifier"]?.value as? String,
              case .success(let authorized) = ProfileApplicationIdentifierMatcher.parse(appID),
              let team = profile.TeamIdentifier.first else { return nil }
        var result = requested
        let originalAppID = requested["application-identifier"] as? String
        let originalPrefix = originalAppID?.split(separator: ".", maxSplits: 1).first.map(String.init)
        let signedAppID = authorized.prefix + "." + bundleIdentifier
        result["application-identifier"] = signedAppID
        if requested["com.apple.application-identifier"] != nil { result["com.apple.application-identifier"] = signedAppID }
        result["com.apple.developer.team-identifier"] = team
        if let groups = requested["keychain-access-groups"] as? [String] {
            var mapped = groups.map { group -> String in
                guard let originalPrefix, group.hasPrefix(originalPrefix + ".") else { return group }
                return authorized.prefix + String(group.dropFirst(originalPrefix.count))
            }
            if isolateKeychainGroups {
                // Explicitly opted-in transformation. Keep every requested group;
                // an unknown/Apple-managed group is rejected, never dropped.
                mapped = mapped.map { group in
                    guard group.hasPrefix(authorized.prefix + ".") else { return group }
                    let suffix = String(group.dropFirst(authorized.prefix.count + 1))
                    return signedAppID + "." + suffix
                }
                mapped.insert(signedAppID, at: 0)
            }
            var seen = Set<String>()
            result["keychain-access-groups"] = mapped.filter { seen.insert($0).inserted }
        } else if isolateKeychainGroups {
            result["keychain-access-groups"] = [signedAppID]
        }
        return result
    }

    /// Decoder bounds do not imply recursion bounds. Reject unsupported shapes
    /// before recursive comparison, serialization, or native DER generation.
    static func isBoundedPropertyList(_ value: Any) -> Bool {
        var remaining = 4096
        func visit(_ item: Any, depth: Int) -> Bool {
            remaining -= 1
            guard depth <= 32, remaining >= 0 else { return false }
            if let array = item as? [Any] { return array.count <= 1024 && array.allSatisfy { visit($0, depth: depth + 1) } }
            if let dictionary = item as? [String: Any] {
                return dictionary.count <= 1024 && dictionary.allSatisfy { key, value in
                    !key.isEmpty && key.utf8.count <= 256 && visit(value, depth: depth + 1)
                }
            }
            if let string = item as? String { return string.utf8.count <= 8192 }
            if let data = item as? Data { return data.count <= 65536 }
            return item is NSNumber || item is Date
        }
        return visit(value, depth: 0)
    }

    static func isSupportedByNativeEncoder(_ value: Any) -> Bool {
        guard isBoundedPropertyList(value) else { return false }
        func supported(_ item: Any) -> Bool {
            if let dictionary = item as? [String: Any] { return dictionary.values.allSatisfy(supported) }
            if let array = item as? [Any] { return array.allSatisfy(supported) }
            if item is String { return true }
            if let number = item as? NSNumber {
                return !["f", "d"].contains(String(cString: number.objCType)) && Int64(number.stringValue) != nil
            }
            return false
        }
        return supported(value)
    }

    static func failures(requested: [String: Any], grants: [String: Any]) -> [String] {
        requested.keys.sorted().filter { key in
            guard let value = requested[key], let grant = grants[key] else { return true }
            if ["application-identifier", "com.apple.application-identifier"].contains(key), let wanted = value as? String, let available = grant as? String {
                return !ProfileApplicationIdentifierMatcher.match(applicationIdentifier: available, entitlementValue: wanted).isAuthorized
            }
            return !allows(value, granted: grant, key: key)
        }
    }
}
