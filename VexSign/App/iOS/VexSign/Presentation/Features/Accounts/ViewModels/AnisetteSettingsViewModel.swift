import Foundation
import Combine

@MainActor
final class AnisetteSettingsViewModel: ObservableObject {
    @Published private(set) var currentDescriptor: AnisetteConfiguration?
    let useCase: AnisetteProviderUseCase

    var isConfigured: Bool { currentDescriptor != nil }

    init(useCase: AnisetteProviderUseCase) {
        self.useCase = useCase
        reload()
    }

    func reload() { currentDescriptor = useCase.currentConfiguration }
}
