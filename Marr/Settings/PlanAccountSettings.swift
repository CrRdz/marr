import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct ChatGPTPlanSettings: View {
    @ObservedObject var controller: MarrController

    var body: some View {
        MarrChatGPTAccountSettings(profiles: controller.chatGPTProfiles,
            activeProfileID: controller.chatGPTActiveProfileID, isBusy: controller.chatGPTBusy,
            isRefreshing: controller.chatGPTModelsLoading,
            status: controller.chatGPTModelError ?? controller.chatGPTStatus, usesPlan: controller.provider == .chatGPT) { action in
            switch action {
            case .signIn: controller.signInWithChatGPT()
            case .addAccount: controller.signInWithChatGPT(newAccount: true)
            case .select(let id): controller.selectChatGPTProfile(id)
            case .reconnect(let id): controller.reconnectChatGPTProfile(id)
            case .enablePlan: controller.signInWithChatGPT(requestConsent: true)
            case .usePlan: controller.provider = .chatGPT
            case .signOut: controller.signOutOfChatGPT()
            case .refresh: controller.refreshChatGPTAccount(forceRefresh: true)
            case .cancel: controller.cancelChatGPTSignIn()
            }
        }
        .onAppear { controller.refreshChatGPTAccount() }
        .alert("You’re using your ChatGPT plan", isPresented: $controller.showsChatGPTWelcome) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible Conversation and translation requests use your ChatGPT plan. Manage usage in ChatGPT settings.")
        }
    }

}

/// Pure presentation keeps account layout independent of OAuth and its side effects.
struct MarrChatGPTAccountSettings: View {
    enum Action {
        case signIn, addAccount, select(String), reconnect(String), enablePlan, usePlan, signOut, refresh, cancel
    }
    let profiles: [ChatGPTProfile]
    let activeProfileID: String?
    var isBusy = false
    var isRefreshing = false
    var status = ""
    var usesPlan = true
    let onAction: (Action) -> Void

    private var activeProfile: ChatGPTProfile? { profiles.first { $0.id == activeProfileID } }

    var body: some View {
        CompactSettingsGroup("ChatGPT") {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
                ForEach(profiles) { profile in
                    accountRow(profile)
                    CompactSettingsDivider()
                }
                if let activeProfile, activeProfile.isSignedIn {
                    if !activeProfile.canUsePlan {
                        Button("Enable ChatGPT plan usage") { onAction(.enablePlan) }
                            .buttonStyle(MarrButtonStyle(.secondary, size: .compact))
                            .disabled(isBusy)
                    } else if !usesPlan {
                        Button("Use for conversations") { onAction(.usePlan) }
                            .buttonStyle(MarrButtonStyle(.secondary, size: .compact))
                            .disabled(isBusy)
                    }
                }
                HStack(spacing: MarrUI.Spacing.regular) {
                    if profiles.isEmpty {
                        Button("Continue with ChatGPT") { onAction(.signIn) }
                            .buttonStyle(MarrButtonStyle(.primary, size: .compact))
                    } else {
                        Button("Add account") { onAction(.addAccount) }
                            .buttonStyle(MarrButtonStyle(.secondary, size: .compact))
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Refresh accounts") { onAction(.refresh) }
                        if let activeProfile, activeProfile.isSignedIn {
                            Button("Reconnect") { onAction(.reconnect(activeProfile.id)) }
                            Divider()
                            Button("Sign out", role: .destructive) { onAction(.signOut) }
                        }
                    } label: {
                        MarrIcon("ellipsis").frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Account actions").accessibilityLabel("Account actions")
                }
                .disabled(isBusy)
                if isBusy || isRefreshing {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        ProgressView().controlSize(.small)
                        Text("Updating connection…").marrTextStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Cancel") { onAction(.cancel) }.controlSize(.small)
                    }
                }
                if !status.isEmpty {
                    Text(status).marrTextStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.top, 8)
            CompactSettingsDivider().padding(.top, 16)
            CompactSettingsRow("Plan usage", systemImage: "chart.bar") {
                Link(destination: URL(string: "https://chatgpt.com/settings/usage")!) {
                    Label("Manage usage", marrSymbol: "arrow.up.right")
                }
                .marrTextStyle(.secondary)
            }
        }
    }

    private func accountRow(_ profile: ChatGPTProfile) -> some View {
        HStack(alignment: .top, spacing: MarrUI.Spacing.medium) {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                Text(profile.label).marrTextStyle(.body, weight: .medium)
                Text(profile.email ?? "Registration pending sign-in")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Text(profile.isSignedIn ? (profile.canUsePlan ? "Plan access enabled" : "Plan access not enabled") : "Signed out")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !profile.isSignedIn {
                Button("Sign in") { onAction(.reconnect(profile.id)) }
                    .buttonStyle(MarrButtonStyle(.secondary, size: .compact)).disabled(isBusy)
            } else if profile.id == activeProfileID {
                Label("Selected", marrSymbol: "checkmark")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Button("Select") { onAction(.select(profile.id)) }
                    .buttonStyle(MarrButtonStyle(.secondary, size: .compact)).disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct MarrCodexSyncSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController

    var body: some View {
        CompactSettingsGroup("Codex compatibility") {
            HStack(spacing: 5) {
                Text("Sync Codex work").marrTextStyle(.body)
                MarrSettingsInfo(title: "Sync Codex work",
                    message: "Sync Codex workspaces, chats and runtime tools. Turning this off keeps your local Marr workspaces and chats available.")
                Spacer(minLength: 0)
                Toggle("Sync Codex work", isOn: Binding(
                    get: { workspace.codexSyncEnabled },
                    set: { _ = workspace.setCodexSyncEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }.padding(.vertical, 8)
            if !workspace.codexSyncStatusMessage.isEmpty {
                Text(workspace.codexSyncStatusMessage)
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}
