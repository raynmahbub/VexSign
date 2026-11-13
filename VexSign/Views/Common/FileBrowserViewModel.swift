//
//  FileBrowserViewModel.swift
//  VexSign — shared ViewModel for the Files browser, extracted to avoid duplicating IPAFileLoader logic.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published private(set) var entries: [IPAFileEntry] = []
    @Published var query: String = ""
    @Published var sort: ItemSortOption = .nameAZ
    @Published var showsHidden: Bool = false
    @Published var isLoading = false

    private var currentDirectory: URL = URL.documentsDirectory
    private var cancellables = Set<AnyCancellable>()

    init(directory: URL = URL.documentsDirectory) {
        currentDirectory = directory
        $query.combineLatest($sort.combineLatest($showsHidden))
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func setDirectory(_ url: URL) {
        currentDirectory = url
        reload()
    }

    func reload() {
        isLoading = true
        let dir = currentDirectory
        let hidden = showsHidden
        Task.detached(priority: .userInitiated) {
            let items = IPAFileLoader.children(of: dir, includesHidden: hidden, measuringDirectorySize: false)
            await MainActor.run {
                self.entries = items
                self.isLoading = false
            }
        }
    }

    var visible: [IPAFileEntry] {
        let filtered = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted(by: sort.comparator())
    }

    // Quick folder counts and sizes for the Quick Access grid
    func count(at url: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).count) ?? 0
    }
    func size(at url: URL) -> String {
        FileManager.default.allocatedSize(at: url).formattedFileSize
    }
}
