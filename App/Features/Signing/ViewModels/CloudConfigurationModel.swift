import Foundation
import Combine

@MainActor
final class CloudConfigurationModel: ObservableObject {
    @Published private(set) var state: CloudConfigurationState
    private let useCase: CloudConfigurationUseCase
    private var observation: Task<Void, Never>?
    init(useCase: CloudConfigurationUseCase) {
        self.useCase = useCase; state = useCase.state()
        let changes = useCase.changes()
        observation = Task { @MainActor [weak self] in
            for await value in changes {
                guard !Task.isCancelled, let self else { break }
                self.state = value
            }
        }
    }
    deinit { observation?.cancel() }
    var isEnabled: Bool {
        get { state.isEnabled }
        set { useCase.setEnabled(newValue); state = useCase.state() }
    }
    var serverURLString: String {
        get { state.endpoint }
        set { useCase.setEndpoint(newValue); state = useCase.state() }
    }
    var apiKey: String {
        get { useCase.bearerToken() }
        set { useCase.setBearerToken(newValue) }
    }
    var isTesting: Bool { state.isTesting }
    var lastTestResult: String? { state.lastTestResult }
    var lastHealthCheckSucceeded: Bool? { state.lastHealthCheckSucceeded }
    func testConnection() async { await useCase.testConnection(); state = useCase.state() }
}
