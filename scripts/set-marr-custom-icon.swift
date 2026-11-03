#!/usr/bin/env swift
// Local customization of an installed copy, never an Xcode build product.
// Usage: swift scripts/set-marr-custom-icon.swift /Applications/Marr.app
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: swift scripts/set-marr-custom-icon.swift /Applications/Marr.app")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let installDirectories = [
    URL(fileURLWithPath: "/Applications"),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
].map { $0.resolvingSymlinksInPath().path }
guard installDirectories.contains(app.deletingLastPathComponent().path) else {
    fail("Refusing to modify a build product. Custom Finder metadata breaks subsequent CodeSign steps. Use a separate installed Marr.app in /Applications or ~/Applications.")
}
guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "com.marr.Marr" else {
    fail("Expected a built Marr.app with bundle identifier com.marr.Marr")
}
let script = URL(fileURLWithPath: #filePath)
let root = script.deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("Marr/Assets.xcassets/AppIcon.appiconset/Marr-Dock-512@2x.png")
guard let image = NSImage(contentsOf: artwork) else {
    fail("Missing packaged circular icon; run scripts/package-marr-app-icon.swift first")
}

// Finder custom-icon metadata belongs to this installed copy, not to the
// running process. It survives normal exit and force quit. Never do this from
// the app itself or a build phase. This is an opt-in local customization after
// installation; it must not modify a product that Xcode will sign again.
guard NSWorkspace.shared.setIcon(image, forFile: app.path, options: []) else {
    fail("macOS could not set the custom icon on \(app.path)")
}
print("Set persistent Finder/Dock icon: \(app.path)")
