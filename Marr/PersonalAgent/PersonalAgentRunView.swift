import SwiftUI

struct PersonalAgentRunView: View {
    let run: PersonalAgentRun
    @ObservedObject var coordinator: PersonalAgentCoordinator
    var showsPrompt = false
    var showsCompletionStatus = false
    @State private var expanded = false
    private var isActive: Bool { coordinator.cloud.enabled ? run.status.isInFlight : coordinator.activeRunID == run.id }
    private var result: String { !coordinator.cloud.enabled && isActive && !coordinator.liveText.isEmpty ? coordinator.liveText : run.result }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            if showsPrompt {
                HStack(alignment: .bottom) {
                    Spacer(minLength: 72)
                    VStack(alignment: .trailing, spacing: MarrUI.Spacing.tight) {
                        UserMessageContent(source: run.prompt).marrChatBubble()
                        MarrMessageActions(text: run.prompt, copyTitle: "Copy message")
                    }
                }
            }
            if run.status != .succeeded || showsCompletionStatus || run.routineID != nil {
                HStack(spacing: MarrUI.Spacing.regular) {
                    if isActive && run.status == .running { MarrActivityIndicator(color: .secondary) }
                    else { MarrIcon(symbol, size: 13) }
                    Text(coordinator.isStopping && isActive ? "Stopping…" : run.status.title).marrTextStyle(.secondary, weight: .medium)
                    if run.routineID != nil { Text("Routine").marrTextStyle(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(run.startedAt, style: .time).marrTextStyle(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 10)
            }
            if !result.isEmpty {
                if result.trimmingCharacters(in: .whitespacesAndNewlines) == "NO_UPDATE" {
                    Text("Checked · no changes to report").marrTextStyle(.secondary).foregroundStyle(.secondary)
                } else {
                    MarkdownResponseView(source: result).textSelection(.enabled)
                        .padding(.horizontal, 4).padding(.vertical, 4)
                    MarrMessageActions(text: result).padding(.leading, 4)
                }
            }
            if !run.detail.isEmpty { Text(run.detail).marrTextStyle(.secondary).foregroundStyle(.secondary).textSelection(.enabled) }
            if isActive {
                ForEach(coordinator.requests(for: run)) { request in
                    PersonalAgentInteractionView(request: request, runID: run.id, coordinator: coordinator)
                }
            }
            if run.status == .uncertain {
                HStack {
                    Button(coordinator.checkingRunID == run.id ? "Checking…" : "Check connection") { coordinator.check(run) }
                    if run.turnID != nil {
                        Button("Stop run") { coordinator.check(run, stopIfRunning: true) }
                    }
                }.buttonStyle(PersonalAgentButtonStyle()).disabled(coordinator.checkingRunID != nil || coordinator.activeRunID != nil)
            }
            if !run.trace.isEmpty {
                DisclosureGroup("Activity · \(run.trace.count)", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(run.trace) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).marrTextStyle(.caption, weight: .semibold)
                                if !item.detail.isEmpty {
                                    Text(item.detail).marrTextStyle(.code).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }.padding(.top, 8)
                }.marrTextStyle(.caption).foregroundStyle(.secondary)
            }
            if !run.isRead, !run.status.isInFlight {
                Button("Mark as read") { coordinator.markRead(run.id) }.buttonStyle(.link).marrTextStyle(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch run.status {
        case .succeeded: "checkmark.circle"
        case .failed, .uncertain: "exclamationmark.triangle"
        case .needsInput: "hand.raised"
        case .cancelled: "stop.fill"
        case .running: "clock"
        }
    }
}

private struct PersonalAgentInteractionView: View {
    let request: CodexInteractionRequest
    let runID: UUID
    @ObservedObject var coordinator: PersonalAgentCoordinator
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title).marrTextStyle(.body, weight: .semibold)
            if !request.message.isEmpty { Text(request.message).marrTextStyle(.secondary).textSelection(.enabled) }
            if !request.preview.isEmpty {
                ScrollView { Text(request.preview).marrTextStyle(.code).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).marrTextStyle(.secondary)
                    if !question.options.isEmpty {
                        Picker(question.header, selection: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })) {
                            Text("Choose…").tag("")
                            ForEach(question.options) { Text($0.label).tag($0.label) }
                        }.labelsHidden()
                    }
                    if question.isOther || question.options.isEmpty {
                        if question.isSecret {
                            SecureField("Your answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                        } else {
                            TextField("Your answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                        }
                    }
                }
            }
            HStack {
                Button("Decline") { coordinator.respond(request, runID: runID, action: .decline, answers: [:]) }.buttonStyle(PersonalAgentButtonStyle())
                Spacer()
                Button(request.isQuestion ? "Reply" : "Allow once") { coordinator.respond(request, runID: runID, action: .accept, answers: answers) }
                    .buttonStyle(PersonalAgentButtonStyle(primary: true))
                    .disabled(!request.supportsAcceptance || request.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }.disabled(coordinator.isStopping || coordinator.respondingRequestIDs.contains(request.id))
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
