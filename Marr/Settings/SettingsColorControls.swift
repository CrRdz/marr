import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

private struct BubbleColorDropdown: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var selectedOption: MarrBubbleColor {
        MarrBubbleColor.resolve(selection)
    }

    var body: some View {
        ColorDropdownButton(
            title: selectedOption.title,
            color: selectedOption.dotColor,
            isPresented: $isPresented
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                ForEach(MarrBubbleColor.allCases) { option in
                    Button {
                        selection = option.rawValue
                        isPresented = false
                    } label: {
                        ColorMenuOptionLabel(
                            title: option.title,
                            color: option.dotColor,
                            isSelected: selection == option.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 156)
        }
    }
}

private struct AccentColorDropdown: View {
    @Binding var selection: String
    @State private var isPresented = false

    private var selectedOption: MarrAccentColor {
        MarrAccentColor.resolve(selection)
    }

    var body: some View {
        ColorDropdownButton(
            title: selectedOption.title,
            color: selectedOption.dotColor,
            isPresented: $isPresented
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                ForEach(MarrAccentColor.allCases) { option in
                    Button {
                        selection = option.rawValue
                        isPresented = false
                    } label: {
                        ColorMenuOptionLabel(
                            title: option.title,
                            color: option.dotColor,
                            isSelected: selection == option.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 156)
        }
    }
}

private struct ColorDropdownButton: View {
    let title: String
    let color: Color
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: MarrUI.Spacing.regular) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 6)
                MarrIcon("chevron.down", size: MarrUI.Icon.disclosure)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ColorMenuOptionLabel: View {
    let title: String
    let color: Color
    let isSelected: Bool
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    var body: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            if isSelected {
                MarrIcon("checkmark", size: MarrUI.Icon.status)
                    .frame(width: 14)
            } else {
                Color.clear
                    .frame(width: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .marrTextStyle(.body, weight: isSelected ? .semibold : .regular)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .foregroundStyle(isSelected ? selectedAccent.foregroundColor : .primary)
        .background(
            RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                .fill(isSelected ? selectedAccentColor : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous))
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}
