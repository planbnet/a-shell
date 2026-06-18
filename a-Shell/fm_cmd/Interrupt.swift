import Foundation

// MARK: - Ctrl-C (SIGINT) cancellation for long-running async work
//
// Under ios_system, Ctrl-C is delivered as a thread-directed SIGINT. We install
// a plain C handler that flips a flag, then a watcher Task cancels the in-flight
// operation Task. FoundationModels' streaming/respond honour Task cancellation
// (throwing CancellationError), so generation actually stops — letting the agent
// and chat REPLs return to their prompt cleanly.

/// Reference box so an `@escaping` operation closure can hand an error back to
/// its caller (read only after the operation Task has finished).
final class ErrorBox {
    var error: Error?
}

private var fmInterruptFlag: sig_atomic_t = 0

private func fmInterruptHandler(_ sig: Int32) {
    fmInterruptFlag = 1
}

/// Runs `operation` while Ctrl-C cancels its Task. Returns `true` if it ran to
/// completion, `false` if it was interrupted by SIGINT.
@discardableResult
func runInterruptible(_ operation: @escaping () async -> Void) async -> Bool {
    fmInterruptFlag = 0
    let previous = signal(SIGINT, fmInterruptHandler)
    defer { signal(SIGINT, previous) }

    let op = Task { await operation() }
    let watcher = Task {
        while !Task.isCancelled {
            if fmInterruptFlag != 0 { op.cancel(); return }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }
    await op.value
    watcher.cancel()
    return fmInterruptFlag == 0
}
