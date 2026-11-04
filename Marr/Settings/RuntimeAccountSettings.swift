import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CodexAccountSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @State private var confirmsSignOut = false

    private var isBusy: Bool {
        !workspace.settingsLoadingMethods.isDisjoint(with:
            ["account/read", "account/login/start", "account/login/cancel", "account/logout"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.section) {
            CompactSettingsGroup("Connected account") {
                if let account = workspace.account {
                    detail("Sign-in method", value: account.type == "chatgpt" ? "ChatGPT" : account.type == "apiKey" ? "API key" : account.type)
                    if let email = account.email { detail("Email", value: email) }
                    if let plan = account.planType { detail("Plan", value: plan.capitalized) }
                } else {
                    Text(workspace.settingsLoadingMethods.contains("account/read") ? "Loading account…" : "No account is signed in.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    if workspace.requiresOpenAIAuth == false {
                        Text("Your current provider does not require an OpenAI sign-in.")
                            .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            if let login = workspace.accountLogin {
                CompactSettingsGroup("Complete sign-in") {
                    if let code = login.userCode {
                        Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            .padding(.vertical, 8)
                    }
                    Text("Finish signing in in your browser, then return here.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    HStack {
                        if let url = login.url {
                            Link("Open browser", destination: url)
                        }
                        Spacer()
                        Button("Cancel") { workspace.cancelAccountLogin() }
                            .disabled(isBusy)
                    }
                    .padding(.top, 12)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MarrUI.Spacing.medium) { accountActions }
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) { accountActions }
                }
                if workspace.isRunning || workspace.isRemoteTaskActive {
                    Text("Wait for the active chat to finish before changing accounts.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
            }
            if !workspace.accountStatusMessage.isEmpty {
                Text(workspace.accountStatusMessage)
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CodexSettingsRequestStatus(workspace: workspace,
                methods: ["account/read", "account/login/start", "account/login/cancel", "account/logout"])
            Button { workspace.refreshAccount() } label: {
                Label("Refresh account", marrSymbol: "arrow.clockwise")
            }
            .disabled(isBusy)
        }
        .onAppear { workspace.refreshAccount() }
        .alert("Sign out of Codex?", isPresented: $confirmsSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { workspace.logoutAccount() }
        } message: {
            Text("Other clients using this Codex runtime will also use the updated sign-in state.")
        }
    }

    @ViewBuilder private var accountActions: some View {
        if workspace.account == nil {
            Button("Sign in with ChatGPT") { workspace.startAccountLogin() }
                .disabled(isBusy || workspace.isRunning || workspace.isRemoteTaskActive)
            Button("Use a device code") { workspace.startAccountLogin(deviceCode: true) }
                .disabled(isBusy || workspace.isRunning || workspace.isRemoteTaskActive)
        } else {
            Button("Sign out…", role: .destructive) { confirmsSignOut = true }
                .disabled(isBusy || workspace.isRunning || workspace.isRemoteTaskActive)
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Text(title).marrTextStyle(.secondary).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct CodexAccountUsageSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController

    var body: some View {
        CompactSettingsGroup("Account limits") {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
                HStack {
                    Text("Shared across your Codex clients")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        workspace.refreshRateLimits()
                        workspace.refreshAccountUsage()
                    } label: {
                        MarrIcon("arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh limits").accessibilityLabel("Refresh account limits")
                    .disabled(workspace.settingsLoadingMethods.contains("account/rateLimits/read")
                              || workspace.settingsLoadingMethods.contains("account/usage/read"))
                }
                ForEach(workspace.rateLimitBuckets) { bucket in
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
                        HStack {
                            Text(bucket.name).fontWeight(.medium)
                            Spacer()
                            if let plan = bucket.planType {
                                Text(plan.capitalized).foregroundStyle(.secondary)
                            }
                        }
                        if let primary = bucket.primary { limitWindow(primary, fallback: "Primary window") }
                        if let secondary = bucket.secondary { limitWindow(secondary, fallback: "Secondary window") }
                        if bucket.primary == nil, bucket.secondary == nil {
                            Text("No usage window is available.").foregroundStyle(.secondary)
                        }
                        if bucket.creditsUnlimited == true {
                            Text("Credits: unlimited").foregroundStyle(.secondary)
                        } else if let balance = bucket.creditsBalance {
                            Text("Credits: \(balance)").foregroundStyle(.secondary)
                        } else if bucket.hasCredits == false {
                            Text("No credits available").foregroundStyle(.secondary)
                        }
                    }
                    .marrTextStyle(.secondary)
                    .padding(12)
                    .marrSurface(.card)
                }
                if workspace.rateLimitBuckets.isEmpty,
                   !workspace.settingsLoadingMethods.contains("account/rateLimits/read"),
                   workspace.settingsErrors["account/rateLimits/read"] == nil {
                    Text("No account limits are available for this sign-in.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
                if workspace.ordinaryUsageAllowed == false {
                    Text("The account currently cannot use its ordinary allowance.")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                }
                if let usage = workspace.accountUsage {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        Text("Account activity").fontWeight(.medium)
                        usageMetric("Lifetime tokens", value: usage.lifetimeTokens?.formatted())
                        usageMetric("Peak daily tokens", value: usage.peakDailyTokens?.formatted())
                        usageMetric("Current streak", value: usage.currentStreakDays.map { "\($0) days" })
                        usageMetric("Longest streak", value: usage.longestStreakDays.map { "\($0) days" })
                        usageMetric("Longest turn", value: usage.longestRunningTurnSec.map {
                            Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                        })
                    }
                    .marrTextStyle(.secondary)
                }
                CodexSettingsRequestStatus(workspace: workspace, methods: ["account/rateLimits/read", "account/usage/read"])
            }
        }
        .onAppear {
            workspace.refreshRateLimits()
            workspace.refreshAccountUsage()
        }
    }

    private func usageMetric(_ title: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "Unavailable").monospacedDigit()
        }
    }

    private func limitWindow(_ window: CodexRateLimitWindow, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack {
                Text(windowTitle(window.windowDurationMins, fallback: fallback))
                Spacer()
                Text("\(window.remainingPercent, specifier: "%.0f")% remaining").monospacedDigit()
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .accessibilityLabel(windowTitle(window.windowDurationMins, fallback: fallback))
                .accessibilityValue("\(Int(window.remainingPercent)) percent remaining")
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .marrTextStyle(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func windowTitle(_ minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }
}
