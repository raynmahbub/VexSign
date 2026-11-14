//
//  StdoutCapture.swift
//  VexSign
//
//  Created by VexSign Team
//

import Foundation

// Scoped stdout/stderr capture (restored on stop) so zsign's C output joins the signing log.
final class StdoutCapture {
	static let shared = StdoutCapture()
	private init() {}

	private let _queue = DispatchQueue(label: "app.vexsign.stdoutcapture")
	private var _pipe: Pipe?
	private var _savedOut: Int32 = -1
	private var _savedErr: Int32 = -1
	private var _buffer = Data()
	private var _onLine: ((String) -> Void)?

	/// Starts capturing the process's stdout/stderr until `stop()` is called.
	///
	/// Capture is process-wide, so only one scope can own it at a time. A second caller
	/// gets `false` instead of silently receiving nothing - and, just as importantly, must
	/// not call `stop()`, because that would restore the descriptors the first caller is
	/// still relying on. The signing gate normally makes the second caller impossible; this
	/// keeps a future caller from turning that assumption into lost log output.
	/// - Returns: `true` when this call owns the capture.
	@discardableResult
	func start(_ onLine: @escaping (String) -> Void) -> Bool {
		_queue.sync {
			guard _pipe == nil else { return false }

			let pipe = Pipe()
			_onLine = onLine
			_savedOut = dup(STDOUT_FILENO)
			_savedErr = dup(STDERR_FILENO)

			let writeFd = pipe.fileHandleForWriting.fileDescriptor
			dup2(writeFd, STDOUT_FILENO)
			dup2(writeFd, STDERR_FILENO)
			_pipe = pipe

			pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
				let data = handle.availableData
				guard !data.isEmpty, let self else { return }
				self._queue.async { self._consume(data) }
			}
			return true
		}
	}

	func stop() {
		_queue.sync {
			guard let pipe = _pipe else { return }

			fflush(stdout)
			fflush(stderr)
			if _savedOut >= 0 { dup2(_savedOut, STDOUT_FILENO); close(_savedOut); _savedOut = -1 }
			if _savedErr >= 0 { dup2(_savedErr, STDERR_FILENO); close(_savedErr); _savedErr = -1 }

			pipe.fileHandleForReading.readabilityHandler = nil
			try? pipe.fileHandleForWriting.close()
			_consume(pipe.fileHandleForReading.readDataToEndOfFile())
			if !_buffer.isEmpty {
				_emit(_buffer)
				_buffer.removeAll()
			}

			try? pipe.fileHandleForReading.close()
			_pipe = nil
			_onLine = nil
		}
	}

	private func _consume(_ data: Data) {
		guard !data.isEmpty else { return }
		_buffer.append(data)

		let newline = UInt8(ascii: "\n")
		while let index = _buffer.firstIndex(of: newline) {
			let line = _buffer.subdata(in: _buffer.startIndex..<index)
			_buffer.removeSubrange(_buffer.startIndex...index)
			_emit(line)
		}
	}

	private func _emit(_ data: Data) {
		guard
			let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
			!text.isEmpty
		else { return }
		_onLine?(text)
	}
}
