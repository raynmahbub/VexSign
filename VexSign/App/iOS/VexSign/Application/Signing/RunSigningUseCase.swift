import Foundation

/// Preserves the existing pipeline while owning its application-level event
/// contract: ordered progress, pre-start cancellation, and exactly one terminal
/// event. Admission/leases remain with SigningService and the existing registry.
struct RunSigningUseCase<Request, Artifact> {
    private let work: any SigningWork<Request, Artifact>

    init(work: any SigningWork<Request, Artifact>) { self.work = work }

    func execute(_ request: Request, reporting: @escaping (SigningWorkflowEvent<Artifact>) -> Void) async {
        let result: Result<Artifact, Error>
        if Task.isCancelled {
            result = .failure(CancellationError())
        } else {
            result = await work.run(request) { event in
                // A misbehaving engine/pipeline cannot publish a second verdict.
                if !event.isTerminal { reporting(event) }
            }
        }

        switch result {
        case .success(let artifact): reporting(.finished(artifact))
        case .failure(let error) where error is CancellationError: reporting(.cancelled)
        case .failure(let error): reporting(.failed(error))
        }
    }
}
