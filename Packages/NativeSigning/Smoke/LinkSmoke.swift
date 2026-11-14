import SideSign
import ZsignSwift

/// Public exported references force both implementations into the dynamic link.
/// Building this library never calls authenticate, signs files, or contacts Apple.
@MainActor
public enum NativeSigningLinkSmoke {
    public static func codecEntryPoints() -> (Any, Any) {
        (SideSignSessionCodec.encode as Any, SideSignSessionCodec.decodeForRevalidation as Any)
    }

    public static func accountAdapterFactory() throws -> SideSignAccountAdapter<SideSignNativePortal> {
        try SideSignAccountAdapter()
    }

    public static func anisetteProviderFactory(descriptor: AnisetteProviderDescriptor) throws -> HTTPSAnisetteProvider<SystemAnisetteHeaderTransport> {
        try HTTPSAnisetteProvider(descriptor: descriptor)
    }

    public static func accountBackendFactory(descriptor: AnisetteProviderDescriptor) throws -> NativeAccountBackend {
        try NativeAccountBackend(provider: descriptor)
    }

    public static func linkedEntryPoints() -> (Any, Any) {
        (DeveloperPortal.shared, Zsign.sign as Any)
    }
}
