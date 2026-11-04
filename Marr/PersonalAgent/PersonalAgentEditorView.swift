import AppKit
import SwiftUI

enum PersonalAgentEditor: Identifiable {
    case agent(PersonalAgentProfile), routine(PersonalAgentRoutine), skill(PersonalAgentSkill)
    var id: UUID {
        switch self { case .agent(let item): item.id; case .routine(let item): item.id; case .skill(let item): item.id }
    }
}

struct PersonalAgentEditorView: View {
    let editor: PersonalAgentEditor
    @ObservedObject var coordinator: PersonalAgentCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var agent: PersonalAgentProfile
    @State private var routine: PersonalAgentRoutine
    @State private var skill: PersonalAgentSkill
    @State private var error: String?
    @State private var confirmsDelete = false
    @State private var saving = false

    init(editor: PersonalAgentEditor, coordinator: PersonalAgentCoordinator) {
        self.editor = editor; self.coordinator = coordinator
        _agent = State(initialValue: { if case .agent(let item) = editor { item } else { PersonalAgentProfile() } }())
        _routine = State(initialValue: { if case .routine(let item) = editor { item } else { PersonalAgentRoutine(agentID: UUID()) } }())
        _skill = State(initialValue: { if case .skill(let item) = editor { item } else { PersonalAgentSkill() } }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).marrTextStyle(.pageTitle, weight: .semibold)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch editor {
                    case .agent: agentFields
                    case .routine: routineFields
                    case .skill: skillFields
                    }
                }.padding(2)
            }
            if let error { Text(error).marrTextStyle(.secondary).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if exists {
                    Button("Delete…", role: .destructive) { confirmsDelete = true }.disabled(isBusy || saving)
                }
                Spacer()
                Button("Save") { save() }.buttonStyle(PersonalAgentButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(isBusy || saving)
            }
            if isBusy { Text("Wait for this agent’s run to finish before changing its configuration.").marrTextStyle(.caption).foregroundStyle(.secondary) }
        }
        .padding(24).frame(width: 380, height: 510)
        .confirmationDialog("Delete \(title.lowercased())?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Related schedules will stop. Run history and files are kept.") }
    }

    private var title: String {
        switch editor { case .agent: "Agent details"; case .routine: "Routine"; case .skill: "Skill" }
    }
    private var exists: Bool {
        switch editor {
        case .agent: coordinator.archive.agents.contains { $0.id == editor.id }
        case .routine: coordinator.archive.routines.contains { $0.id == editor.id }
        case .skill: coordinator.archive.skills.contains { $0.id == editor.id }
        }
    }
    private var isBusy: Bool {
        let id: UUID?
        switch editor { case .agent: id = agent.id; case .routine: id = routine.agentID; case .skill: id = nil }
        return coordinator.archive.runs.contains { ($0.status.isInFlight || $0.status == .uncertain) && (id == nil || $0.agentID == id) }
    }

    private var agentFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                MarrAgentEmblem().hueRotation(.degrees(Double(agent.tint))).frame(width: 48, height: 48)
                Picker("Color", selection: $agent.tint) {
                    Text("Blue").tag(0); Text("Mint").tag(80); Text("Lilac").tag(300)
                }
            }
            field("Name", text: $agent.name)
            field("Role", text: $agent.role)
            multiline("Instructions", hint: "What should this agent do, and what does a good result look like?", text: $agent.instructions)
            multiline("Memory", hint: "Stable preferences and context you want it to retain.", text: $agent.memory)
            Picker("File access", selection: $agent.access) {
                ForEach(PersonalAgentAccess.allCases) { Text($0.title).tag($0) }
            }
            Text("The runtime enforces the file sandbox. Extra access requires approval. Connected app tools are not enabled yet.")
                .marrTextStyle(.caption).foregroundStyle(.secondary)
            if exists && !coordinator.cloud.enabled {
                Button("Open agent folder") {
                    do { NSWorkspace.shared.open(try coordinator.store.workspaceURL(for: agent.id)) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(PersonalAgentButtonStyle())
            }
            skillSelection($agent.skillIDs)
            Stepper("Time limit: \(agent.maxRunMinutes) min", value: $agent.maxRunMinutes, in: 1...60)
            Stepper("Routine limit: \(agent.dailyRoutineLimit) / 24h", value: $agent.dailyRoutineLimit, in: 1...100)
            Toggle("Pause this agent", isOn: $agent.isPaused)
        }.marrTextStyle(.secondary)
    }

    private var routineFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Name", text: $routine.name)
            Picker("Agent", selection: $routine.agentID) {
                ForEach(coordinator.archive.agents) { Text($0.name).tag($0.id) }
            }
            multiline("Instruction", hint: "Describe the check, sources and expected result. Say what counts as no change.", text: $routine.instruction)
            Picker("Repeat", selection: $routine.schedule.frequency) {
                ForEach(PersonalAgentSchedule.Frequency.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                if routine.schedule.frequency != .hourly {
                    Picker("Hour", selection: $routine.schedule.hour) {
                        ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                }
                Picker("Minute", selection: $routine.schedule.minute) {
                    ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) }
                }
            }
            field("Time zone", text: $routine.schedule.timeZoneID)
            skillSelection($routine.skillIDs)
            Toggle("Enable schedule", isOn: $routine.isEnabled)
            Text(coordinator.cloud.enabled ? "Runs on your server, including when this Mac is offline." : "Runs while Marr is open and this Mac is awake.")
                .marrTextStyle(.caption).foregroundStyle(.secondary)
            if routine.schedule.isValid, let next = routine.schedule.next(after: Date()) {
                Text("Next scheduled time: \(routine.schedule.formatted(next))")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
            }
        }.marrTextStyle(.secondary)
    }

    private var skillFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Name", text: $skill.name)
            multiline("Workflow", hint: "Include required inputs, steps, verification, output format, and when to ask for approval.", text: $skill.instructions, height: 210)
            Text("Skills are shared across agents. Saving a skill does not run it or grant tool access.")
                .marrTextStyle(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).marrTextStyle(.secondary, weight: .medium)
            TextField(label, text: text).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(label)
        }
    }

    private func multiline(_ label: String, hint: String, text: Binding<String>, height: CGFloat = 85) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).marrTextStyle(.secondary, weight: .medium)
            Text(hint).marrTextStyle(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).marrTextStyle(.body).frame(height: height).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)))
                .accessibilityLabel(label)
        }
    }

    private func skillSelection(_ selected: Binding<[UUID]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skills").marrTextStyle(.secondary, weight: .medium)
            if coordinator.archive.skills.isEmpty { Text("Add workflows from the Skills menu.").marrTextStyle(.caption).foregroundStyle(.secondary) }
            ForEach(coordinator.archive.skills) { item in
                Toggle(item.name, isOn: Binding(get: { selected.wrappedValue.contains(item.id) }, set: { enabled in
                    if enabled { selected.wrappedValue.append(item.id) } else { selected.wrappedValue.removeAll { $0 == item.id } }
                })).toggleStyle(.checkbox)
            }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let value: PersonalAgentEditor
                switch editor { case .agent: value = .agent(agent); case .routine: value = .routine(routine); case .skill: value = .skill(skill) }
                try await coordinator.save(value)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        saving = true
        Task {
            defer { saving = false }
            do { try await coordinator.remove(editor); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
