import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

struct PanelUtilityButtonLabel: View {
    let symbol: String

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MarrIcon(symbol, size: MarrUI.Icon.status)
            .foregroundStyle(isHovering ? MarrPanelColors.primary(for: colorScheme)
                             : MarrPanelColors.secondary(for: colorScheme))
            .frame(width: 26, height: 26)
            .background(
                Color.primary.opacity(isHovering ? 0.13 : 0.07),
                in: Circle()
            )
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 0.7)
                    .allowsHitTesting(false)
            )
            .contentShape(Circle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
    }
}
