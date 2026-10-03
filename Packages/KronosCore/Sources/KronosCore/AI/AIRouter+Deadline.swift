// A hard wall-clock cap around one async call.
//
// `withThrowingTaskGroup` cannot do this: a group waits for every child before it returns, so a
// client that does not honour cancellation would hold the caller past the cap. This races two
// unstructured tasks and resumes the caller with whichever finishes first; the loser is cancelled
// and left to wind down on its own.

import Foundation

private final class RaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if done { lock.unlock(); task.cancel(); return }
        tasks.append(task)
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !done, let continuation else { lock.unlock(); return }
        done = true
        let all = tasks
        self.continuation = nil
        lock.unlock()
        all.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

extension AIRouter {

    /// Runs `work`; throws `AIError.timeout` when it has not returned after `seconds`. A caller
    /// cancelling its own task also cancels `work`.
    static func raced<T: Sendable>(seconds: Double,
                                   _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = RaceGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                gate.track(Task {
                    do { gate.finish(.success(try await work())) } catch { gate.finish(.failure(error)) }
                })
                gate.track(Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    gate.finish(.failure(AIError.timeout(budgetSeconds: seconds)))
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}
