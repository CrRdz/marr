import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

struct UserMessageContent: View {
    let presentation: UserMessagePresentation

    init(source: String) { presentation = UserMessagePresentation(source) }
    init(presentation: UserMessagePresentation) { self.presentation = presentation }
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let isLong = presentation.body.count > 700 || presentation.body.components(separatedBy: .newlines).count > 12
        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            ForEach(presentation.attachments.filter(\.isImage)) { attachment in
                MarrUserAttachmentView(artifact: attachment).id(attachment.source)
            }
            if isLong && !expanded {
                Text(verbatim: presentation.body)
                    .lineLimit(8)
                    .textSelection(.enabled)
            } else if !presentation.body.isEmpty {
                MarkdownResponseView(source: presentation.body, compact: true, proseRole: .answer)
            }
            ForEach(presentation.references, id: \.self) { reference in
                Text(verbatim: reference)
                    .marrTextStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: MarrUI.Radius.chip))
            }
            ForEach(presentation.attachments.filter { !$0.isImage }) { attachment in
                MarrUserAttachmentView(artifact: attachment).id(attachment.source)
            }
            if let details = presentation.additionalDetails {
                DisclosureGroup("Message details") {
                    Text(verbatim: details).font(MarrTypography.font(.code)).textSelection(.enabled)
                }
                .marrTextStyle(.secondary)
            }
            if isLong {
                Button(expanded ? "Show less" : "Show full message") {
                    withAnimation(MarrMotion.disclosure(reducesMotion: reducesMotion)) { expanded.toggle() }
                }
                .font(MarrTypography.font(.caption, weight: .medium))
                .buttonStyle(.borderless)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .frame(maxWidth: presentation.attachments.contains(where: \.isImage) ? MarrUserImagePreview.maximumWidth : nil,
               alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
