import SwiftUI

/// Conversation and agent chats share the same reading column and composer chrome.
enum MarrChatLayout {
    static let horizontalInset: CGFloat = 32
    static let maximumWidth: CGFloat = 720
    static let inputPadding: CGFloat = 12
    static let landingInputPadding: CGFloat = 16
    static let landingMaximumWidth: CGFloat = 560
    static let workspaceFooterHeight: CGFloat = 48
    static func landingEditorHeight(in width: CGFloat) -> CGFloat {
        min(52, max(40, width * 0.09))
    }
    static let landingTitleSize: CGFloat = 28
    static func columnWidth(in width: CGFloat) -> CGFloat {
        min(maximumWidth, max(180, width - horizontalInset * 2))
    }
}

struct MarrChatComposerSurface: View {
    var isFocused: Bool
    var isLanding = false
    @AppStorage(MarrAccentColor.storageKey) private var accent = MarrAccentColor.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MarrUI.Radius.composer, style: .continuous)
        shape
            .fill(reducesTransparency ? MarrUI.Surface.raised
                  : scheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.52))
            .overlay {
                shape.stroke(isFocused
                    ? MarrAccentColor.resolve(accent).color.opacity(contrast == .increased ? 0.9 : 0.65)
                    : Color.primary.opacity(contrast == .increased ? 0.45 : 0.16),
                    lineWidth: isFocused ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isLanding ? 0.045 : 0), radius: 14, y: 5)
            .animation(MarrMotion.transition(reducesMotion: reducesMotion), value: isFocused)
            .allowsHitTesting(false)
    }
}

private struct MarrChatInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .font(MarrTypography.font(.answer))
            .lineLimit(1...4)
            .frame(minHeight: 30, alignment: .topLeading)
            .foregroundStyle(.primary)
    }
}

private struct MarrChatBubbleStyle: ViewModifier {
    @AppStorage(MarrBubbleColor.storageKey) private var bubble = MarrBubbleColor.system.rawValue
    func body(content: Content) -> some View {
        let color = MarrBubbleColor.resolve(bubble)
        content.marrTextStyle(.answer).textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(color.color.opacity(0.92), in: RoundedRectangle(cornerRadius: MarrUI.Radius.card, style: .continuous))
            .foregroundStyle(color.foregroundColor)
    }
}

private struct MarrChatSendStyle: ViewModifier {
    var isEnabled: Bool
    @AppStorage(MarrBubbleColor.storageKey) private var bubble = MarrBubbleColor.system.rawValue
    func body(content: Content) -> some View {
        let color = MarrBubbleColor.resolve(bubble)
        content.buttonStyle(MarrButtonStyle(.primary, size: .icon, shape: .circle,
                                           tint: color.color, foregroundColor: color.foregroundColor))
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}

struct MarrChatStopButton: View {
    var action: () -> Void
    @AppStorage(MarrAccentColor.storageKey) private var accent = MarrAccentColor.system.rawValue
    var body: some View {
        Button(action: action) {
            MarrIcon("stop.fill", size: MarrUI.Icon.status).frame(width: 28, height: 28)
        }
        .buttonStyle(MarrButtonStyle(.secondary, size: .icon, shape: .circle, tint: MarrAccentColor.resolve(accent).color))
        .accessibilityLabel("Stop response").help("Stop response")
        .transition(.opacity)
    }
}

extension View {
    func marrChatInput() -> some View { modifier(MarrChatInputStyle()) }
    func marrChatBubble() -> some View { modifier(MarrChatBubbleStyle()) }
    func marrChatSendButton(isEnabled: Bool) -> some View { modifier(MarrChatSendStyle(isEnabled: isEnabled)) }
}

/// A single, centered starting point shared by Conversation and Work.
/// The composer stays live here and moves back to the footer after the first turn.
struct MarrComposerLanding<Content: View>: View {
    var isWork = false
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    private var welcome: some View {
        Text(isWork ? "Let’s make it happen." : "What’s on your mind?")
            .font(.system(size: MarrChatLayout.landingTitleSize, weight: .regular, design: .serif))
            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    let headerLayout = geometry.size.width < 520
                        ? AnyLayout(VStackLayout(spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    headerLayout {
                        MarrCompanion(phase: .idle, size: 56, followsPointer: true)
                        welcome
                    }
                    .padding(.horizontal, MarrChatLayout.horizontalInset)
                    content()
                        // Reserve the project strip in both modes so the hero
                        // and editor keep the same vertical position.
                        .padding(.bottom, isWork ? 0 : MarrChatLayout.workspaceFooterHeight)
                }
                .padding(.top, 24)
                .padding(.bottom, 48)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }
}
