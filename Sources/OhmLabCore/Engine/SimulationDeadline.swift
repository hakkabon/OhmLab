import Foundation

/// Cooperative wall-clock deadline shared by a host and the solver it runs.
///
/// The host sets `instant` as a task-local around execution. Long-running
/// solver loops call `check()` at their natural checkpoints, so a deadline is
/// enforced by the work itself rather than only by a timer task that may be
/// starved by a blocking solve. `check()` also honors normal Swift task
/// cancellation.
public enum SimulationExecutionDeadline {
    @TaskLocal public static var instant: ContinuousClock.Instant?

    public static func check() throws {
        try Task.checkCancellation()
        if let instant, ContinuousClock().now >= instant {
            throw SimulationDeadlineError.deadlineExceeded
        }
    }
}

public enum SimulationDeadlineError: LocalizedError, Equatable {
    case deadlineExceeded

    public var errorDescription: String? {
        "simulation deadline exceeded"
    }
}
