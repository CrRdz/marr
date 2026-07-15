import AppKit
import MarrCore

struct PickedImage {
    let data: Data
    let mimeType: String
    let fileName: String
    let image: NSImage
}

extension ConversationImageAsset {
    init(id: UUID = UUID(), image: PickedImage) {
        self.init(
            id: id,
            data: image.data,
            mimeType: image.mimeType,
            fileName: image.fileName
        )
    }
}

