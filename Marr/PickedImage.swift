import AppKit
import MarrCore
import UniformTypeIdentifiers

struct PickedImage {
    let data: Data
    let mimeType: String
    let fileName: String
    let image: NSImage

    static func attachment(from url: URL) throws -> PickedImage {
        let attachment = try PickedAttachment.attachment(from: url)
        guard let image = attachment.image else {
            throw PickedAttachmentError.unsupportedFormat(url.lastPathComponent)
        }
        return PickedImage(
            data: attachment.data,
            mimeType: attachment.mimeType,
            fileName: attachment.fileName,
            image: image
        )
    }
}

struct PickedAttachment {
    let data: Data
    let mimeType: String
    let fileName: String
    let image: NSImage?

    var isImage: Bool {
        image != nil
    }

    static func attachment(from url: URL) throws -> PickedAttachment {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = url.lastPathComponent
        let pathExtension = url.pathExtension.lowercased()
        let fileExtension = pathExtension.isEmpty ? fileName.lowercased() : pathExtension
        guard AttachmentFileSupport.supportedExtensions.contains(fileExtension) else {
            throw PickedAttachmentError.unsupportedFormat(fileName)
        }

        if let byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           byteCount >= AttachmentFileSupport.maximumFileBytes {
            throw PickedAttachmentError.fileTooLarge(fileName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PickedAttachmentError.couldNotRead(fileName)
        }
        guard data.count < AttachmentFileSupport.maximumFileBytes else {
            throw PickedAttachmentError.fileTooLarge(fileName)
        }

        let image: NSImage?
        if AttachmentFileSupport.imageExtensions.contains(fileExtension) {
            guard let decodedImage = NSImage(data: data), decodedImage.isValid else {
                throw PickedAttachmentError.invalidImage(fileName)
            }
            image = decodedImage
        } else {
            image = nil
        }

        return PickedAttachment(
            data: data,
            mimeType: AttachmentFileSupport.mimeType(
                forExtension: fileExtension,
                url: url
            ),
            fileName: fileName,
            image: image
        )
    }
}

enum AttachmentFileSupport {
    static let maximumAttachmentCount = 10
    static let maximumFileBytes = 49_000_000
    static let maximumRequestBytes = 49_000_000
    static let allowedContentTypes: [UTType] = [.item]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp"
    ]

    static let spreadsheetExtensions: Set<String> = [
        "xla", "xlb", "xlc", "xlm", "xls", "xlsx", "xlt", "xlw",
        "csv", "tsv", "iif"
    ]

    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "dot", "odt", "rtf", "pages"
    ]

    static let presentationExtensions: Set<String> = [
        "pot", "ppa", "pps", "ppt", "pptx", "pwz", "wiz", "keynote"
    ]

    static let textAndCodeExtensions: Set<String> = [
        "asm", "astro", "awk", "bash", "bat", "c", "cc", "clj", "cmake",
        "conf", "cpp", "cs", "css", "cxx", "dart", "def", "dic", "diff",
        "brewfile", "cl", "dockerfile", "ejs", "el", "eml", "erb", "erl",
        "ex", "exs", "gemfile", "graphql", "go", "gradle",
        "groovy", "h", "handlebars", "hcl", "hh", "hpp", "htm", "html",
        "hbs", "hs", "ics", "ifb", "in", "ini", "java", "jade", "jinja",
        "jinja2", "jl", "js", "json", "json5", "jsx", "kt", "kts", "ksh",
        "less", "lhs", "liquid", "lisp", "list", "log", "lsp", "lua", "m",
        "makefile", "markdown", "md", "mht", "mhtml", "mime", "mjs", "mm",
        "mustache",
        "ndjson", "nws", "patch", "php", "pl", "properties", "proto", "ps1",
        "podfile", "pug", "py", "r", "rakefile", "rb", "rs", "rst", "s",
        "sass", "scala", "scss", "sh", "sql", "srt", "swift", "tex", "text",
        "tf", "tmpl", "toml", "ts", "tsx", "twig", "txt", "vb", "vbs",
        "vcf", "vtt", "xml", "yaml", "yml", "zsh"
    ]

    static let supportedExtensions =
        imageExtensions
        .union(spreadsheetExtensions)
        .union(documentExtensions)
        .union(presentationExtensions)
        .union(textAndCodeExtensions)

    static func symbolName(for fileName: String) -> String {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if spreadsheetExtensions.contains(fileExtension) {
            return "tablecells"
        }
        if presentationExtensions.contains(fileExtension) {
            return "rectangle.on.rectangle"
        }
        if fileExtension == "pdf" {
            return "doc.richtext"
        }
        if textAndCodeExtensions.contains(fileExtension) {
            return "doc.text"
        }
        return "doc"
    }

    static func mimeType(forExtension fileExtension: String, url: URL) -> String {
        switch fileExtension {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "tsv": return "text/tsv"
        case "iif": return "application/x-iif"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xla", "xlb", "xlc", "xlm", "xls", "xlt", "xlw":
            return "application/vnd.ms-excel"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc", "dot": return "application/msword"
        case "odt": return "application/vnd.oasis.opendocument.text"
        case "rtf": return "application/rtf"
        case "pages": return "application/vnd.apple.pages"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "pot", "ppa", "pps", "ppt", "pwz", "wiz":
            return "application/vnd.ms-powerpoint"
        case "keynote": return "application/vnd.apple.keynote"
        case "json": return "application/json"
        case "json5": return "application/json5"
        case "ndjson": return "application/x-ndjson"
        case "html", "htm": return "text/html"
        case "xml": return "text/xml"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "ts": return "text/x-typescript"
        case "tsx": return "text/tsx"
        case "yaml", "yml": return "application/yaml"
        case "toml": return "application/toml"
        case "eml", "mht", "mhtml", "mime": return "message/rfc822"
        case "ics", "ifb": return "text/calendar"
        case "vcf": return "text/vcard"
        case "md", "markdown": return "text/markdown"
        case "tex": return "text/x-tex"
        case "srt": return "application/x-subrip"
        case "vtt": return "text/vtt"
        default:
            let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            return resourceType?.preferredMIMEType ?? "text/plain"
        }
    }
}

enum PickedAttachmentError: LocalizedError {
    case unsupportedFormat(String)
    case fileTooLarge(String)
    case couldNotRead(String)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileName):
            "\"\(fileName)\" is not a supported attachment format."
        case .fileTooLarge(let fileName):
            "\"\(fileName)\" must be smaller than 50 MB."
        case .couldNotRead(let fileName):
            "\"\(fileName)\" could not be read."
        case .invalidImage(let fileName):
            "\"\(fileName)\" does not contain a valid image."
        }
    }
}

typealias PickedImageAttachmentError = PickedAttachmentError

extension ConversationImageAsset {
    init(id: UUID = UUID(), image: PickedImage) {
        self.init(
            id: id,
            data: image.data,
            mimeType: image.mimeType,
            fileName: image.fileName
        )
    }

    init(id: UUID = UUID(), attachment: PickedAttachment) {
        self.init(
            id: id,
            data: attachment.data,
            mimeType: attachment.mimeType,
            fileName: attachment.fileName
        )
    }
}
