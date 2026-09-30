import Foundation
import Darwin

/// A windowless, independently signed launcher for the user-installed Codex
/// CLI. It intentionally has no App Sandbox entitlement: launching Codex from
/// the Marr UI would inherit the UI app's sandbox and lose access to the
/// user's existing Codex login.
enum MarrCodexServer {
    struct Configuration: Decodable {
        let codexPaths: [String]
        let listenURL: String
        let diagnosticPath: String
    }

    static func run() -> Never {
        let fallbackDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.marr.Marr/Data/tmp", isDirectory: true)
        let configurationURL: URL
        if let argumentIndex = CommandLine.arguments.firstIndex(of: "--configuration"),
           CommandLine.arguments.indices.contains(argumentIndex + 1) {
            configurationURL = URL(fileURLWithPath: CommandLine.arguments[argumentIndex + 1])
        } else {
            configurationURL = fallbackDirectory.appendingPathComponent("MarrCodexServer.json")
        }
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              !configuration.codexPaths.isEmpty else {
            writeDiagnostic("Could not read helper configuration at \(configurationURL.path).",
                            to: fallbackDirectory.appendingPathComponent("MarrCodexServer.log"))
            exit(EXIT_FAILURE)
        }
        let diagnosticURL = URL(fileURLWithPath: configuration.diagnosticPath)

        for executable in configuration.codexPaths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--listen", configuration.listenURL]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            // Drain stderr directly to disk; waiting before draining a pipe can
            // deadlock a long-running app-server once its pipe buffer fills.
            writeDiagnostic("Starting Codex from \(executable).", to: diagnosticURL)
            let errorLog = try? FileHandle(forWritingTo: diagnosticURL)
            try? errorLog?.seekToEnd()
            process.standardError = errorLog ?? FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                try? errorLog?.close()
                exit(process.terminationStatus)
            } catch {
                try? errorLog?.close()
                writeDiagnostic("Could not launch \(executable): \(error.localizedDescription)", to: diagnosticURL)
                continue
            }
        }

        exit(EXIT_FAILURE)
    }

    static func writeDiagnostic(_ text: String, to url: URL?) {
        guard let url else { return }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

MarrCodexServer.run()
