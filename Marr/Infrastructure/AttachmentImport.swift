import AppKit
import MarrCore

struct AttachmentImportResult {
    var attachments: [ConversationImageAsset] = []
    var errors: [String] = []
}

enum AttachmentFilePicker {
    static func present(completion: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Add Attachments"
        panel.message = "Choose images, PDFs, documents, spreadsheets, presentations, text, or code files."
        panel.prompt = "Attach"
        panel.allowedContentTypes = AttachmentFileSupport.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let urls = response == .OK ? panel.urls : nil
            DispatchQueue.main.async { completion(urls) }
        }
        let parent = (NSApp.keyWindow as? AnswerPanelWindow)
            ?? NSApp.orderedWindows.first { $0 is AnswerPanelWindow && $0.isVisible }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

/// Both the file picker and external drops use the same validation and limits.
enum AttachmentFileImporter {
    static func append(_ urls: [URL], to existing: [ConversationImageAsset]) -> AttachmentImportResult {
        var result = AttachmentImportResult(attachments: existing)
        var attachedBytes = existing.reduce(0) { $0 + $1.data.count }
        for url in urls {
            guard result.attachments.count < AttachmentFileSupport.maximumAttachmentCount else {
                result.errors.append("You can attach up to \(AttachmentFileSupport.maximumAttachmentCount) files to one question.")
                break
            }
            do {
                guard url.isFileURL else { throw PickedAttachmentError.couldNotRead(url.lastPathComponent) }
                let attachment = try PickedAttachment.attachment(from: url)
                guard attachedBytes + attachment.data.count < AttachmentFileSupport.maximumRequestBytes else {
                    result.errors.append("\"\(attachment.fileName)\" would make the combined attachments exceed 50 MB.")
                    continue
                }
                result.attachments.append(ConversationImageAsset(attachment: attachment))
                attachedBytes += attachment.data.count
            } catch {
                result.errors.append(error.localizedDescription)
            }
        }
        return result
    }
}

enum AttachmentDropLoader {
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
