//
//  P12CrackerView.swift
//  VexSign
//
//  Interactive sheet for recovering passwords of imported .p12 certificates.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

struct P12CrackerView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var cracker = P12Cracker.shared

	let p12URL: URL
	var onFound: (String) -> Void

	@State private var selectedMode: P12Cracker.Mode = .fullDictionary
	@State private var customWordlistText = ""
	@State private var showCustomInput = false
	@State private var hasFinished = false

	var body: some View {
		NBNavigationView(.localized("P12 Password Recovery"), displayMode: .inline) {
			Form {
				Section {
					Picker(.localized("Search Mode"), selection: $selectedMode) {
						ForEach(P12Cracker.Mode.allCases) { mode in
							Text(mode.title).tag(mode)
						}
					}
					.disabled(cracker.isRunning)

					Toggle(.localized("Include Custom Wordlist"), isOn: $showCustomInput)
						.disabled(cracker.isRunning)

					if showCustomInput {
						TextField(.localized("Comma-separated words..."), text: $customWordlistText)
							.disabled(cracker.isRunning)
					}
				} header: {
					Text(.localized("Options"))
				} footer: {
					Text(.localized("Tests candidate passwords against the certificate private key until the valid password is discovered."))
				}

				if cracker.isRunning {
					Section {
						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text(.localized("Testing:"))
									.font(.footnote)
									.foregroundColor(.secondary)
								Text(verbatim: cracker.currentCandidate.isEmpty ? String.localized("(blank)") : cracker.currentCandidate)
									.font(.footnote.monospaced())
								Spacer()
								Text("\(cracker.testedCount) / \(cracker.totalCount)")
									.font(.caption.monospacedDigit())
									.foregroundColor(.secondary)
							}

							ProgressView(value: cracker.progress)
								.tint(.accentColor)
						}
						.padding(.vertical, 4)

						Button(role: .destructive) {
							cracker.cancel()
						} label: {
							HStack {
								Spacer()
								Text(.localized("Stop"))
								Spacer()
							}
						}
					} header: {
						Text(.localized("Progress"))
					}
				} else if let found = cracker.foundPassword {
					Section {
						VStack(spacing: 8) {
							Image(systemName: "checkmark.seal.fill")
								.font(.system(size: 36))
								.foregroundColor(.green)

							Text(.localized("Password Found!"))
								.font(.headline)

							Text(verbatim: found.isEmpty ? String.localized("(No password required)") : found)
								.font(.title3.monospaced().bold())
								.padding(.horizontal, 16)
								.padding(.vertical, 8)
								.background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

							Button(.localized("Apply Password")) {
								onFound(found)
								dismiss()
							}
							.buttonStyle(.borderedProminent)
							.padding(.top, 4)
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 8)
					}
				} else if hasFinished {
					Section {
						VStack(spacing: 8) {
							Image(systemName: "xmark.circle")
								.font(.system(size: 32))
								.foregroundColor(.orange)

							Text(.localized("Password Not Found"))
								.font(.subheadline.bold())

							Text(.localized("None of the candidate passwords matched. Try providing custom words or importing another certificate."))
								.font(.caption)
								.foregroundColor(.secondary)
								.multilineTextAlignment(.center)
						}
						.frame(maxWidth: .infinity)
						.padding(.vertical, 8)
					}
				}

				if !cracker.isRunning && cracker.foundPassword == nil {
					Section {
						Button {
							_startCracking()
						} label: {
							HStack {
								Spacer()
								Label(.localized("Start Recovery"), systemImage: "key.fill")
									.bold()
								Spacer()
							}
						}
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
			}
		}
	}

	private func _startCracking() {
		hasFinished = false
		let customWords = customWordlistText
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }

		Task {
			let result = await cracker.crack(
				p12URL: p12URL,
				mode: selectedMode,
				customCandidates: customWords
			)

			hasFinished = true
			if let result {
				onFound(result)
			}
		}
	}
}
