import Foundation
import MarrCore

struct ResponsesRequest: Encodable {
    let model: String
    let input: [InputMessage]
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, input
        case maxOutputTokens = "max_output_tokens"
    }

    struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable {
        let type: String
        let text: String?
        let imageURL: String?
        let fileData: String?
        let filename: String?

        init(
            type: String,
            text: String? = nil,
            imageURL: String? = nil,
            fileData: String? = nil,
            filename: String? = nil
        ) {
            self.type = type
            self.text = text
            self.imageURL = imageURL
            self.fileData = fileData
            self.filename = filename
        }

        enum CodingKeys: String, CodingKey {
            case type, text, filename
            case imageURL = "image_url"
            case fileData = "file_data"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(imageURL, forKey: .imageURL)
            try container.encodeIfPresent(fileData, forKey: .fileData)
            try container.encodeIfPresent(filename, forKey: .filename)
        }
    }
}

struct ResponsesEnvelope: Decodable {
    let status: String?
    let error: Failure?
    let incompleteDetails: IncompleteDetails?
    let output: [Output]
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case status, error, output, usage
        case incompleteDetails = "incomplete_details"
    }

    struct IncompleteDetails: Decodable { let reason: String? }
    struct Failure: Decodable { let message: String? }
    struct Output: Decodable { let content: [Content] }
    struct Content: Decodable {
        let type: String
        let text: String?
    }
    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}
