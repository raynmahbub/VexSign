//
//  DocumentPicker.swift
//  VexSign
//
//  Created by VexSign Team
//

import UIKit
import UniformTypeIdentifiers
import NimbleExtensions

/// UIKit presented. In a SwiftUI `.sheet` the picker dismisses itself and desyncs the binding,
/// which then swallows later presentations.
enum DocumentPicker {
	static func open(
		_ types: [UTType],
		multiple: Bool = false,
        asCopy: Bool = true,
		folder: ImportFolder? = nil,
		onPick: @escaping ([URL]) -> Void
	) {
        // Pairing credentials opt out of an OS-created Documents/Inbox copy.
        // Their owner holds a security scope while reading into protected storage.
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
		picker.allowsMultipleSelection = multiple
		_present(picker, folder: folder) { urls in
			guard !urls.isEmpty else { return }
			onPick(urls)
		}
	}

	static func export(_ urls: [URL], onFinish: (() -> Void)? = nil) {
		guard !urls.isEmpty else { onFinish?(); return }
		let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
		picker.directoryURL = UserDefaults.standard.bool(forKey: "VexSign.useLastExportLocation")
			? nil
			: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		_present(picker, folder: nil) { _ in onFinish?() }
	}

	private static var _delegates: [ObjectIdentifier: Delegate] = [:]

	private static func _present(
		_ picker: UIDocumentPickerViewController,
		folder: ImportFolder?,
		onFinish: @escaping ([URL]) -> Void
	) {
        guard let presenter = UIApplication.topViewController(), presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil, !presenter.isBeingPresented, !presenter.isBeingDismissed,
              presenter.transitionCoordinator == nil,
              !(presenter is UIAlertController), !(presenter is UIDocumentPickerViewController) else {
            onFinish([]) // Credential exports must also clean up when presentation is impossible/busy.
            return
        }

		let key = ObjectIdentifier(picker)
		let delegate = Delegate(folder: folder) { urls in
			Presentation.afterDismiss {
				_delegates[key] = nil
				onFinish(urls)
			}
		}
		if let directory = delegate.startDirectory { picker.directoryURL = directory }
		picker.delegate = delegate
		_delegates[key] = delegate

        picker.presentationController?.delegate = delegate
        presenter.present(picker, animated: true) {
            picker.presentationController?.delegate = delegate
        }
        // UIKit may refuse a presentation without calling its completion or
        // document-picker delegate. Do not retain a protected credential export
        // (or a security-scoped directory) indefinitely in that case.
        DispatchQueue.main.async { [weak picker, weak delegate] in
            guard let delegate else { return }
            guard let picker else { delegate.presentationFailed(); return }
            if picker.presentingViewController == nil && !picker.isBeingPresented && picker.viewIfLoaded?.window == nil {
                delegate.presentationFailed()
            }
        }
	}

	private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
		let startDirectory: URL?
		private let _finish: ([URL]) -> Void
		private var _scoped: URL?
        private var _finished = false

		init(folder: ImportFolder?, finish: @escaping ([URL]) -> Void) {
			_finish = finish
			startDirectory = folder.flatMap(Self._bookmarked)
			super.init()
			// Scope must stay held while presented or directoryURL is ignored.
			if let url = startDirectory, url.startAccessingSecurityScopedResource() { _scoped = url }
		}

		func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
			_end(urls)
		}

		func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
			_end([])
		}

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { _end([]) }
        func presentationFailed() { _end([]) }

        deinit { _scoped?.stopAccessingSecurityScopedResource() }

		private func _end(_ urls: [URL]) {
            guard !_finished else { return }
            _finished = true
			_scoped?.stopAccessingSecurityScopedResource()
			_scoped = nil
			_finish(urls)
		}

		private static func _bookmarked(_ folder: ImportFolder) -> URL? {
			guard let data = UserDefaults.standard.data(forKey: folder.bookmarkKey) else { return nil }
			var stale = false
			return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
		}
	}
}
