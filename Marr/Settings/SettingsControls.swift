import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CompactSettingsGroup<Content: View>: View {
    let title: String
    let info: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, info: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.info = info
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack(spacing: 5) {
                Text(title)
                    .marrTextStyle(.body, weight: .semibold)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                if let info { MarrSettingsInfo(title: title, message: info) }
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactSettingsRow<Control: View>: View {
    let title: String
    let systemImage: String
    let info: String?
    @ViewBuilder let control: () -> Control

    init(
        _ title: String,
        systemImage: String,
        info: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.systemImage = systemImage
        self.info = info
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MarrUI.Spacing.regular) {
                rowLabel.fixedSize()
                Spacer(minLength: 0)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                rowLabel
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var rowLabel: some View {
        HStack(spacing: 5) {
            Text(title).marrTextStyle(.body).foregroundStyle(.primary)
            if let info { MarrSettingsInfo(title: title, message: info) }
        }
    }
}

struct MarrSettingsInfo: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            MarrIcon("info.circle", size: MarrUI.Icon.status)
                .foregroundStyle(.secondary).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(message)
        .accessibilityLabel("About " + title)
        .popover(isPresented: $isPresented) {
            Text(message).marrTextStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(width: 260, alignment: .leading)
        }
    }
}

struct CompactSettingsDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.marrAccessibilityOverrides) private var accessibilityOverrides

    var body: some View {
        let increasedContrast = accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
        Rectangle()
            .fill(MarrUI.Border.color(.subtle, increasedContrast: increasedContrast))
            .frame(height: MarrUI.Border.width(.subtle, increasedContrast: increasedContrast))
            .accessibilityHidden(true)
    }
}

struct CompactCredentialEditor: View {
    @ObservedObject var controller: MarrController
    let credential: InferenceCredential
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: credential)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack(spacing: MarrUI.Spacing.regular) {
                SecureField("API key", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .marrSurface(.input, cornerRadius: MarrUI.Radius.control)
                    .onSubmit(save)

                if state.isConfigured == true {
                    Button {
                        showsRemoveConfirmation = true
                    } label: {
                        MarrIcon("trash")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isBusy)
                    .help("Remove key")
                }

                Button(action: save) {
                    Group {
                        if state.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            MarrIcon("checkmark")
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedDraft.isEmpty || state.isBusy)
                .help("Save and verify")
            }

            CompactCredentialStateLabel(state: state)

            if let message = state.message {
                Text(message)
                    .marrTextStyle(.secondary)
                    .foregroundStyle(state.messageIsError ? MarrUI.Status.error.color() : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .task {
            await controller.refreshCredentialState(for: credential)
        }
        .confirmationDialog("Remove API key?", isPresented: $showsRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    if await controller.removeCredential(credential) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: credential) {
                draft = ""
            }
        }
    }
}

struct CompactHeadersCredentialEditor: View {
    @ObservedObject var controller: MarrController
    let credential: InferenceCredential
    @State private var draft = ""
    @State private var showsRemoveConfirmation = false

    private var state: InferenceCredentialState {
        controller.credentialState(for: credential)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            TextEditor(text: $draft)
                .marrTextStyle(.code)
                .frame(minHeight: 58)
                .scrollContentBackground(.hidden)
                .padding(6)
                .marrSurface(.input, cornerRadius: MarrUI.Radius.control)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Header: value")
                            .marrTextStyle(.code)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: MarrUI.Spacing.regular) {
                CompactCredentialStateLabel(state: state)

                Spacer()

                if state.isConfigured == true {
                    Button {
                        showsRemoveConfirmation = true
                    } label: {
                        MarrIcon("trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state.isBusy)
                    .help("Remove headers")
                }

                Button("Save", action: save)
                    .controlSize(.small)
                    .disabled(trimmedDraft.isEmpty || state.isBusy)
            }

            if let message = state.message {
                Text(message)
                    .marrTextStyle(.secondary)
                    .foregroundStyle(state.messageIsError ? MarrUI.Status.error.color() : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .task {
            await controller.refreshCredentialState(for: credential)
        }
        .confirmationDialog("Remove headers?", isPresented: $showsRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    if await controller.removeCredential(credential) {
                        draft = ""
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty, !state.isBusy else { return }
        let value = draft
        Task {
            if await controller.saveAndVerifyCredential(value, for: credential) {
                draft = ""
            }
        }
    }
}

private struct CompactCredentialStateLabel: View {
    let state: InferenceCredentialState

    var body: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            if state.activity == .checking {
                ProgressView()
                    .controlSize(.small)
                Text("Checking")
            } else if state.isConfigured == true {
                MarrStatusLabel(.success, title: "Saved")
            } else if state.isConfigured == false {
                MarrStatusLabel(.idle, title: "Not set")
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Checking")
            }
        }
        .marrTextStyle(.secondary)
        .foregroundStyle(.secondary)
    }
}

struct CompactReadOnlySetting: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        CompactSettingsRow(title, systemImage: systemImage) {
            Text(value)
                .marrTextStyle(.code)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
