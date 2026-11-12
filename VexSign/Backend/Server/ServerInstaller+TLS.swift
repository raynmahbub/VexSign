//
//  Server+TLS.swift
//  vexsign
//
//  Created by VexSign TeamSign Team on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR VEXSIGN
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	static let env: Environment = {
		do {
			var env = try Environment.detect()
			try LoggingSystem.bootstrap(from: &env)
			return env
		} catch {
			FileLogger.error("Failed to detect Environment or bootstrap LoggingSystem: \(error)", category: "install")
			var env = Environment.development
			return env
		}
	}()
	
	func setupApp(port: Int) async throws -> Application {
		let transport: ServerApplicationFactory.Transport
		if getServerMethod() != 1 {
			guard Self.readCommonName() != nil else { throw LocalInstallError.invalidHostname }
			guard let configuration = try tls() else { throw LocalInstallError.missingTLS }
			transport = .https(configuration)
		} else {
			transport = .http
		}
		// Validate identity before allocating Application/thread-pool resources.
		return try await ServerApplicationFactory.make(environment: Self.env, threads: 1,
			hostname: sni(), bindHost: getServerMethod() == 1 ? "0.0.0.0" : "127.0.0.1",
			port: port, transport: transport, bodyLimit: "128mb", caseInsensitive: false)
	}
	
	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		if getServerMethod() == 1 {
			return !self.getIPFix()
			? (Self.getLocalAddress() ?? localhost)
			: localhost
		} else {
			return Self.readCommonName() ?? localhost
		}
	}
	
	func tls() throws -> TLSConfiguration? {
		try DeviceTLSIdentity.ensure()
		guard
			let crt = Self.getUrl("server", ext: "crt"),
			let pem = Self.getUrl("server", ext: "pem")
		else {
			FileLogger.error("Device-local server certificate or key is missing", category: "install")
			return nil
		}
		return try Self._loadTLSConfiguration(certificateURL: crt, privateKeyURL: pem)
	}

	/// Creates the Web Manager's TLS identity with the actual listener hostname/IP
	/// in the leaf SAN before loading it. A missing/corrupt identity is a startup
	/// error; the LAN listener never falls back to plaintext HTTP.
	static func webManagerTLSConfiguration(serverNames: [String]) throws -> TLSConfiguration {
		try DeviceTLSIdentity.ensure(serverNames: serverNames)
		let certificateURL = DeviceTLSIdentity.directory.appendingPathComponent("server.crt")
		let privateKeyURL = DeviceTLSIdentity.directory.appendingPathComponent("server.pem")
		guard FileManager.default.fileExists(atPath: certificateURL.path),
			  FileManager.default.fileExists(atPath: privateKeyURL.path) else {
			throw DeviceTLSIdentity.Failure.invalidIdentity
		}
		return try _loadTLSConfiguration(certificateURL: certificateURL, privateKeyURL: privateKeyURL)
	}

	private static func _loadTLSConfiguration(certificateURL: URL, privateKeyURL: URL) throws -> TLSConfiguration {
		let source = { (url: URL) in
			LocalTLSIdentity.diagnosticSource(for: url, deviceDirectory: DeviceTLSIdentity.directory)
		}
		FileLogger.log("cert=\(source(certificateURL)) key=\(source(privateKeyURL))", category: "install")

		do {
			let chain = try NIOSSLCertificate.fromPEMFile(certificateURL.path)
			let key = try NIOSSLPrivateKey(file: privateKeyURL.path, format: .pem)
			FileLogger.log("loaded certificate chain of \(chain.count) (a leaf plus intermediates is expected)", category: "install")
			return TLSConfiguration.makeServerConfiguration(
				certificateChain: chain.map { NIOSSLCertificateSource.certificate($0) },
				privateKey: .privateKey(key)
			)
		} catch {
			FileLogger.error("certificate or key rejected: \(error)", category: "install")
			throw error
		}
	}
	
	static func readCommonName() -> String? {
		guard
			let url = Self.getUrl("commonName", ext: "txt"),
			let name = try? String(contentsOf: url, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!name.isEmpty
		else {
			return nil
		}
		
		return Self.normalizedHostname(name)
	}

	static func normalizedHostname(_ name: String) -> String? {
		// A wildcard CN needs a concrete label that matches the certificate.
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		let host = name.hasPrefix("*.") ? "local" + name.dropFirst() : name
		guard host != "null", !host.contains(where: { $0.isWhitespace }),
			  let url = URL(string: "https://" + host), url.host == host,
			  url.port == nil, url.user == nil, url.path.isEmpty,
			  url.query == nil, url.fragment == nil, !host.isEmpty else { return nil }
		return host
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
        guard ["server.crt", "server.pem", "commonName.txt"].contains("\(name).\(ext)") else { return nil }
        do { try DeviceTLSIdentity.ensure() }
        catch {
            FileLogger.error("Device TLS identity unavailable: \(error.localizedDescription)", category: "install")
            return nil
        }
        let url = DeviceTLSIdentity.directory.appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

	static func resolve(_ host: String) -> [String] {
		var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
							 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
		var result: UnsafeMutablePointer<addrinfo>?
		guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return [] }
		defer { freeaddrinfo(head) }

		var addresses: [String] = []
		var node: UnsafeMutablePointer<addrinfo>? = head
		while let current = node {
			var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
						   &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
				addresses.append(String(cString: buffer))
			}
			node = current.pointee.ai_next
		}
		return addresses
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while let current = ptr {
				let interface = current.pointee
				guard let addr = interface.ifa_addr else {
					ptr = interface.ifa_next
					continue
				}
				let addrFamily = addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
									   &hostname, socklen_t(hostname.count),
									   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
					}
				}
				ptr = interface.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
