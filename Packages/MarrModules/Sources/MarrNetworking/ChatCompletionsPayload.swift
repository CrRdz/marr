import Foundation
import MarrCore

struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: Content
    }

    enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text):
                try container.encode(text)
            case .parts(let parts):
                try container.encode(parts)
            }
        }
    }

    struct Part: Encodable {
        let type: String
        var text: String?
        var imageURL: ImageURL?
        var file: File?

        enum CodingKeys: String, CodingKey {
            case type, text, file
            case imageURL = "image_url"
        }
    }

    struct ImageURL: Encodable {
        let url: String
    }

    struct File: Encodable {
        let filename: String
        let fileData: String

        enum CodingKeys: String, CodingKey {
            case filename
            case fileData = "file_data"
        }
    }
}

struct ChatCompletionsEnvelope: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: Content?
        let refusal: String?

        var refusalText: String? {
            let text = refusal?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : content?.refusalText
        }
    }

    enum Content: Decodable {
        case text(String)
        case parts([Part])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .parts(try container.decode([Part].self))
            }
        }

        var text: String {
            switch self {
            case .text(let text):
                return text
            case .parts(let parts):
                return parts.filter { $0.type == "text" || $0.type == "output_text" }
                    .compactMap(\.text)
                    .joined(separator: "\n\n")
            }
        }

        var refusalText: String? {
            guard case .parts(let parts) = self else { return nil }
            let text = parts.filter { $0.type == "refusal" }
                .compactMap(\.refusal)
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    struct Part: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}
