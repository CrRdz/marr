import AppKit
import Foundation

final class NativeScreenshotController {
    private var process: Process?
    private var temporaryURL: URL?

    func capture(completion: @escaping (Result<PickedImage, Error>) -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenLens-\(UUID().uuidString)")
            .appendingPathExtension("png")
        temporaryURL = url

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { [weak self] process in
            guard let self else {
                return
            }

            let result = self.result(from: process, fileURL: url)
            self.cleanup()
            completion(result)
        }

        self.process = process

        do {
            NSApp.hide(nil)
            try process.run()
        } catch {
            cleanup()
            completion(.failure(error))
        }
    }

    func cancel() {
        process?.terminate()
        cleanup()
    }

    private func result(from process: Process, fileURL: URL) -> Result<PickedImage, Error> {
        guard process.terminationStatus == 0 else {
            return .failure(UserFacingError("Capture cancelled."))
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let image = NSImage(data: data) else {
                return .failure(UserFacingError("Could not read the captured image."))
            }

            return .success(
                PickedImage(
                    data: data,
                    mimeType: "image/png",
                    fileName: "Screen Capture",
                    image: image
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func cleanup() {
        process = nil

        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        temporaryURL = nil
    }
}
