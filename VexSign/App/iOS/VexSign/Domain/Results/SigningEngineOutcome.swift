import Foundation

struct SigningEngineOutcome: Equatable {
    let succeeded: Bool
    let errorMessage: String?
}
