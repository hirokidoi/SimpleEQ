import XCTest
@testable import SimpleEQ

@MainActor
final class MixerRenderClockTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("MixerRenderClockTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeClock() -> MixerRenderClock {
        let settings = SettingsStore(defaults: defaults)
        let viewModel = EQViewModel(
            engine: AudioEngine(),
            settings: settings,
            outputController: OutputDeviceController(settings: settings, targetDeviceUID: "test-driver-uid"),
            audioWorld: makeTestAudioWorld()
        )
        return MixerRenderClock(levelStore: MixerLevelStore(slotCount: 4), viewModel: viewModel)
    }

    /// ウィンドウを閉じてもビューはウィンドウに載ったままなので、行の出入りだけでは止まらない。
    func testClockFollowsVisibilityWhileTheRowsStayAttached() {
        let clock = makeClock()
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        clock.add(view)
        XCTAssertTrue(clock.isRunning)

        clock.active = false
        XCTAssertFalse(clock.isRunning, "見えていない間は回さない")

        clock.active = true
        XCTAssertTrue(clock.isRunning)
    }

    /// 見えていない間に行が付いても回り出さない。
    func testRowsAddedWhileInactiveDoNotStartTheClock() {
        let clock = makeClock()
        clock.active = false
        clock.add(MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock))
        XCTAssertFalse(clock.isRunning)
    }

    func testClockStopsWhenTheLastRowLeaves() {
        let clock = makeClock()
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        clock.add(view)
        clock.remove(view)
        XCTAssertFalse(clock.isRunning)
    }
}
