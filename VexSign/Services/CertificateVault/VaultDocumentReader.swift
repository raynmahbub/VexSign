//
//  VaultDocumentReader.swift
//  VexSign
//
//  Security-scoped reads happen here, before any bytes reach the vault. The
//  scope is closed on success, failure and cancellation; nothing is copied to
//  a temporary location, so a PKCS#12 is never left on disk by an import.
//

import Foundation

protocol VaultSecurityScopeControlling: AnyObject {
    @discardableResult
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

final class VaultURLSecurityScopeController: VaultSecurityScopeControlling {
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

struct VaultDocumentReader {
    let controller: VaultSecurityScopeControlling
    let maximumBytes: Int

    init(controller: VaultSecurityScopeControlling = VaultURLSecurityScopeController(),
         maximumBytes: Int = CertificateInputReader.maximumBytes) {
        self.controller = controller
        self.maximumBytes = maximumBytes
    }

    func read(_ url: URL) throws -> Data {
        guard controller.startAccessing(url) else { throw VaultError.restrictedFile }
        defer { controller.stopAccessing(url) }
        do {
            return try CertificateInputReader.read(url, maximumBytes: maximumBytes)
        } catch let error as CertificateInputReader.ReadError {
            switch error {
            case .tooLarge: throw VaultError.tooLarge
            default: throw VaultError.restrictedFile
            }
        } catch {
            throw VaultError.restrictedFile
        }
    }
}
