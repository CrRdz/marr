import SwiftUI

struct PersonalAgentCloudSettings: View {
    @ObservedObject var coordinator: PersonalAgentCoordinator
    @ObservedObject private var cloud: PersonalAgentCloud
    @State private var address = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showsDeployment = false

    init(coordinator: PersonalAgentCoordinator) {
        self.coordinator = coordinator
        cloud = coordinator.cloud
        _address = State(initialValue: coordinator.cloud.address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 5) {
                Text("Personal Agent · Hosting").marrTextStyle(.title, weight: .semibold)
                MarrSettingsInfo(title: "Agent hosting", message: "Your server can run agents while this Mac is offline. Each server has its own chats and agents; switching back to this Mac keeps server schedules running. Tokens are stored in Keychain.")
            }
            HStack {
                MarrIcon(cloud.enabled ? "globe" : "desktopcomputer", size: 16)
                Text(cloud.enabled ? (cloud.connected ? "Your server · Connected" : "Your server · Offline") : "This Mac")
                    .marrTextStyle(.secondary, weight: .medium)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Server address").marrTextStyle(.secondary)
                TextField("https://agents.example.com", text: $address).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Agent server address")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Access token").marrTextStyle(.secondary)
                SecureField(cloud.enabled ? "Leave blank to use the saved token" : "Your server access token", text: $token)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Agent server access token")
            }
            HStack {
                Button(cloud.enabled ? "Reconnect" : "Connect") {
                    busy = true; message = nil
                    Task {
                        defer { busy = false }
                        do { try await cloud.connect(address: address, token: token); token = ""; message = "Connected. Server agents are now available." }
                        catch { message = error.localizedDescription }
                    }
                }.buttonStyle(PersonalAgentButtonStyle(primary: true))
                if cloud.enabled {
                    Button("Use this Mac") { cloud.useLocal(); message = nil }
                        .buttonStyle(PersonalAgentButtonStyle())
                }
            }.disabled(busy || coordinator.activeRunID != nil || !cloud.pendingAgents.isEmpty)
            if let message = message ?? cloud.error { Text(message).marrTextStyle(.caption).textSelection(.enabled) }
            DisclosureGroup("Set up your server", isExpanded: $showsDeployment) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deploy the services/personal-agent Docker Compose package on your own Linux server. Configure a domain, access token and model; sign in to the runtime on that server. Then connect here.")
                    Text("Hosting and model usage are billed by your providers. Marr does not supply a hosted server.")
                }.marrTextStyle(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.marrTextStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
