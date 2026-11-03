import Foundation

enum BackgroundOperation {
    static func run<Value: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: priority, operation: operation)

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
