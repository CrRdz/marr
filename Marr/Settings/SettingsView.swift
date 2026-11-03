import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

enum MarrSettingsLayout {
    static let horizontalInset: CGFloat = MarrUI.Spacing.medium
    static let navigationWidth: CGFloat = 44
    static let columnSpacing: CGFloat = MarrUI.Spacing.medium
    static let contentPadding: CGFloat = MarrUI.Spacing.large
    static let contentCornerRadius: CGFloat = MarrUI.Radius.panel
    static let sectionSpacing: CGFloat = MarrUI.Spacing.section
}

@MainActor
final class MarrSettingsNavigation: ObservableObject {
    @Published var selection: MarrSettingsSection = .general
    @Published var query = ""
    @Published var capabilitySection: CodexCapabilitySection = .skills

    func open(_ section: MarrSettingsSection) {
        query = ""
        selection = section.navigationSection
    }

    func openCapabilities(_ section: CodexCapabilitySection) {
        capabilitySection = section
        open(.work)
    }

    func open(_ result: MarrSettingsSearchResult) {
        if let capabilitySection = result.capabilitySection {
            openCapabilities(capabilitySection)
        } else {
            open(result.section)
        }
    }

    /// Returns false only when the parent should leave Settings.
    @discardableResult
    func back() -> Bool {
        if !query.isEmpty { query = ""; return true }
        return false
    }
}

enum MarrSettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, conversation, translation, account, work, configuration, archives, storage, advanced, usage
    static let visibleSections: [Self] = [.general, .conversation, .translation, .work, .usage, .archives, .storage, .advanced]
    var navigationSection: Self {
        switch self {
        case .appearance: .general
        case .account: .conversation
        case .usage: .usage
        case .configuration: .advanced
        default: self
        }
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .conversation: "AI & Models"
        case .translation: "Translation"
        case .account: "Account"
        case .configuration: "Configuration"
        case .archives: "Archived chats"
        case .storage: "Storage"
        case .work: "Work & Integrations"
        case .advanced: "Advanced"
        case .usage: "Usage"
        }
    }
    var tabTitle: String {
        switch self {
        case .general: "General"
        case .appearance: "Style"
        case .conversation: "AI & Models"
        case .translation: "Translate"
        case .account: "Account"
        case .configuration: "Config"
        case .archives: "Archives"
        case .storage: "Storage"
        case .work: "Work & Integrations"
        case .advanced: "Runtime"
        case .usage: "Usage"
        }
    }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .conversation: "bubble.left"
        case .translation: Self.translationSymbol
        case .account: "person.crop.circle"
        case .configuration: "slider.horizontal.3"
        case .archives: "archivebox"
        case .storage: "square.stack"
        case .work: "square.stack.3d.up"
        case .advanced: "slider.horizontal.3"
        case .usage: "chart.bar"
        }
    }
    private static let translationSymbol = "translate"
    var summary: String {
        switch self {
        case .general: "Dock icon, capture shortcuts, and appearance."
        case .appearance: "Theme, glass surfaces, and colors."
        case .conversation: "Connect an AI provider and choose your model."
        case .translation: "Choose the service behind your translations."
        case .account: "Manage your AI accounts and connections."
        case .configuration: "Preferences and policies from your Codex runtime."
        case .archives: "Find and restore your archived local chats."
        case .storage: "Manage chats, attachments and workspaces stored on this Mac."
        case .work: "Local workspaces and optional Codex compatibility."
        case .advanced: "Manage optional runtime integrations."
        case .usage: "Codex account limits and activity on this Mac."
        }
    }
    var color: Color {
        switch self {
        case .general: .blue
        case .appearance: .purple
        case .conversation: .teal
        case .translation: .orange
        case .account: .blue
        case .configuration: .secondary
        case .archives: .secondary
        case .storage: .orange
        case .work: .indigo
        case .advanced: .secondary
        case .usage: .green
        }
    }
}

struct MarrSettingsSearchResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let section: MarrSettingsSection
    let keywords: String
    var capabilitySection: CodexCapabilitySection? = nil

    static let all: [Self] = [
        .init(id: "dock-icon", title: "Show Dock icon", detail: "Keep Marr in the Dock or use the menu bar and shortcuts", section: .general, keywords: "dock icon show hide menu bar application 程序坞 图标 显示 隐藏 菜单栏"),
        .init(id: "shortcuts", title: "Screenshot shortcuts", detail: "Capture an area or a window", section: .general, keywords: "keyboard hotkey shortcut window area capture 快捷键 截图 窗口 区域"),
        .init(id: "availability", title: "Shortcut availability", detail: "All apps or one selected app", section: .general, keywords: "scope global disabled application frontmost 范围 应用 禁用"),
        .init(id: "theme", title: "Theme", detail: "System, Light or Dark", section: .appearance, keywords: "color mode theme light dark 主题 外观 深色 浅色"),
        .init(id: "glass", title: "Liquid Glass", detail: "Native glass surfaces", section: .appearance, keywords: "transparency material liquid glass 玻璃 透明"),
        .init(id: "colors", title: "Accent & bubble colors", detail: "Personalize controls and your messages", section: .appearance, keywords: "accent bubble colour color 气泡 颜色 强调色"),
        .init(id: "conversation-model", title: "Conversation model, reasoning & speed", detail: "Choose the AI connection used by Marr", section: .conversation, keywords: "provider anthropic claude google gemini deepseek openrouter moonshot kimi xai grok ollama API 服务商 intelligence reasoning effort strength default model speed fast standard lightning 对话 模型 推理 强度 速度 快速 闪电"),
        .init(id: "account", title: "AI connections", detail: "ChatGPT accounts, API services and local models", section: .account, keywords: "login account authentication sign in logout email plan 登录 账户 邮箱 套餐 退出"),
        .init(id: "configuration", title: "Codex preferences", detail: "Web search, response detail and analytics", section: .configuration, keywords: "config configuration web search reasoning summary verbosity analytics 配置 搜索 回复 摘要 分析"),
        .init(id: "policies", title: "Runtime policies", detail: "Effective sandbox, approvals and managed requirements", section: .configuration, keywords: "permissions sandbox approval policy managed requirements 权限 沙箱 审批 策略 管理"),
        .init(id: "features", title: "Runtime features", detail: "Available features and their enabled state", section: .configuration, keywords: "experimental feature flags beta 实验 功能 开关"),
        .init(id: "archives", title: "Archived chats", detail: "Search and restore archived local chats", section: .archives, keywords: "archived archive history restore unarchive chats 归档 历史 恢复 聊天"),
        .init(id: "storage", title: "Storage on this Mac", detail: "Chat data, attachments, archives and workspace storage", section: .storage, keywords: "storage disk bytes database sqlite files local space 存储 空间 占用 本地 数据 文件 清理"),
        .init(id: "local-workspaces", title: "Local workspaces", detail: "Manage workspace names and folders", section: .storage, keywords: "workspace project folder local 工作区 项目 文件夹 本地"),
        .init(id: "agent-hosting", title: "Personal Agent hosting", detail: "Connect your own always-on server", section: .work, keywords: "agent cloud server hosting token 云端 常驻 服务器 个人 智能体"),
        .init(id: "codex-sync", title: "Sync Codex work", detail: "Optional Codex history and runtime integration", section: .work, keywords: "sync codex compatibility integration history 同步 兼容 开关 历史"),
        .init(id: "limits", title: "Codex account usage limits", detail: "Remaining allowance, credits and reset times", section: .work, keywords: "account limits rate billing usage credits reset 额度 余额 用量 重置 计费"),
        .init(id: "translation-model", title: "Translation model & reasoning", detail: "Reuse a saved AI connection or follow the conversation", section: .translation, keywords: "model codex reasoning effort strength 翻译 模型 推理 强度"),
        .init(id: "translation-api", title: "Translation connection", detail: "Choose an existing AI connection or DeepLX", section: .translation, keywords: "provider server URL gateway protocol responses chat completions messages deeplx 独立 接口 服务 地址"),
        .init(id: "translation-credentials", title: "Translation credentials", detail: "API keys, access tokens and request headers", section: .conversation, keywords: "api key token bearer authentication headers 凭据 密钥 令牌 请求头"),
        .init(id: "translation-test", title: "Test translation", detail: "Check your saved API connection", section: .translation, keywords: "connection test network sample 测试 网络 连接"),
        .init(id: "work-skills", title: "Skills", detail: "Browse skills and manage which are enabled", section: .work, keywords: "skill enable disable invocation 技能 启用 禁用 调用", capabilitySection: .skills),
        .init(id: "work-plugins", title: "Plugins", detail: "Installed and available runtime plugins", section: .work, keywords: "plugin install uninstall marketplace 插件 安装 卸载 市场", capabilitySection: .plugins),
        .init(id: "work-apps", title: "Apps", detail: "Apps available to your Codex account", section: .work, keywords: "app connector connection 应用 连接器", capabilitySection: .apps),
        .init(id: "work-mcp", title: "MCP servers", detail: "Connect accounts and reload tools", section: .work, keywords: "MCP tool server oauth login 工具 服务 登录", capabilitySection: .mcp),
        .init(id: "runtime", title: "Codex runtime", detail: "Desktop or a custom CLI", section: .advanced, keywords: "CLI path executable runtime desktop advanced 运行 环境 路径 高级"),
        .init(id: "server", title: "Local app-server", detail: "Background service and connection address", section: .advanced, keywords: "app-server websocket server connection local background service 本地 服务 后台 连接"),
        .init(id: "usage", title: "Token activity", detail: "Local token totals and daily activity", section: .usage, keywords: "tokens history activity streak statistics 用量 统计 活动 历史")
    ]

    static func search(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return all.filter { result in
            let text = "\(result.title) \(result.detail) \(result.section.title) \(result.section.tabTitle) \(result.keywords)"
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

struct AnswerPanelSettingsView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject var navigation: MarrSettingsNavigation
    @ObservedObject private var workspace: RuntimeWorkspaceController
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredCategory: MarrSettingsSection?
    @State private var showsCategoryTitles = false

    init(controller: MarrController, navigation: MarrSettingsNavigation) {
        self.controller = controller
        self.navigation = navigation
        self.workspace = controller.codexWorkspace
    }

    var body: some View {
        HStack(alignment: .top, spacing: MarrSettingsLayout.columnSpacing) {
            categoryMenu
            VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
                pageHeading
                    .fixedSize(horizontal: false, vertical: true)
                CompactSettingsDivider()
                ZStack(alignment: .topLeading) {
                    // Keep the current page alive while search temporarily covers it.
                    ScrollView {
                        VStack(alignment: .leading, spacing: MarrSettingsLayout.sectionSpacing) {
                            selectedPanel(navigation.selection)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.automatic)
                    .id(navigation.selection)
                    .opacity(isSearching ? 0 : 1)
                    .allowsHitTesting(!isSearching)
                    .disabled(isSearching)
                    .accessibilityHidden(isSearching)

                    if isSearching {
                        ScrollView {
                            searchResults
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 22)
                        }
                        .scrollIndicators(.automatic)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MarrSettingsLayout.contentPadding)
            .marrSurface(.content, cornerRadius: MarrSettingsLayout.contentCornerRadius)
            .clipShape(RoundedRectangle(cornerRadius: MarrSettingsLayout.contentCornerRadius, style: .continuous))
        }
        .padding(.horizontal, MarrSettingsLayout.horizontalInset)
        .padding(.bottom, 12)
        .marrTextStyle(.body)
        .tint(settingsTint)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 640 } action: { showsCategoryTitles = $0 }
    }

    private var isSearching: Bool {
        !navigation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Text(isSearching ? "Search results" : navigation.selection.title)
                .marrTextStyle(.pageTitle)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var categoryMenu: some View {
        ScrollView {
          VStack(spacing: MarrUI.Spacing.regular) {
            ForEach(MarrSettingsSection.visibleSections) { section in
                if section == .advanced {
                    Divider()
                        .overlay(.primary.opacity(contrast == .increased ? 0.2 : 0))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                Button { navigation.open(section) } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        MarrIcon(section.systemImage, size: MarrUI.Icon.toolbar)
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 28, height: 36)
                        if showsCategoryTitles {
                            Text(section.title).marrTextStyle(.body).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                        .frame(width: showsCategoryTitles ? 168 : 36, height: 36)
                        .background {
                            RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                                .fill(.primary.opacity(navigation.selection == section ? 0.09 : hoveredCategory == section ? 0.045 : 0))
                                .overlay {
                                    RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                                        .strokeBorder(.primary.opacity(contrast == .increased && navigation.selection == section ? 0.5 : 0), lineWidth: 0.75)
                                }
                        }
                        .frame(width: showsCategoryTitles ? 176 : 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredCategory = $0 ? section : nil }
                .help(section.title)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
            }
          }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
        .frame(width: showsCategoryTitles ? 176 : MarrSettingsLayout.navigationWidth)
        .frame(maxHeight: .infinity)
        .animation(reducesMotion ? nil : .easeInOut(duration: 0.15), value: navigation.selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }


    @ViewBuilder
    private func selectedPanel(_ section: MarrSettingsSection) -> some View {
        switch section {
        case .general, .appearance:
            CompactGeneralSettingsPanel(controller: controller)
            CompactAppearanceSettingsPanel()
        case .conversation: CompactProviderSettingsPanel(controller: controller, page: .conversation, openAccount: { navigation.open(.conversation) })
        case .translation: CompactProviderSettingsPanel(controller: controller, page: .translation, openAccount: { navigation.open(.conversation) })
        case .account:
            CompactProviderSettingsPanel(controller: controller, page: .conversation, openAccount: { navigation.open(.conversation) })
        case .usage:
            CompactUsageSettingsPanel(usageStore: controller.tokenUsageStore, historyStore: controller.historyStore)
        case .archives:
            MarrLocalChatStorageView(controller: controller, archivedOnly: true)
            if workspace.codexSyncEnabled {
                DisclosureGroup("Archived Codex chats") {
                    CodexArchiveSettings(workspace: workspace).padding(.top, 12)
                }
            }
        case .storage:
            MarrStorageSettingsView(controller: controller)
        case .work:
            PersonalAgentCloudSettings(coordinator: controller.personalAgent)
            CompactSettingsGroup("Local workspaces", info: "Chats stay on this Mac and use the connection selected in AI & Models.") {
                HStack {
                    Button("AI connection") { navigation.open(.conversation) }
                    Button("Manage storage") { navigation.open(.storage) }
                    Spacer(minLength: 0)
                }.padding(.top, 10)
            }
            MarrCodexSyncSettings(workspace: workspace)
            if workspace.codexSyncEnabled {
                CodexAccountSettings(workspace: workspace)
                CodexAccountUsageSettings(workspace: workspace)
                CodexCapabilitiesView(workspace: workspace, section: $navigation.capabilitySection, embedded: true)
            }
        case .advanced, .configuration:
            MarrCodexSyncSettings(workspace: workspace)
            if workspace.codexSyncEnabled {
                CodexWorkspaceSettingsPanel(workspace: workspace)
                CodexRuntimeConfigurationSettings(workspace: workspace)
            }
        }
    }

    private var searchResults: some View {
        let results = MarrSettingsSearchResult.search(navigation.query)
        return VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
            Text(results.isEmpty ? "No matching settings" : "\(results.count) matching settings")
                .marrTextStyle(.title, weight: .semibold)
                .padding(.top, 8)
            if results.isEmpty {
                Text("Try “model”, “shortcut” or “appearance”.")
                    .foregroundStyle(.secondary)
                    .marrTextStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(results) { result in
                    Button { navigation.open(result) } label: {
                        HStack(spacing: MarrUI.Spacing.medium) {
                            MarrIcon(result.section.navigationSection.systemImage, size: MarrUI.Icon.navigation)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                                Text(result.title).marrTextStyle(.body, weight: .medium)
                                Text("\(result.section.navigationSection.title) · \(result.detail)")
                                    .marrTextStyle(.secondary)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MarrIcon("chevron.right", size: MarrUI.Icon.disclosure).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if result.id != results.last?.id { CompactSettingsDivider() }
                }
            }
        }
    }

    private var settingsTint: Color {
        let selected = MarrAccentColor.resolve(accentColor)
        return selected == .system ? Color.accentColor : selected.color
    }
}

struct MarrSettingsSearchField: View {
    @ObservedObject var navigation: MarrSettingsNavigation
    @FocusState private var searchFocused: Bool
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue
    private var settingsTint: Color { MarrAccentColor.resolve(accentColor).color }
    var body: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon("magnifyingglass", size: MarrUI.Icon.status)
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $navigation.query)
                .textFieldStyle(.plain)
                .marrTextStyle(.secondary)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
            if !navigation.query.isEmpty {
                Button { navigation.query = "" } label: {
                    MarrIcon("xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .marrSurface(.input, cornerRadius: MarrUI.Radius.control,
                     border: searchFocused ? .focus : .subtle, tint: settingsTint)
    }

}
