import Foundation
import MarrCore

struct ConversationContextPolicy: Equatable, Sendable {
    var maximumCompletedTurns = 12
    var maximumTextCharacters = 24_000
    var maximumImages = AttachmentFileSupport.maximumAttachmentCount
    var maximumAttachmentBytes = AttachmentFileSupport.maximumRequestBytes

    static let `default` = ConversationContextPolicy()
}

enum ConversationSlashCommand: String, CaseIterable, Identifiable, Sendable {
    case explain
    case translate
    case summarize
    case extract
    case steps

    var id: String { rawValue }

    var invocation: String { "/\(rawValue)" }

    var symbol: String {
        switch self {
        case .explain: "text.magnifyingglass"
        case .translate: "translate"
        case .summarize: "text.alignleft"
        case .extract: "doc.text.viewfinder"
        case .steps: "list.number"
        }
    }

    var summary: String {
        switch self {
        case .explain: "Explain what is shown"
        case .translate: "Translate visible content"
        case .summarize: "Give a concise summary"
        case .extract: "Extract all readable text"
        case .steps: "Turn it into action steps"
        }
    }

    static func matching(_ input: String) -> [ConversationSlashCommand] {
        guard input.hasPrefix("/") else { return [] }
        let query = String(input.dropFirst())
        guard !query.contains(where: \.isWhitespace) else { return [] }
        return allCases.filter { $0.rawValue.hasPrefix(query.lowercased()) }
    }

    static func expandedPrompt(for rawInput: String) -> String {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard
            let token = parts.first,
            token.hasPrefix("/"),
            let command = ConversationSlashCommand(
                rawValue: String(token.dropFirst()).lowercased()
            )
        else {
            return input
        }

        let additionalInstruction = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let prompt = command.basePrompt
        guard !additionalInstruction.isEmpty else { return prompt }
        return "\(prompt)\n\nAdditional instruction: \(additionalInstruction)"
    }

    private var basePrompt: String {
        switch self {
        case .explain:
            return "Explain the latest screenshot or referenced content clearly. Identify the important elements, what they mean, and any context needed to understand them."
        case .translate:
            return "Translate the latest screenshot or referenced content. If an additional instruction specifies a target language, use it; otherwise translate into Simplified Chinese. Preserve names, numbers, code, and structure where practical."
        case .summarize:
            return "Summarize the latest screenshot or referenced content concisely. Lead with the main point, then include only the most important supporting details."
        case .extract:
            return "Extract all readable text from the latest screenshot or referenced content. Preserve the original reading order and useful structure, and do not add commentary."
        case .steps:
            return "Turn the latest screenshot or referenced content into a short, ordered list of practical next steps. Call out any missing information or risks that affect the steps."
        }
    }
}

struct ConversationContextBuilder: Sendable {
    static let systemPrompt = """
    You are Marr, a general-purpose AI assistant. Help with questions, planning, writing, analysis, screenshots, and attached files. Answer the latest user question directly and use earlier turns only when they are relevant.

    Match the user's language and requested level of detail. Lead with the answer or outcome, then give only the explanation and next steps needed to use it. Use short paragraphs and lists when they make the answer easier to scan. Avoid routine preambles, repeated conclusions, and unnecessary headings for simple questions. Preserve detail when the user requests a thorough explanation or a complete extraction or translation.

    Keep internal deliberation out of the reply. Give concise reasons, relevant evidence and uncertainty instead. Clearly distinguish suggested actions from actions actually performed; never claim a file was changed, a check passed, or an external action completed without evidence.

    Attachments belong to the user message where they appear. A newly attached image or file is new context and may differ from earlier attachments. Do not claim that two attachments are the same unless the user says so. When the question is ambiguous, prefer the most recently attached item.
    """

    let policy: ConversationContextPolicy

    init(policy: ConversationContextPolicy = .default) {
        self.policy = policy
    }

    func build(
        turns: [ConversationTurn],
        images: [UUID: ConversationImageAsset],
        through targetTurnID: UUID
    ) -> VisionRequest? {
        guard let targetIndex = turns.firstIndex(where: { $0.id == targetTurnID }) else {
            return nil
        }

        let target = turns[targetIndex]
        let completed = turns[..<targetIndex].filter {
            $0.status == .completed && !$0.answer.isEmpty
        }
        let selectedCompleted = selectCompletedTurns(Array(completed))
        var selected = selectedCompleted + [target]
        let latestImageID = turns[...targetIndex].reversed().lazy.flatMap(\.imageIDs).first
        selected = enforceImageBudget(
            selected,
            images: images,
            targetID: target.id,
            fallbackImageID: latestImageID
        )

        var messages: [VisionMessage] = []
        for turn in selected {
            var userContent: [VisionContent] = turn.imageIDs.compactMap { imageID in
                guard let attachment = images[imageID] else { return nil }
                return attachment.isImage ? .image(attachment) : .file(attachment)
            }
            userContent.append(.text(ConversationSlashCommand.expandedPrompt(for: turn.question)))
            messages.append(VisionMessage(role: .user, content: userContent))

            if turn.id != target.id, !turn.answer.isEmpty {
                messages.append(VisionMessage(role: .assistant, content: [.text(turn.answer)]))
            }
        }

        return VisionRequest(systemPrompt: Self.systemPrompt, messages: messages)
    }

    private func selectCompletedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var selected: [ConversationTurn] = []
        var characterCount = 0

        for turn in turns.reversed() {
            guard selected.count < policy.maximumCompletedTurns else { break }
            let turnCharacters = turn.question.count + turn.answer.count
            guard selected.isEmpty || characterCount + turnCharacters <= policy.maximumTextCharacters else {
                break
            }
            selected.append(turn)
            characterCount += turnCharacters
        }

        return selected.reversed()
    }

    private func enforceImageBudget(
        _ turns: [ConversationTurn],
        images: [UUID: ConversationImageAsset],
        targetID: UUID,
        fallbackImageID: UUID?
    ) -> [ConversationTurn] {
        var remainingImages = max(1, policy.maximumImages)
        var remainingBytes = max(1, policy.maximumAttachmentBytes)
        var result = turns

        for index in result.indices.reversed() {
            let imageIDs = result[index].imageIDs
            var keptImageIDs: [UUID] = []
            for imageID in imageIDs.reversed() {
                guard
                    remainingImages > 0,
                    let attachment = images[imageID],
                    attachment.data.count <= remainingBytes
                else {
                    continue
                }
                keptImageIDs.append(imageID)
                remainingImages -= 1
                remainingBytes -= attachment.data.count
            }
            keptImageIDs.reverse()

            if keptImageIDs != imageIDs {
                result[index] = ConversationTurn(
                    id: result[index].id,
                    question: result[index].question,
                    imageIDs: keptImageIDs,
                    answer: result[index].answer,
                    errorMessage: result[index].errorMessage,
                    status: result[index].status,
                    showsAssistant: result[index].showsAssistant
                )
            }
        }

        if !result.contains(where: { !$0.imageIDs.isEmpty }),
           let targetIndex = result.firstIndex(where: { $0.id == targetID }),
           let fallbackImageID,
           let fallback = images[fallbackImageID],
           fallback.data.count <= policy.maximumAttachmentBytes {
            result[targetIndex] = ConversationTurn(
                id: result[targetIndex].id,
                question: result[targetIndex].question,
                imageIDs: [fallbackImageID],
                answer: result[targetIndex].answer,
                errorMessage: result[targetIndex].errorMessage,
                status: result[targetIndex].status,
                showsAssistant: result[targetIndex].showsAssistant
            )
        }

        return result
    }
}
