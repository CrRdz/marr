import AppKit
import Carbon
import SwiftUI

@MainActor
final class AnswerPanelController {
    private let window: AnswerPanelWindow
    private let session: ConversationSession
    private var escapeMonitor: Any?
    private var onClose: (() -> Void)?
    private var allowsWindowDragging = false
    private(set) var isMinimized = false

    init(
        controller: MarrController,
        historyStore: ConversationHistoryStore,
        image: PickedImage,
        anchorRect: CGRect,
        initialQuestion: String
    ) {
        session = ConversationSession(initialImage: image, initialQuestion: initialQuestion)
        session.setArchiveHandler { [weak historyStore] archive in
            historyStore?.save(archive)
        }
        let panelSize = NSSize(width: 544, height: 398)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 22

        let x = visibleFrame.maxX - panelSize.width - margin
        let y = visibleFrame.minY + margin
        let composerRect = CGRect(
            x: x + (panelSize.width - 420) / 2,
            y: y + 12,
            width: 420,
            height: 46
        )
        let usesRegularComposerGlass = screen.map {
            BackgroundBrightnessSampler.isNearlyWhite(in: composerRect, on: $0)
        } ?? false

        window = AnswerPanelWindow(
            contentRect: CGRect(origin: CGPoint(x: x, y: y), size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Marr"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = allowsWindowDragging
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        let hostingView = AnswerPanelHostingView(
            rootView: AnswerPanelView(
                controller: controller,
                session: session,
                usesRegularComposerGlass: usesRegularComposerGlass
            )
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        onClose = { [weak controller] in
            controller?.dismissCaptureSession()
        }
    }

    func show() {
        isMinimized = false
        installEscapeMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func minimize() {
        isMinimized = true
        removeEscapeMonitor()
        window.orderOut(nil)
    }

    func restore() {
        isMinimized = false
        installEscapeMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.requestFocus()
    }

    func close() {
        removeEscapeMonitor()
        window.close()
    }

    func setWindowDraggingEnabled(_ isEnabled: Bool) {
        allowsWindowDragging = isEnabled
        window.isMovableByWindowBackground = isEnabled
    }

    func appendScreenshot(_ image: PickedImage) {
        session.appendScreenshot(image)
        isMinimized = false
        installEscapeMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == kVK_Escape else {
                return event
            }

            self?.onClose?()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private enum BackgroundBrightnessSampler {
    static func isNearlyWhite(in rect: CGRect, on screen: NSScreen) -> Bool {
        guard
            let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return false
        }

        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(
            x: (rect.minX - screen.frame.minX) * scale,
            y: (screen.frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)

        guard
            let image = CGDisplayCreateImage(displayID, rect: pixelRect),
            let bitmap = NSBitmapImageRep(cgImage: image).retagging(with: .sRGB)
        else {
            return false
        }

        let columns = 32
        let rows = 6
        var luminanceTotal: CGFloat = 0
        var nearWhiteSamples = 0
        var sampleCount = 0

        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(bitmap.pixelsWide - 1, (column * bitmap.pixelsWide + bitmap.pixelsWide / 2) / columns)
                let y = min(bitmap.pixelsHigh - 1, (row * bitmap.pixelsHigh + bitmap.pixelsHigh / 2) / rows)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }

                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                luminanceTotal += luminance
                if luminance >= 0.93 && color.saturationComponent <= 0.08 {
                    nearWhiteSamples += 1
                }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return false
        }

        let averageLuminance = luminanceTotal / CGFloat(sampleCount)
        let nearWhiteRatio = CGFloat(nearWhiteSamples) / CGFloat(sampleCount)
        return averageLuminance >= 0.90 && nearWhiteRatio >= 0.72
    }
}

private final class AnswerPanelWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class AnswerPanelHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? (bounds.contains(point) ? self : nil)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = firstScrollView(in: self) {
            scrollView.scrollWheel(with: event)
        }
        // Keep wheel events inside the transparent answer panel instead of
        // allowing them to pass through to whatever is behind the window.
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }
}

private struct AnswerPanelView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject var session: ConversationSession
    let usesRegularComposerGlass: Bool

    @State private var question = ""
    @State private var lastAutoScrolledTurnCount = 0
    @State private var hasSubmittedInitialQuestion = false
    @FocusState private var questionFocused: Bool

    private let composerWidth: CGFloat = 420
    private let assistantRevealDelay = 0.30

    init(
        controller: MarrController,
        session: ConversationSession,
        usesRegularComposerGlass: Bool
    ) {
        self.controller = controller
        self.session = session
        self.usesRegularComposerGlass = usesRegularComposerGlass
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            conversationBody
            if !session.pendingImageIDs.isEmpty {
                Label(
                    "\(session.pendingImageIDs.count) screenshot\(session.pendingImageIDs.count == 1 ? "" : "s") attached to the next question",
                    systemImage: "photo.on.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composer
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: 520, height: 374, alignment: .bottom)
        .padding(12)
        .onAppear {
            DispatchQueue.main.async {
                questionFocused = true
                submitInitialQuestion()
            }
        }
        .onChange(of: session.focusRequestID) { _, _ in
            questionFocused = true
        }
    }

    private var panelControls: some View {
        HStack(spacing: 8) {
            PanelControlButton(color: Color(red: 1.0, green: 0.36, blue: 0.34), borderColor: Color(red: 0.82, green: 0.20, blue: 0.19)) {
                controller.dismissCaptureSession()
            }
            .help("Close")

            PanelControlButton(color: Color(red: 1.0, green: 0.78, blue: 0.13), borderColor: Color(red: 0.82, green: 0.58, blue: 0.02)) {
                controller.minimizeAnswerPanel()
            }
            .help("Minimize")
        }
    }

    private var conversationBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.turns) { turn in
                        turnView(turn, isCompact: false, showsUserMessage: true)
                            .id(turn.id)
                    }
                }
                .padding(.top, 32)
                .padding(.bottom, 2)
                .frame(width: composerWidth, alignment: .topLeading)
                .frame(minHeight: 276, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: session.turns.count) { _, nextCount in
                guard nextCount > lastAutoScrolledTurnCount, let lastID = session.turns.last?.id else {
                    return
                }

                lastAutoScrolledTurnCount = nextCount
                DispatchQueue.main.async {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(width: composerWidth + 24, height: 276)
        .liquidGlassSurface(cornerRadius: 24, isClear: true)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topLeading) {
            panelControls
                .padding(.leading, 14)
                .padding(.top, 12)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 7)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func turnView(_ turn: ConversationTurn, isCompact: Bool, showsUserMessage: Bool) -> some View {
        VStack(spacing: 10) {
            if showsUserMessage {
                HStack {
                    Spacer(minLength: 72)
                    Text(turn.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlAccentColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            if turn.showsAssistant {
                if turn.errorMessage != nil {
                    errorMessage(turn)
                        .transition(.opacity)
                } else {
                    HStack(alignment: .top) {
                        assistantMessage(turn, isCompact: isCompact)
                        Spacer(minLength: 72)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func assistantMessage(_ turn: ConversationTurn, isCompact: Bool) -> some View {
        if turn.isLoading {
            TypingIndicatorView()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassSurface(cornerRadius: 15, isClear: true)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        } else {
            MarkdownResponseView(source: turn.answer.isEmpty ? " " : turn.answer)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .liquidGlassSurface(cornerRadius: 15, isClear: true)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        }
    }

    private func errorMessage(_ turn: ConversationTurn) -> some View {
        VStack(spacing: 8) {
            Text(turn.errorMessage ?? "")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .textSelection(.enabled)
            Button("Retry") {
                retry(turn.id)
            }
            .controlSize(.small)
            .disabled(session.hasLoadingTurn)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .lineLimit(1...2)
                .foregroundStyle(.primary)
                .focused($questionFocused)
                .onSubmit {
                    sendCurrentQuestion()
                }

            Button {
                sendCurrentQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .sendCircleButton(isEnabled: canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(width: composerWidth)
        .frame(minHeight: 46)
        .liquidGlassSurface(cornerRadius: 23, isClear: !usesRegularComposerGlass)
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .white.opacity(0.10), radius: 1, x: 0, y: -1)
    }

    private var canSend: Bool {
        !session.hasLoadingTurn && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCurrentQuestion() {
        let current = question
        question = ""
        send(current)
    }

    private func send(_ rawQuestion: String) {
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !session.hasLoadingTurn else {
            return
        }

        guard let turnID = session.beginTurn(question: trimmedQuestion) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + assistantRevealDelay) {
            withAnimation(.easeOut(duration: 0.20)) {
                session.revealAssistant(for: turnID)
            }
        }
        submit(turnID)
    }

    private func submitInitialQuestion() {
        guard !hasSubmittedInitialQuestion, let turnID = session.turns.first?.id else {
            return
        }

        hasSubmittedInitialQuestion = true
        submit(turnID)
    }

    private func retry(_ turnID: UUID) {
        guard session.prepareRetry(turnID) else { return }
        submit(turnID)
    }

    private func submit(_ turnID: UUID) {
        guard let request = session.request(for: turnID) else {
            session.fail(turnID, message: "Could not build the conversation context.")
            return
        }

        Task {
            do {
                let response = try await controller.submit(request: request)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.18)) {
                        session.complete(turnID, answer: response)
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.18)) {
                        session.fail(turnID, message: controller.userFacingMessage(for: error))
                    }
                }
            }
        }
    }
}

private struct PanelControlButton: View {
    let color: Color
    let borderColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(
                    Circle()
                        .stroke(borderColor.opacity(0.72), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0.08), radius: isHovering ? 3 : 2, x: 0, y: 1)
                .frame(width: 13, height: 13)
                .scaleEffect(isHovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
    }
}

private struct MarkdownResponseView: View {
    let source: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, content):
            Text(inlineMarkdown(content))
                .font(.system(size: headingSize(level), weight: .semibold))
                .lineSpacing(2)
                .padding(.top, level == 1 ? 2 : 0)

        case let .paragraph(content):
            Text(inlineMarkdown(content))
                .font(.system(size: 13))
                .lineSpacing(3)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(item))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 17, alignment: .trailing)
                        Text(inlineMarkdown(item))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(content):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(inlineMarkdown(content))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case let .code(content):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: content)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .padding(10)
            }
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        case .divider:
            Rectangle()
                .fill(.separator.opacity(0.65))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func inlineMarkdown(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        default: 14
        }
    }
}

private enum MarkdownBlock {
    case heading(level: Int, content: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
    case divider
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, content: heading.content))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !startsBlock(line) else { break }
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("```")
            || line.hasPrefix(">")
            || heading(from: line) != nil
            || unorderedItem(from: line) != nil
            || orderedItem(from: line) != nil
            || isDivider(line)
    }

    private static func heading(from line: String) -> (level: Int, content: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let content = line.dropFirst(level)
        guard content.first?.isWhitespace == true else { return nil }
        return (level, content.trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        guard let period = line.firstIndex(of: ".") else { return nil }
        let number = line[..<period]
        let remainder = line[line.index(after: period)...]
        guard Int(number) != nil, remainder.first?.isWhitespace == true else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(String(marker)) && compact.allSatisfy { $0 == marker }
    }
}

private struct TypingIndicatorView: View {
    @State private var activeDot = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.primary.opacity(index == activeDot ? 0.72 : 0.28))
                    .frame(width: 5, height: 5)
                    .offset(y: index == activeDot ? -1 : 0)
            }
        }
        .frame(height: 16)
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { _ in
                activeDot = (activeDot + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat, isClear: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                isClear ? .clear.interactive() : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(isClear ? 0.05 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(isClear ? 0.22 : 0.34), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func liquidGlassIconButton() -> some View {
        if #available(macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .foregroundStyle(.secondary)
        } else {
            self
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func sendCircleButton(isEnabled: Bool) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(isEnabled ? Color(nsColor: .labelColor) : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(isEnabled ? 0.18 : 0.06), radius: 8, x: 0, y: 4)
    }
}
