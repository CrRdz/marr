import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CodexArchiveSettings: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @State private var query = ""

    private var tasks: [SavedTask] {
        workspace.workbench.tasks.filter {
            workspace.workbench.isTaskArchived($0.id)
                && (query.isEmpty || $0.title.localizedStandardContains(query)
                    || projectName($0).localizedStandardContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
            TextField("Search archived chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search archived chats")
            HStack {
                Text("\(tasks.count) chats")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { workspace.loadArchivedTaskHistory() } label: {
                    Label("Refresh", marrSymbol: "arrow.clockwise")
                }
                .disabled(workspace.isLoadingTaskHistory || workspace.isRunning)
            }
            .marrTextStyle(.secondary)
            if workspace.isLoadingTaskHistory {
                ProgressView("Loading archived chats…").controlSize(.small)
            }
            if let error = workspace.capabilityErrors["thread/unarchive"] ?? workspace.capabilityErrors["thread/archive"] ?? workspace.capabilityErrors["thread/list"] {
                Text(error).foregroundStyle(MarrUI.Status.error.color()).marrTextStyle(.secondary)
            }
            if tasks.isEmpty, !workspace.isLoadingTaskHistory {
                Text(query.isEmpty ? "No archived chats." : "No chats match your search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(tasks) { task in
                HStack(alignment: .top, spacing: MarrUI.Spacing.medium) {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                        Text(task.title).lineLimit(2)
                        Text(projectName(task)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Text(task.updatedAt, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    }
                    .marrTextStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { workspace.unarchiveTask(task) } label: {
                        ZStack {
                            if workspace.archivingTaskIDs.contains(task.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                MarrIcon("arrow.uturn.backward")
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Restore chat")
                    .accessibilityLabel("Restore \(task.title)")
                    .disabled(workspace.isRunning || workspace.isLoadingTaskHistory || workspace.archivingTaskIDs.contains(task.id))
                }
                CompactSettingsDivider()
            }
        }
        .onAppear { workspace.loadArchivedTaskHistory() }
    }

    private func projectName(_ task: SavedTask) -> String {
        workspace.workbench.workspaces.first { $0.id == task.workspaceID }?.name ?? "Codex"
    }
}

struct CodexWorkspaceSettingsPanel: View {
    @ObservedObject var workspace: RuntimeWorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: MarrSettingsLayout.sectionSpacing) {
            CompactSettingsGroup("Codex runtime") {
                CompactSettingsRow("Executable", systemImage: "terminal") {
                    Button("Choose CLI…") {
                        workspace.chooseCodexCLI()
                    }
                    .controlSize(.small)
                }

                Text(workspace.codexCLIDisplayName)
                    .marrTextStyle(.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                if workspace.codexCLIURL != nil {
                    Button("Reset to automatic") {
                        workspace.useAutomaticCodexCLIPath()
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if workspace.codexCLIURL != nil || workspace.usesExternalAppServer {
                    Button("Use Desktop Codex") { workspace.useDesktopRuntime() }
                        .disabled(workspace.isRunning)
                        .controlSize(.small)
                        .help(workspace.runtimeDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
            }

            CompactSettingsGroup("Local server", info: "Leave the address blank to use the built-in app-server.") {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    TextField(
                        "ws://127.0.0.1:4500",
                        text: Binding(
                            get: { workspace.appServerURLString },
                            set: { workspace.setAppServerURL($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .marrTextStyle(.code)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .marrSurface(.input, cornerRadius: MarrUI.Radius.control)
                    .accessibilityLabel("Local app-server address")

                    Button("Start Background Service") {
                        workspace.startAppServerInBackground()
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    if workspace.usesExternalAppServer {
                        Button("Use Built-in app-server") {
                            workspace.setAppServerURL("")
                        }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }
}
