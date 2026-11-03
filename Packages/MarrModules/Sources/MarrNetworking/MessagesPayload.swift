import Foundation
import MarrCore

struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Content: Encodable {
        let type: String
        let text: String?
        let source: Source?
        let title: String?

        init(type: String, text: String?, source: Source?, title: String? = nil) {
            self.type = type
            self.text = text
            self.source = source
            self.title = title
        }
    }

    struct Source: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}

struct AnthropicMessagesEnvelope: Decodable {
    let content: [Content]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }
    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try container.decode(Int.self, forKey: .inputTokens)
            outputTokens = try container.decode(Int.self, forKey: .outputTokens)
            cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
            cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
        }
    }
}
