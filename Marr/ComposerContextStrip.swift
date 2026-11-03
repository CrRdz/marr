import AppKit
import SwiftUI
import MarrCore

struct ComposerContextStrip: View {
    let attachments: [ConversationImageAsset]
    var bindings: [ComposerMentionBinding] = []
    let onRemoveAttachment: (UUID) -> Void
    var onRemoveBinding: (ComposerMentionBinding) -> Void = { _ in }
    @State private var preview: ConversationImageAsset?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        Button { preview = attachment } label: {
                            HStack(spacing: 5) {
                                ComposerAttachmentThumbnail(attachment: attachment)
                                Text(attachment.fileName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Inspect \(attachment.fileName)")
                        .accessibilityLabel("Inspect \(attachment.fileName)")
                        Button { onRemoveAttachment(attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(attachment.fileName)")
                    }
                    .contextChip()
                    .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                }
                ForEach(bindings) { binding in
                    HStack(spacing: 5) {
                        Label(binding.name, systemImage: binding.kind == .skill ? "sparkle" : binding.kind == .file ? "doc.text" : "puzzlepiece.extension")
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 175)
                            .help(binding.path)
                        Button { onRemoveBinding(binding) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove context \(binding.name)")
                    }
                    .contextChip()
                    .accessibilityElement(children: .contain)
                    .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // A horizontal ScrollView otherwise accepts the footer's spare height
        // and can crowd the transcript when an attachment is added.
        .frame(height: 42)
        .animation(MarrMotion.attachment(reducesMotion: reducesMotion), value: attachments.map(\.id))
        .animation(MarrMotion.attachment(reducesMotion: reducesMotion), value: bindings.map(\.id))
        .popover(item: $preview) { ComposerAttachmentPreview(attachment: $0) }
    }
}

/// A local, read-only preview; document scripts and executables are never run.
struct ComposerAttachmentPreview: View {
    let attachment: ConversationImageAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(attachment.fileName).font(MarrTypography.font(.body, weight: .semibold))
                .textSelection(.enabled)
            Text("\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))")
                .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
            if attachment.isImage, let image = NSImage(data: attachment.data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 300)
            } else if let text = String(data: attachment.data.prefix(32_768), encoding: .utf8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(text).font(MarrTypography.font(.code)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 340, height: 220)
                if attachment.data.count > 32_768 {
                    Text("Preview shows the first 32 KB. The complete file is retained.")
                        .font(MarrTypography.font(.caption)).foregroundStyle(.secondary)
                }
            } else {
                Label("The complete file is retained.", systemImage: "doc")
                    .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 220, maxWidth: 392)
    }
}

private struct ComposerAttachmentThumbnail: View {
    let attachment: ConversationImageAsset
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 26, height: 26).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: attachment.isImage ? "photo" : AttachmentFileSupport.symbolName(for: attachment.fileName))
                    .frame(width: 26, height: 26)
            }
        }
        .accessibilityHidden(true)
        .task(id: attachment.id) {
            if attachment.isImage { image = NSImage(data: attachment.data) }
        }
    }
}

private extension View {
    func contextChip() -> some View {
        font(MarrTypography.font(.secondary))
            .frame(height: 26)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}
