import SwiftUI

/// The rail is outside the existing chat canvas; its width never comes out of
/// the transcript, composer, or history sidebar's assigned layout.
enum MarrPanelShellLayout {
    static let railWidth: CGFloat = 64
    static let toolbarTop: CGFloat = 12
    static let toolbarHeight: CGFloat = 30
    static let titleRowTop = toolbarTop + toolbarHeight + MarrUI.Spacing.regular
    static let windowSize = CGSize(width: AnswerPanelConversationLayout.panelSize.width + railWidth,
                                   height: AnswerPanelConversationLayout.panelSize.height)

    static func contentFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + railWidth, y: frame.minY,
               width: max(0, frame.width - railWidth), height: frame.height)
    }

    static func windowFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX - railWidth, y: frame.minY,
               width: frame.width + railWidth, height: frame.height)
    }

    static func contentMotion(_ motion: AnswerPanelSidebarWindowMotion?, railWidth: CGFloat = Self.railWidth) -> AnswerPanelSidebarWindowMotion? {
        motion.map { AnswerPanelSidebarWindowMotion(
            fromWidth: $0.fromWidth - railWidth, toWidth: $0.toWidth - railWidth,
            fromRevealWidth: $0.fromRevealWidth, toRevealWidth: $0.toRevealWidth)
        }
    }
}

enum MarrPanelSection: String, CaseIterable, Identifiable {
    case chats, personalAgent
    var id: Self { self }
    var title: String { self == .chats ? "Conversation / Work" : "Personal Agent" }
}

struct MarrAccountAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct MarrNavigationRail: View {
    @Binding var selection: MarrPanelSection
    var agentUnreadCount = 0
    var accountName = "Marr"
    var accountDetail = "Settings and accounts"
    var accountInitial: String?
    var onOpenSettings: () -> Void = {}
    var onOpenAccount: () -> Void = {}
    var onSelect: (MarrPanelSection) -> Void = { _ in }
    var showsAccountMenu = false
    var onToggleAccountMenu: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: MarrUI.Spacing.medium) {
            ForEach(MarrPanelSection.allCases) { section in
                Button { selection = section; onSelect(section) } label: {
                    Group {
                        if section == .personalAgent {
                            MarrAgentEmblem().frame(width: 30, height: 30)
                                .overlay(alignment: .topTrailing) {
                                    if agentUnreadCount > 0 {
                                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                                            .offset(x: 4, y: -3)
                                    }
                                }
                        } else {
                            Image("MarrStatusIcon")
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.card))
                }
                .buttonStyle(MarrRailButtonStyle(isSelected: selection == section))
                .help(section.title)
                .accessibilityLabel(section.title)
                .accessibilityValue(section == .personalAgent && agentUnreadCount > 0 ? "\(agentUnreadCount) unread updates" : "")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
                .accessibilityIdentifier("marr.navigation.\(section.rawValue)")
            }
            Spacer(minLength: 0)
            Button(action: onToggleAccountMenu) {
                MarrAccountAvatar(initial: accountInitial)
                    .frame(width: 44, height: 44)
                    .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.card))
            }
            .buttonStyle(MarrRailButtonStyle(isSelected: showsAccountMenu))
            .help("Account and settings")
            .accessibilityLabel("Account and settings")
            .accessibilityValue(showsAccountMenu ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("marr.navigation.account")
            .anchorPreference(key: MarrAccountAnchorKey.self, value: .bounds) { $0 }

        }
        .padding(.top, 64)
        .padding(.horizontal, 10)
        .padding(.bottom, MarrUI.Spacing.large)
        .frame(width: MarrPanelShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }
}

struct MarrAccountAvatar: View {
    var initial: String?
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.09))
            if let initial, !initial.isEmpty {
                Text(initial).font(.system(size: 14, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "person.fill").font(.system(size: 16, weight: .medium))
            }
        }
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct MarrAccountMenuEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let iconName: String?
    var section: MarrSettingsSection = .account
}

struct MarrAnchoredAccountMenu: View {
    let anchor: Anchor<CGRect>
    let entries: [MarrAccountMenuEntry]
    let onDismiss: () -> Void
    let onOpenEntry: (MarrAccountMenuEntry) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let avatar = geometry[anchor]
            ZStack(alignment: .bottomLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                MarrAccountMenuContent(entries: entries, onOpenEntry: onOpenEntry, onOpenSettings: onOpenSettings)
                    .frame(width: min(240, geometry.size.width - avatar.maxX - 18))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, avatar.maxX + 6)
                    .padding(.bottom, max(12, geometry.size.height - avatar.maxY))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
    }
}

struct MarrAccountMenuContent: View {
    let entries: [MarrAccountMenuEntry]
    let onOpenEntry: (MarrAccountMenuEntry) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(entries) { entry in
                        Button { onOpenEntry(entry) } label: {
                            HStack(spacing: 9) {
                                ProviderBrandIcon(name: entry.iconName, size: 24)
                                    .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).marrTextStyle(.body, weight: .medium).lineLimit(1)
                                    Text(entry.detail).marrTextStyle(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).frame(height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(MarrRailButtonStyle(isSelected: false))
                        .help("Manage " + entry.title)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: max(0, CGFloat(min(entries.count, 4)) * 46 - 2))
            Divider().padding(.horizontal, 6)
            Button(action: onOpenSettings) {
                HStack(spacing: 9) {
                    MarrIcon("gearshape", size: MarrUI.Icon.inline).frame(width: 30)
                    Text("Settings").marrTextStyle(.body)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(MarrRailButtonStyle(isSelected: false))
            .accessibilityIdentifier("marr.account.settings")
        }
        .padding(8)
        .background(MarrUI.Surface.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct MarrRailButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: MarrUI.Radius.card)
                    .fill(MarrPanelColors.primary(for: colorScheme)
                        .opacity(configuration.isPressed ? 0.14 : isSelected ? 0.08 : 0))
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: MarrUI.Radius.card)
                        .strokeBorder(MarrUI.Border.color(.standard, increasedContrast: contrast == .increased), lineWidth: 1)
                }
            }
    }
}

/// Vector counterpart of the soft glass mascot, clear even at sidebar size.
struct MarrAgentEmblem: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                MarrAgentPebble()
                    .fill(LinearGradient(colors: reduceTransparency ? [.blue, .blue] : [
                        Color(red: 0.48, green: 0.72, blue: 1),
                        Color(red: 0.24, green: 0.43, blue: 0.91),
                        Color(red: 0.57, green: 0.67, blue: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                MarrAgentPebble()
                    .strokeBorder(.white.opacity(contrast == .increased ? 0.9 : 0.55), lineWidth: size * 0.025)
                HStack(spacing: size * 0.10) {
                    Capsule().frame(width: size * 0.065, height: size * 0.16)
                    Capsule().frame(width: size * 0.065, height: size * 0.16)
                }
                .foregroundStyle(Color(white: 0.08))
                .offset(x: size * 0.035, y: size * 0.02)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MarrAgentPebble: InsettableShape {
    var insetAmount: CGFloat = 0
    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var path = Path()
        for step in 0..<120 {
            let angle = Double(step) / 120 * .pi * 2 - .pi / 2
            let radius = 0.43 + 0.065 * cos(5 * (angle + .pi / 2))
            let point = CGPoint(x: bounds.midX + cos(angle) * radius * bounds.width,
                                y: bounds.midY + sin(angle) * radius * bounds.height)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
