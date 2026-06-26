import AppKit
import UniformTypeIdentifiers

struct PickedImage {
    let data: Data
    let mimeType: String
    let fileName: String
    let image: NSImage
}

enum ImagePicker {
    static func pickImage() -> PickedImage? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.title = "Choose an image"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data) else {
                return nil
            }

            return PickedImage(
                data: data,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent,
                image: image
            )
        } catch {
            return nil
        }
    }

    private static func mimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()

        if pathExtension == "png" {
            return "image/png"
        }

        return "image/jpeg"
    }
}
