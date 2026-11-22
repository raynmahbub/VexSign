//
//  Server+Compute.swift
//  vexsign
//
//  Created by VexSign Contributors on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR VEXSIGN
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	private static let _fallbackEndpoint = URL(fileURLWithPath: "/")

	private func _endpoint(path: String, queryItems: [URLQueryItem]? = nil) -> URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = path
		comps.port = port
		comps.queryItems = queryItems
		return comps.url ?? Self._fallbackEndpoint
	}

	var plistEndpoint: URL {
		_endpoint(path: "/\(id)-\(installToken).plist")
	}

	var payloadEndpoint: URL {
		_endpoint(path: "/\(id)-\(installToken).ipa")
	}
	
	var pageEndpoint: URL {
		_endpoint(
			path: "/install",
			queryItems: [URLQueryItem(name: "token", value: installToken)]
		)
	}
	
	var iTunesLink: String {
		Self.installLink(manifest: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String? {
		guard let manifestUrl else {
			return nil
		}
		
		return Self.installLink(manifest: manifestUrl.absoluteString)
	}
	
	static func installLink(manifest url: String) -> String {
		var components = URLComponents()
		components.scheme = "itms-services"
		components.host = ""
		components.queryItems = [
			URLQueryItem(name: "action", value: "download-manifest"),
			URLQueryItem(name: "url", value: url)
		]
		return components.url?.absoluteString ?? ""
	}

	var displayImageSmallEndpoint: URL {
		_endpoint(path: "/\(installToken)-app57x57.png")
	}

	var displayImageLargeEndpoint: URL {
		_endpoint(path: "/\(installToken)-app512x512.png")
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData() ?? Data()
	}

	var html: String {
		let target = getServerMethod() == 1 ? (iTunesLinkExternal ?? "") : iTunesLink
		let encodedLiteral: String
		if let jsonData = try? JSONEncoder().encode(target), // try? ok: String JSON encoding is infallible; fallback escapes quotes/angle brackets
		   let literal = String(data: jsonData, encoding: .utf8) {
			encodedLiteral = literal.replacingOccurrences(of: "</", with: "<\\/")
		} else {
			encodedLiteral = "\"\""
		}
		return """
		<!doctype html>
		<html style="background-color: black;">
		<script type="text/javascript">window.location=\(encodedLiteral)</script>
		</html>
		"""
	}

	func buildInstallManifest() throws -> [String: Any] {
		let bundleIdentifier = (app.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bundleIdentifier.isEmpty else {
			throw LocalInstallError.invalidManifestMetadata
		}
		let trimmedVersion = (app.version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let bundleVersion = trimmedVersion.isEmpty ? "1.0" : trimmedVersion
		let trimmedTitle = (app.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let title = trimmedTitle.isEmpty ? bundleIdentifier : trimmedTitle

		return [
			"items": [[
				"assets": [
					[
						"kind": "software-package",
						"url": payloadEndpoint.absoluteString
					],
					[
						"kind": "display-image",
						"url": displayImageSmallEndpoint.absoluteString
					],
					[
						"kind": "full-size-image",
						"url": displayImageLargeEndpoint.absoluteString
					],
				],
				"metadata": [
					"bundle-identifier": bundleIdentifier,
					"bundle-version": bundleVersion,
					"kind": "software",
					"title": title,
				],
			]]
		]
	}

	func buildInstallManifestData() throws -> Data {
		let manifest = try buildInstallManifest()
		return try PropertyListSerialization.data(
			fromPropertyList: manifest,
			format: .xml,
			options: .zero
		)
	}

	var installManifest: [String: Any] {
		(try? buildInstallManifest()) ?? [:] // try? ok: computed compatibility property; route handler uses throwing buildInstallManifestData()
	}

	var installManifestData: Data {
		(try? buildInstallManifestData()) ?? .init() // try? ok: computed compatibility property; route handler uses throwing buildInstallManifestData()
	}
}
