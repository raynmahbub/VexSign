//
//  FR.swift
//  VexSign
//
//  Created by VexSign TeamSign Team on 22.04.2025.
//
//  Facade for file/import, signing, certificate, and repository operations.
//  Split into focused extensions:
//  - FR+Import.swift: handlePackageFile
//  - FR+Signing.swift: signPackageFile
//  - FR+Certificates.swift: handleCertificateFiles, checkPasswordForCertificate, validatePairingFile, movePairing
//  - FR+Repository.swift: registerRepositoryKeyProvider, handleSource, _handleGitHubSource, _addGitHubRepository
//  - FR+Export.swift: exportCertificateAndOpenUrl, fetchRepositories
//

import Foundation.NSURL
import Security
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import OSLog
import NimbleExtensions

enum FR {
    // All implementations are in focused extensions
}