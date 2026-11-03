import AppKit
import Metal
import RiveRuntime
import XCTest
@testable import Marr

@MainActor
final class MarrCompanionTests: XCTestCase {
    func testPersonalityMovesAtRestAndBodyFollowsEyes() {
        var life = MarrCompanionPersonality()
        let first = life.advance(dt: 1.0 / 30, target: CGPoint(x: 1, y: 0), engaged: true, near: false)
        XCTAssertGreaterThan(first.gaze.x, first.body.x / 4.5, "Eyes must lead the body")
        for _ in 0..<90 { _ = life.advance(dt: 1.0 / 30, target: .zero, engaged: false, near: false) }
        let before = life.pose
        for _ in 0..<30 { _ = life.advance(dt: 1.0 / 30, target: .zero, engaged: false, near: false) }
        XCTAssertNotEqual(before.body, life.pose.body, "A stationary pointer must not freeze the character")
        XCTAssertNotEqual(before.gaze, life.pose.gaze)
        XCTAssertLessThan(abs(life.pose.body.x), 8)
        XCTAssertLessThan(abs(life.pose.body.y), 8)
    }

    func testPersonalityBlinksAndReopensWithoutFreezingBody() {
        var life = MarrCompanionPersonality()
        var minimum: CGFloat = 1
        for _ in 0..<100 {
            let pose = life.advance(dt: 1.0 / 60, target: .zero, engaged: true, near: false,
                                    blinkDelay: 4, shouldDoubleBlink: true)
            minimum = min(minimum, pose.eyeOpen)
        }
        XCTAssertEqual(minimum, 1)
        for _ in 0..<110 {
            let pose = life.advance(dt: 1.0 / 60, target: .zero, engaged: true, near: false,
                                    blinkDelay: 4, shouldDoubleBlink: true)
            minimum = min(minimum, pose.eyeOpen)
        }
        XCTAssertLessThan(minimum, 0.15)
        XCTAssertEqual(life.pose.eyeOpen, 1, accuracy: 0.001)
    }

    func testNativePersonalityInputsResetWithReducedMotion() async throws {
        let player = MarrCompanionPlayer()
        await player.load(phase: .idle, reducesMotion: false)
        let binding = try XCTUnwrap(player.instance)
        player.applyPersonality(.init(gaze: .zero, body: CGPoint(x: 4, y: -3), tilt: 0.08, eyeOpen: 0.05))
        let x = try await binding.value(of: NumberProperty(path: "bodyX"))
        let lid = try await binding.value(of: NumberProperty(path: "eyeOpen"))
        XCTAssertEqual(x, 68)
        XCTAssertEqual(lid, 0.05, accuracy: 0.001)
        player.update(phase: .idle, reducesMotion: true)
        let resetX = try await binding.value(of: NumberProperty(path: "bodyX"))
        let resetLid = try await binding.value(of: NumberProperty(path: "eyeOpen"))
        XCTAssertEqual(resetX, 64)
        XCTAssertEqual(resetLid, 1)
    }

    func testPointerGazeUsesScreenDirectionAndRadialBounds() {
        let center = CGPoint(x: -400, y: 300)
        XCTAssertEqual(MarrCompanionPointerView.target(pointer: center, center: center), .zero)
        XCTAssertEqual(MarrCompanionPointerView.target(pointer: CGPoint(x: -310, y: 390), center: center),
                       CGPoint(x: 0.5, y: -0.5))
        let diagonal = MarrCompanionPointerView.target(pointer: CGPoint(x: 1000, y: -1000), center: center)
        XCTAssertEqual(hypot(diagonal.x, diagonal.y), 1, accuracy: 0.0001)
        XCTAssertGreaterThan(diagonal.x, 0)
        XCTAssertGreaterThan(diagonal.y, 0)
        XCTAssertEqual(MarrCompanionPointerView.target(pointer: CGPoint(x: CGFloat.nan, y: 0), center: center), .zero)
    }

    func testCaptureStatePrioritizesInFlightWorkAndAnnotationOverReady() {
        XCTAssertEqual(MarrCompanionPhase.capture(sending: true, selecting: true, annotating: true,
                                                 hasSelection: true, hasPinnedImages: true), .sending)
        XCTAssertEqual(MarrCompanionPhase.capture(sending: false, selecting: true, annotating: true,
                                                 hasSelection: true, hasPinnedImages: false), .selecting)
        XCTAssertEqual(MarrCompanionPhase.capture(sending: false, selecting: false, annotating: true,
                                                 hasSelection: true, hasPinnedImages: false), .annotating)
        XCTAssertEqual(MarrCompanionPhase.capture(sending: false, selecting: false, annotating: false,
                                                 hasSelection: false, hasPinnedImages: true), .selected)
        XCTAssertEqual(MarrCompanionPhase.capture(sending: false, selecting: false, annotating: false,
                                                 hasSelection: false, hasPinnedImages: false), .idle)
    }

    func testComparisonTakesPrecedenceWhilePinnedAndReturnsToPinned() {
        XCTAssertEqual(MarrCompanionPhase.translationResult(comparing: true, pinned: true), .comparing)
        XCTAssertEqual(MarrCompanionPhase.translationResult(comparing: false, pinned: true), .pinned)
        XCTAssertEqual(MarrCompanionPhase.translationResult(comparing: false, pinned: false), .success)
    }

    func testTranslationJourneyUsesAConsistentFiveStateVocabulary() {
        let journey: [MarrCompanionPhase] = [.idle, .selecting, .recognizing, .translating,
                                            .rendering, .success, .comparing, .error]
        XCTAssertEqual(journey.map(\.mood), [.waiting, .observing, .processing, .processing,
                                              .processing, .settled, .observing, .attention])
        XCTAssertEqual(Set(MarrCompanionPhase.allCases.map { $0.mood.rawValue }), Set(0...4))
        XCTAssertEqual(MarrCompanionPhase.recognizing.scanStrength, 1)
        XCTAssertEqual(MarrCompanionPhase.translating.scanStrength, 0)
    }

    func testBundledAssetIsNativeRive() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MarrCompanion", withExtension: "riv"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIVE")
        XCTAssertGreaterThan(data.count, 100_000, "The glass image must be embedded for offline playback")
    }

    func testRealRuntimeLoadsEveryPhaseAndKeepsInstancesIndependent() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let first = MarrCompanionPlayer()
        let second = MarrCompanionPlayer()
        await first.load(phase: .recognizing, reducesMotion: true)
        await second.load(phase: .selected, reducesMotion: true)
        let firstRive = try XCTUnwrap(first.rive, "The shipped .riv must load in the pinned Apple runtime")
        let secondRive = try XCTUnwrap(second.rive)
        let binding = try XCTUnwrap(first.instance)
        let otherBinding = try XCTUnwrap(second.instance)
        XCTAssertTrue(firstRive.file === secondRive.file, "Share decoded image resources")
        XCTAssertFalse(firstRive.artboard === secondRive.artboard, "Separate windows need independent states")
        let machineNames = try await firstRive.artboard.getStateMachineNames()
        XCTAssertEqual(machineNames, ["Companion"])
        for phase in MarrCompanionPhase.allCases {
            first.update(phase: phase, reducesMotion: true)
            let actual = try await binding.value(of: NumberProperty(path: "phase"))
            let other = try await otherBinding.value(of: NumberProperty(path: "phase"))
            XCTAssertEqual(actual, Float(phase.mood.rawValue))
            let scan = try await binding.value(of: NumberProperty(path: "scan"))
            XCTAssertEqual(scan, phase.scanStrength)
            XCTAssertEqual(other, Float(MarrCompanionMood.observing.rawValue))
        }
        first.update(phase: .translating, reducesMotion: false)
        first.update(phase: .success, reducesMotion: false)
        first.update(phase: .error, reducesMotion: true)
        let final = try await binding.value(of: NumberProperty(path: "phase"))
        XCTAssertEqual(final, Float(MarrCompanionMood.attention.rawValue))
        XCTAssertTrue(first.reducesMotion)
    }

    func testGazeIsBoundClampedAndFrozenWithReducedMotion() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let player = MarrCompanionPlayer()
        await player.load(phase: .selecting, reducesMotion: false, gaze: CGPoint(x: 4, y: -2))
        let binding = try XCTUnwrap(player.instance)
        let x = try await binding.value(of: NumberProperty(path: "gazeX"))
        let y = try await binding.value(of: NumberProperty(path: "gazeY"))
        XCTAssertEqual(x, 10)
        XCTAssertEqual(y, -8)
        player.update(phase: .selecting, reducesMotion: false, gaze: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        XCTAssertEqual(player.gaze, .zero, "Invalid geometry must not reach the native renderer")
        player.update(phase: .selecting, reducesMotion: true, gaze: CGPoint(x: 1, y: 1))
        player.update(phase: .selecting, reducesMotion: true, gaze: CGPoint(x: -1, y: -1))
        let frozenX = try await binding.value(of: NumberProperty(path: "gazeX"))
        let frozenY = try await binding.value(of: NumberProperty(path: "gazeY"))
        XCTAssertEqual(frozenX, 0)
        XCTAssertEqual(frozenY, 0)
        XCTAssertEqual(player.gaze, .zero)
    }

    func testCancelledLoadDoesNotPublishAStalePlayer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let player = MarrCompanionPlayer()
        let work = Task { await player.load(phase: .translating, reducesMotion: false) }
        work.cancel()
        await work.value
        XCTAssertNil(player.rive)
        await player.load(phase: .error, reducesMotion: true)
        XCTAssertNotNil(player.rive, "A subsequent visible appearance can load normally")
        XCTAssertEqual(player.phase, .error)
    }

    func testToolFormsAreIndependentFromActivityAndOtherInstances() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let tool = MarrCompanionPlayer()
        let original = MarrCompanionPlayer()
        await tool.load(phase: .idle, reducesMotion: true, form: .orb)
        await original.load(phase: .idle, reducesMotion: true)
        XCTAssertNotNil(tool.rive)
        let binding = try XCTUnwrap(tool.instance)
        let other = try XCTUnwrap(original.instance)
        for form in MarrCompanionForm.allCases {
            tool.update(phase: .translating, reducesMotion: true, form: form)
            let value = try await binding.value(of: NumberProperty(path: "tool"))
            let activity = try await binding.value(of: NumberProperty(path: "phase"))
            let originalForm = try await other.value(of: NumberProperty(path: "tool"))
            XCTAssertEqual(value, Float(form.rawValue))
            XCTAssertEqual(activity, Float(MarrCompanionMood.processing.rawValue))
            XCTAssertEqual(originalForm, 0)
        }
        XCTAssertEqual(ScreenshotAnnotationTool.pen.companionForm, .pen)
        XCTAssertEqual(ScreenshotAnnotationTool.arrow.companionForm, .arrow)
        XCTAssertEqual(ScreenshotAnnotationTool.rectangle.companionForm, .rectangle)
        XCTAssertEqual(ScreenshotAnnotationTool.number.companionForm, .number)
    }

    func testAppleRendererMorphsGeometryAndSettlesAfterInterruptedChanges() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let player = MarrCompanionPlayer()
        await player.load(phase: .idle, reducesMotion: false, form: .orb)
        let rive = try XCTUnwrap(player.rive)
        let edge = 256
        func render() async throws -> Data {
            let renderer = rive.makeRenderer()
            var config = RiveUIRendererConfiguration(rive: rive, drawableSize: CGSize(width: edge, height: edge))
            config.color = 0
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: config.pixelFormat,
                width: edge, height: edge, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let done = expectation(description: "Render vector tool")
            renderer.draw(config, to: texture, from: device, onDraw: { buffer in
                buffer.addCompletedHandler { _ in done.fulfill() }
            }, onSkipped: { done.fulfill() }, onError: { error in
                XCTFail("Native tool rendering failed: \(error)"); done.fulfill()
            })
            await fulfillment(of: [done], timeout: 10)
            var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
            texture.getBytes(&pixels, bytesPerRow: edge * 4,
                from: MTLRegionMake2D(0, 0, edge, edge), mipmapLevel: 0)
            XCTAssertEqual(pixels[3], 0)
            return Data(pixels)
        }
        func advance(_ frames: Int) {
            for _ in 0..<frames { rive.stateMachine.advance(by: 1.0 / 60) }
        }
        func silhouette(_ pixels: Data) -> [Bool] {
            stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] > 128 }
        }
        advance(60)
        let orb = try await render()
        player.update(phase: .idle, reducesMotion: false, form: .pen)
        advance(10)
        let between = try await render()
        advance(50)
        let pen = try await render()
        XCTAssertNotEqual(silhouette(orb), silhouette(pen), "The body itself must change shape")
        XCTAssertNotEqual(silhouette(between), silhouette(orb))
        XCTAssertNotEqual(silhouette(between), silhouette(pen), "Intermediate frames must morph the actual contour")
        for form in [MarrCompanionForm.translate, .arrow, .rectangle, .number, .translate] {
            player.update(phase: .idle, reducesMotion: false, form: form)
            advance(5)
        }
        advance(120)
        let interrupted = try await render()
        player.update(phase: .idle, reducesMotion: true, form: .pen)
        _ = try await render()
        player.update(phase: .idle, reducesMotion: true, form: .translate)
        let reducedMotion = try await render()
        let edgeDifference = zip(silhouette(interrupted), silhouette(reducedMotion)).filter { $0 != $1 }.count
        XCTAssertLessThan(edgeDifference, 200,
                         "The final contours must match, allowing only the independent subpixel breathing motion")
        func translationInk(_ pixels: Data) -> [Bool] {
            (116..<162).flatMap { y in
                (72..<184).map { x in
                    let i = (y * edge + x) * 4
                    return pixels[i + 3] > 128 &&
                        Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 450
                }
            }
        }
        let textDifference = zip(translationInk(interrupted), translationInk(reducedMotion))
            .filter { $0 != $1 }.count
        XCTAssertLessThan(textDifference, 160,
                         "Reduce Motion must reach the translated word, not pause on the source word")
        var silhouettes: [[Bool]] = []
        for form in MarrCompanionForm.allCases {
            player.update(phase: .idle, reducesMotion: true, form: form)
            let pixels = try await render()
            let shape = silhouette(pixels)
            XCTAssertGreaterThan(shape.filter { $0 }.count, 2_000)
            XCTAssertFalse(silhouettes.contains(shape), "Every tool must have a distinct body contour")
            silhouettes.append(shape)
        }
    }

    func testAppleRendererShowsFiveMoodsAndRespondsToScanAndGaze() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let edge = 256

        // Every sample uses a fresh artboard at the same time, so pixel differences
        // demonstrate the input rather than an unrelated passage of animation time.
        func render(_ phase: MarrCompanionPhase, gaze: CGPoint = .zero) async throws -> Data {
            let player = MarrCompanionPlayer()
            await player.load(phase: phase, reducesMotion: false, gaze: gaze)
            let rive = try XCTUnwrap(player.rive)
            rive.stateMachine.advance(by: 1.2)
            let renderer = rive.makeRenderer()
            var config = RiveUIRendererConfiguration(rive: rive, drawableSize: CGSize(width: edge, height: edge))
            config.color = 0
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: config.pixelFormat,
                                                                      width: edge, height: edge, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let rendered = expectation(description: "Render \(phase)")
            renderer.draw(config, to: texture, from: device, onDraw: { buffer in
                buffer.addCompletedHandler { _ in rendered.fulfill() }
            }, onSkipped: { rendered.fulfill() }, onError: { error in
                XCTFail("Rive Metal render failed: \(error)")
                rendered.fulfill()
            })
            await fulfillment(of: [rendered], timeout: 10)
            var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
            texture.getBytes(&pixels, bytesPerRow: edge * 4,
                             from: MTLRegionMake2D(0, 0, edge, edge), mipmapLevel: 0)
            XCTAssertEqual(pixels[3], 0, "No opaque tile around the companion")
            XCTAssertGreaterThan(pixels[(edge / 2 * edge + edge / 2) * 4 + 3], 100,
                                 "The actual Apple runtime must draw the glass body")
            return Data(pixels)
        }
        var seen: Set<Data> = []
        for mood in MarrCompanionMood.allCases {
            let pixels = try await render(mood.representativePhase)
            XCTAssertTrue(seen.insert(pixels).inserted, "The five visual states must remain distinguishable")
        }
        let translating = try await render(.translating)
        let recognizing = try await render(.recognizing)
        XCTAssertNotEqual(recognizing, translating, "Recognition must enable its subtle reading light")
        let lookingLeft = try await render(.selecting, gaze: CGPoint(x: -1, y: 0))
        let lookingRight = try await render(.selecting, gaze: CGPoint(x: 1, y: 0))
        XCTAssertNotEqual(lookingLeft, lookingRight, "Actual content direction must move the native eyes")
    }
}
