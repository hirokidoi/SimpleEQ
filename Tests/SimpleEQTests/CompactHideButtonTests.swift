import AppKit
import XCTest

@testable import SimpleEQ

final class CompactHideButtonPolicyTests: XCTestCase {
    private let hotZone = CGRect(x: 0, y: 0, width: 72, height: 56)
    private let buttonRect = CGRect(x: 10, y: 10, width: 20, height: 20)

    func testRevealedWhileThePointerIsInsideTheHotZone() {
        XCTAssertTrue(CompactHideButtonPolicy.revealed(
            windowVisible: true, pointer: CGPoint(x: 5, y: 5), hotZone: hotZone
        ))
    }

    func testNotRevealedWhileThePointerIsOutsideTheHotZone() {
        XCTAssertFalse(CompactHideButtonPolicy.revealed(
            windowVisible: true, pointer: CGPoint(x: 100, y: 5), hotZone: hotZone
        ))
    }

    func testNotRevealedWhileTheWindowIsNotVisibleEvenWithThePointerInside() {
        XCTAssertFalse(CompactHideButtonPolicy.revealed(
            windowVisible: false, pointer: CGPoint(x: 5, y: 5), hotZone: hotZone
        ))
    }

    func testNotRevealedWhereThePointerCannotBeRead() {
        XCTAssertFalse(CompactHideButtonPolicy.revealed(
            windowVisible: true, pointer: nil, hotZone: hotZone
        ))
    }

    func testAcceptsThePressOnlyInsideTheButton() {
        XCTAssertTrue(CompactHideButtonPolicy.acceptsPress(
            revealed: true, point: CGPoint(x: 20, y: 20), buttonRect: buttonRect
        ))
        XCTAssertFalse(CompactHideButtonPolicy.acceptsPress(
            revealed: true, point: CGPoint(x: 5, y: 5), buttonRect: buttonRect
        ))
    }

    func testRefusesThePressWhileNotRevealed() {
        XCTAssertFalse(CompactHideButtonPolicy.acceptsPress(
            revealed: false, point: CGPoint(x: 20, y: 20), buttonRect: buttonRect
        ))
    }

    /// ホットゾーンに入っただけの位置は押下を受けない (ボタンの外だけがドラッグ面へ通る)。
    func testTheHotZoneIsWiderThanTheSurfaceThatAnswersThePress() {
        let insideHotZoneOnly = CGPoint(x: 50, y: 40)
        XCTAssertTrue(CompactHideButtonPolicy.revealed(
            windowVisible: true, pointer: insideHotZoneOnly, hotZone: hotZone
        ))
        XCTAssertFalse(CompactHideButtonPolicy.acceptsPress(
            revealed: true, point: insideHotZoneOnly, buttonRect: buttonRect
        ))
    }
}

@MainActor
final class CompactHideButtonRevealTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let hotZone = CGSize(width: 72, height: 56)
    private let buttonRect = CGRect(x: 10, y: 10, width: 20, height: 20)
    private let contentSize = CGSize(width: 300, height: 200)

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("CompactHideButtonRevealTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testTheRevealDropsWhileTheWindowIsHidden() {
        let (_, window, revealed) = makeAttachedView()
        defer { window.orderOut(nil) }
        XCTAssertTrue(revealed(), "ポインタがホットゾーンにあれば現れること")

        window.orderOut(nil)
        pumpRunLoopUntil { !revealed() }
        XCTAssertFalse(revealed(), "隠れている間は現れないこと")
    }

    /// 隠している間にポインタが離れた場合、開き直しても現れないこと (残留の再発防止)。
    func testTheRevealDoesNotSurviveHidingAndShowingAgain() {
        let (view, window, revealed) = makeAttachedView()
        defer { window.orderOut(nil) }
        XCTAssertTrue(revealed())

        window.orderOut(nil)
        view.pointerLocation = { [frame = window.frame] in
            NSPoint(x: frame.maxX - 10, y: frame.minY + 10)
        }
        window.orderFront(nil)
        pumpRunLoopUntil({ false }, timeout: 0.2)
        XCTAssertFalse(revealed(), "開き直したときポインタが外にあれば現れないこと")
    }

    /// 離脱通知は領域内にいるうちにも届くため、位置を読み直して判定すること。
    func testTheDepartureNoticeAloneDoesNotDropTheReveal() {
        let (view, window, revealed) = makeAttachedView()
        defer { window.orderOut(nil) }
        XCTAssertTrue(revealed())

        view.mouseExited(with: mouseEvent(in: window))
        pumpRunLoopUntil({ false }, timeout: 0.2)
        XCTAssertTrue(revealed(), "ポインタがホットゾーンに留まっていれば現れたままであること")

        view.pointerLocation = { [frame = window.frame] in
            NSPoint(x: frame.maxX - 10, y: frame.minY + 10)
        }
        view.mouseExited(with: mouseEvent(in: window))
        pumpRunLoopUntil { !revealed() }
        XCTAssertFalse(revealed(), "ポインタが離れていれば消えること")
    }

    /// 押下を受ける面は、見えていない間は下のドラッグ面へ通すこと。
    func testTheSurfaceAnswersOnlyWhileTheButtonIsShown() {
        let (view, window, revealed) = makeAttachedView()
        defer { window.orderOut(nil) }
        let onButton = view.convert(CGPoint(x: buttonRect.midX, y: buttonRect.midY), to: view.superview)
        XCTAssertTrue(revealed())
        XCTAssertIdentical(view.hitTest(onButton), view, "現れている間はボタンの上で応じること")

        window.orderOut(nil)
        pumpRunLoopUntil { !revealed() }
        XCTAssertNil(view.hitTest(onButton), "現れていない間は応じないこと")
    }

    /// アプリごと隠れる回もウィンドウの可視性が落ちるため、隠す経路を別に観測する必要はない。
    func testTheRevealDoesNotSurviveHidingTheApplication() {
        let (view, window, revealed) = makeAttachedView()
        defer {
            NSApp.unhide(nil)
            window.orderOut(nil)
        }
        XCTAssertTrue(revealed())

        NSApp.hide(nil)
        pumpRunLoopUntil { !revealed() }
        XCTAssertFalse(revealed(), "アプリが隠れている間は現れないこと")

        view.pointerLocation = { [frame = window.frame] in
            NSPoint(x: frame.maxX - 10, y: frame.minY + 10)
        }
        NSApp.unhide(nil)
        pumpRunLoopUntil({ false }, timeout: 0.2)
        XCTAssertFalse(revealed(), "戻したときポインタが外にあれば現れないこと")
    }

    private func mouseEvent(in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }

    /// ポインタの位置は screen ↔ window ↔ view の変換を経るため、期待値はウィンドウ矩形の算術だけから作る。
    private func makeAttachedView() -> (CompactHideHitView, NSWindow, () -> Bool) {
        let settings = SettingsStore(defaults: defaults)
        let viewModel = EQViewModel(
            engine: AudioEngine(), settings: settings,
            outputController: OutputDeviceController(settings: settings, targetDeviceUID: "test-driver-uid"),
            audioWorld: makeTestAudioWorld()
        )
        let mixer = MixerModel(settings: settings, coordinator: nil, levelStore: MixerLevelStore(slotCount: 4))

        let reported = RevealRecorder()
        let view = CompactHideHitView(
            viewModel: viewModel, mixer: mixer, buttonRect: buttonRect,
            onRevealChange: { reported.value = $0 }
        )
        view.frame = CGRect(
            x: 0, y: contentSize.height - hotZone.height, width: hotZone.width, height: hotZone.height
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        // 原点が 0 だと screen ↔ window の変換が恒等になり、取り違えても検証が通ってしまう。
        window.setFrameOrigin(NSPoint(x: 120, y: 80))
        let container = NSView(frame: CGRect(origin: .zero, size: contentSize))
        window.contentView = container
        window.orderFront(nil)
        // 可視のウィンドウへ後から付ける。付けた時点の可視性だけで正しく見える形にしておくと、
        // 隠して開き直す経路だけを検証できる。
        container.addSubview(view)

        let frame = window.frame
        view.pointerLocation = { NSPoint(x: frame.minX + 20, y: frame.maxY - 20) }
        view.updateTrackingAreas()
        pumpRunLoopUntil { reported.value == true }
        return (view, window, { reported.value == true })
    }
}

private final class RevealRecorder {
    var value: Bool?
}
