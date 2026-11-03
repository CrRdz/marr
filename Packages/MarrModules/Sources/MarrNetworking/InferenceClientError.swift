import Foundation
import MarrCore

public enum InferenceClientError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyAnswer
    case outputTruncated
    case refused(String)
    case unsupportedAttachment(String)
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "AI API URL is invalid."
        case .invalidResponse:
            "The AI provider returned an invalid response."
        case .apiError(let message):
            "AI provider error: \(message)"
        case .emptyAnswer:
            "The AI provider returned an empty answer."
        case .outputTruncated:
            "The AI provider stopped because the output limit was reached. Increase Maximum Output Tokens and retry."
        case .refused(let message):
            "The AI provider declined the request: \(message)"
        case .unsupportedAttachment(let message):
            message
        case .incompleteStream:
            "The connection ended before the answer was complete. The received text has been kept."
        }
    }
}
