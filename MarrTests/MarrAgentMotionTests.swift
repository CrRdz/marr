import AppKit
import SwiftUI
import XCTest
@testable import Marr

@MainActor
final class MarrAgentMotionTests: XCTestCase {
    func testAmbientAnimationOnlyRunsForActiveWorkWithAccessibleMotionPreferences() {
        for reducesMotion in [false, true] {
            for reducesTransparency in [false, true] {
                for increasedContrast in [false, true] {
                    for isVisible in [false, true] {
                        XCTAssertEqual(MarrAmbientPresentation.resolve(
                            isRunning: false, reducesMotion: reducesMotion,
                            reducesTransparency: reducesTransparency, increasedContrast: increasedContrast,
                            isVisible: isVisible
                        ), .hidden, "Idle work must never retain ambient activity")
                    }
                }
            }
        }
        func mode(motion: Bool = false, transparency: Bool = false,
                  contrast: Bool = false, active: Bool = true) -> MarrAmbientPresentation {
            .resolve(isRunning: true, reducesMotion: motion, reducesTransparency: transparency,
                     increasedContrast: contrast, isVisible: active)
        }
        XCTAssertEqual(mode(), .animated)
        XCTAssertEqual(mode(motion: true), .still)
        XCTAssertEqual(mode(active: false), .still)
        XCTAssertEqual(mode(transparency: true), .outline)
        XCTAssertEqual(mode(contrast: true), .outline)
        XCTAssertEqual(mode(motion: true, transparency: true, contrast: true), .outline)
    }

    func testAmbientSurfacePreservesEditorAndExportsNativePreviews() throws {
        let state = MotionPreviewState()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 596),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Production panels use screenSaver level, and the app's launch cleanup
        // orders normal windows out. Keep this isolated fixture above those panels.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.contentView = NSHostingView(rootView: MotionPreview(state: state))
        // XCTest can launch its host behind another app. An ordered but
        // occluded window intentionally gets the static ambient fallback.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer { window.close() }
        settle(window)
        let visibility = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? MarrAmbientVisibilityView }.first)
        func assertVisible(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(window.isVisible, "The preview window must be ordered in", file: file, line: line)
            XCTAssertTrue(window.occlusionState.contains(.visible),
                "An occluded preview would only exercise the static fallback", file: file, line: line)
            XCTAssertTrue(visibility.isWindowVisible,
                "The production window observer must receive visible state", file: file, line: line)
        }
        assertVisible()
        let editor = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? CodexInputTextView }.first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("Keep this draft while the agent responds.", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 9, length: 4))
        let draft = editor.string
        let selection = editor.selectedRange()

        for width in [420.0, 720.0] {
            window.setContentSize(NSSize(width: width, height: 596))
            for dark in [false, true] {
                state.dark = dark
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for mode in MotionPreviewMode.allCases {
                    state.mode = mode
                    state.answer += "\nThe response grew without moving the composer."
                    window.orderFrontRegardless()
                    settle(window)
                    assertVisible()
                    if mode == .running {
                        XCTAssertEqual(MarrAmbientPresentation.resolve(
                            isRunning: true, reducesMotion: false, reducesTransparency: false,
                            increasedContrast: false, isVisible: visibility.isWindowVisible
                        ), .animated, "Running previews must select the TimelineView branch, not the still fallback")
                    }
                    let current = try XCTUnwrap(descendants(window.contentView).compactMap { $0 as? CodexInputTextView }.first)
                    XCTAssertTrue(current === editor, "Changing ambient state must preserve the native editor")
                    XCTAssertEqual(editor.string, draft)
                    XCTAssertEqual(editor.selectedRange(), selection)
                    XCTAssertTrue(window.firstResponder === editor)
                    try snapshot(window, name: "ambient-\(mode.rawValue)-\(dark ? "dark" : "light")-\(Int(width))")
                }
            }
        }
        state.mode = .running
        window.orderFrontRegardless()
        settle(window)
        assertVisible()
        window.orderOut(nil)
        settle(window)
        XCTAssertFalse(visibility.isWindowVisible, "A hidden native panel must stop ambient animation")
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private func settle(_ window: NSWindow) {
        // Capture the final appearance after the 160 ms decoration fade.
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        window.displayIfNeeded()
    }

    private func snapshot(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marr-agent-ui-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum MotionPreviewMode: String, CaseIterable {
    case idle, running, reducedMotion, reducedTransparency, increasedContrast
}

@MainActor
private final class MotionPreviewState: ObservableObject {
    @Published var mode = MotionPreviewMode.idle
    @Published var dark = false
    @Published var answer = "I’ll review the workspace and prepare a focused change."
}

/// A native, interactive fixture: exported images are illustrative, not snapshots
/// of production AnswerPanel. It exercises the same editor, styles, and decoration.
private struct MotionPreview: View {
    @ObservedObject var state: MotionPreviewState
    @State private var draft = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var focused = true
    @State private var showsDetails = false

    private var isRunning: Bool { state.mode != .idle }
    private var reducesMotion: Bool { state.mode == .reducedMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.large) {
            HStack {
                Text("Work").font(MarrTypography.font(.pageTitle, weight: .semibold))
                Spacer()
                Text("Marr").font(MarrTypography.font(.caption)).foregroundStyle(.secondary)
            }
            Text("Review the workspace").font(MarrTypography.font(.answer, weight: .medium))
            Text(state.answer).font(MarrTypography.font(.answer)).lineLimit(5)
            if isRunning {
                Label("Responding", systemImage: "circle.dotted")
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(MarrMotion.disclosure(reducesMotion: reducesMotion)) {
                    showsDetails.toggle()
                }
            } label: {
                Label("Activity", systemImage: showsDetails ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(MarrButtonStyle(.ghost, size: .compact))
            if showsDetails { Text("Reading workspace files").font(MarrTypography.font(.secondary)) }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                CodexComposerEditor(text: $draft, selection: $selection, focused: $focused,
                                    placeholder: "Add an instruction", onKey: { _ in false }, onSubmit: {})
                HStack(spacing: MarrUI.Spacing.regular) {
                    Button {} label: { Image(systemName: "plus") }
                        .buttonStyle(MarrButtonStyle(.secondary, size: .icon, shape: .circle))
                        .accessibilityLabel("Add attachments")
                    Spacer()
                    Button("Model") {}
                        .buttonStyle(MarrButtonStyle(.ghost, size: .compact))
                    Button {} label: { Image(systemName: "arrow.up") }
                        .buttonStyle(MarrButtonStyle(.primary, size: .icon, shape: .circle))
                        .accessibilityLabel("Send message")
                    if isRunning {
                        Button {} label: { Image(systemName: "stop.fill") }
                            .buttonStyle(MarrButtonStyle(.secondary, size: .icon, shape: .circle))
                            .accessibilityLabel("Stop")
                    }
                }
            }
            .padding(MarrUI.Spacing.medium)
            .background(MarrUI.Surface.raised,
                        in: RoundedRectangle(cornerRadius: MarrUI.Radius.composer, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MarrUI.Radius.composer, style: .continuous)
                    .strokeBorder(MarrUI.Surface.border(increasedContrast: state.mode == .increasedContrast))
            }
            .marrAmbientGlow(isRunning: isRunning)
        }
        .padding(24)
        .background(MarrUI.Surface.canvas)
        .environment(\.colorScheme, state.dark ? .dark : .light)
        .environment(\.marrAccessibilityOverrides, MarrAccessibilityPreferences(
            reducesMotion: reducesMotion,
            reducesTransparency: state.mode == .reducedTransparency,
            increasedContrast: state.mode == .increasedContrast
        ))
    }
}
