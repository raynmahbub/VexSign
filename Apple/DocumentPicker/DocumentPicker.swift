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
	/// Opens the system picker.
	///
	/// `onUnavailable` is called when the picker could not be shown at all: another
	/// presentation already owns the window, or UIKit refused it. That used to be
	/// indistinguishable from the user cancelling — a tap on Import could do
	/// nothing and say nothing — so a caller that passes this closure can tell the
	/// user instead of leaving the button looking dead.
	static func open(
		_ types: [UTType],
		multiple: Bool = false,
        asCopy: Bool = true,
		folder: ImportFolder? = nil,
		onUnavailable: (() -> Void)? = nil,
		onPick: @escaping ([URL]) -> Void
	) {
        // Pairing credentials opt out of an OS-created Documents/Inbox copy.
        // Their owner holds a security scope while reading into protected storage.
		let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
		picker.allowsMultipleSelection = multiple
		let presented = _present(picker, folder: folder, onUnavailable: onUnavailable) { urls in
			guard !urls.isEmpty else { return }
			onPick(urls)
		}
		guard !presented else { return }
		onUnavailable?()
	}

	static func export(_ urls: [URL], onFinish: (() -> Void)? = nil) {
		guard !urls.isEmpty else { onFinish?(); return }
		let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
		picker.directoryURL = UserDefaults.standard.bool(forKey: "VexSign.useLastExportLocation")
			? nil
			: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		// A credential export still has to clean up when it cannot be presented.
		let presented = _present(picker, folder: nil) { _ in onFinish?() }
		guard !presented else { return }
		onFinish?()
	}

	private static var _delegates: [ObjectIdentifier: Delegate] = [:]

	/// Presents `picker`, or reports that it could not be presented.
	///
	/// Returning the outcome instead of calling `onFinish([])` keeps "the user
	/// cancelled" and "the window was busy" apart: they need different answers, and
	/// only one of them is the user's own doing.
	private static func _present(
		_ picker: UIDocumentPickerViewController,
		folder: ImportFolder?,
		onUnavailable: (() -> Void)? = nil,
		onFinish: @escaping ([URL]) -> Void
	) -> Bool {
        guard let presenter = UIApplication.topViewController(), presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil, !presenter.isBeingPresented, !presenter.isBeingDismissed,
              presenter.transitionCoordinator == nil,
              !(presenter is UIAlertController), !(presenter is UIDocumentPickerViewController) else {
            return false
        }

		let key = ObjectIdentifier(picker)
		let delegate = Delegate(folder: folder, onUnavailable: onUnavailable) { urls in
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
        return true
	}

	private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
		let startDirectory: URL?
		private let _finish: ([URL]) -> Void
		/// Called only when UIKit refused the presentation. A cancel by the user is
		/// not a failure and must not be reported as one.
		private let _onUnavailable: (() -> Void)?
		private var _scoped: URL?
        private var _finished = false

		init(folder: ImportFolder?, onUnavailable: (() -> Void)? = nil, finish: @escaping ([URL]) -> Void) {
			_finish = finish
			_onUnavailable = onUnavailable
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
        func presentationFailed() {
            _onUnavailable?()
            _end([])
        }

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
