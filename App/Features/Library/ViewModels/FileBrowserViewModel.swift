import Foundation
import Combine
import SwiftUI
import NimbleExtensions

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published private(set) var entries: [IPAFileEntry] = []
    @Published var query = ""
    @Published var sort: ItemSortOption = .nameAZ
    @Published var showsHidden = false
    @Published private(set) var isLoading = false

    private let useCase: FileWorkspaceUseCase
    private var currentDirectory: URL
    private var reloadTask: Task<Void, Never>?
    private var generation = UUID()
    private var cancellables = Set<AnyCancellable>()

    init(useCase: FileWorkspaceUseCase, directory: URL? = nil) {
        self.useCase = useCase
        currentDirectory = directory ?? useCase.roots.documents
        $showsHidden.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }
    deinit { reloadTask?.cancel() }

    func setDirectory(_ url: URL) { currentDirectory = url; reload() }
    func reload() {
        reloadTask?.cancel()
        let request = UUID()
        generation = request
        isLoading = true
        let directory = currentDirectory
        let hidden = showsHidden
        let useCase = useCase
        reloadTask = Task { @MainActor [weak self] in
            let items = await useCase.children(of: directory, includesHidden: hidden, measuringDirectorySize: false)
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.entries = items
            self.isLoading = false
        }
    }

    var visible: [IPAFileEntry] {
        let filtered = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return sort.comparator()($0, $1)
        }
    }
    func count(at url: URL) -> Int { useCase.count(at: url) }
    func size(at url: URL) -> String { useCase.size(at: url).formattedFileSize }
}
