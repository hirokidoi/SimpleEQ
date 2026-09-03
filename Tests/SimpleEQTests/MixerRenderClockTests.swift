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

    private func makeViewModel() -> EQViewModel {
        let settings = SettingsStore(defaults: defaults)
        return EQViewModel(
            engine: AudioEngine(),
            settings: settings,
            outputController: OutputDeviceController(settings: settings, targetDeviceUID: "test-driver-uid"),
            audioWorld: makeTestAudioWorld()
        )
    }

    private func makeClock(levelStore: MixerLevelStore = MixerLevelStore(slotCount: 4)) -> MixerRenderClock {
        MixerRenderClock(levelStore: levelStore, viewModel: makeViewModel())
    }

    /// 行のメーターの平滑化は、ビジュアライザの調整から切り離して持つ。
    /// 既定値と一致していると追従しても気づけないため、どちらの段も定数と違う側へ寄せて確かめる。
    func testSmoothingIsHeldApartFromTheVisualizerSetting() throws {
        let viewModel = makeViewModel()
        let apart = try XCTUnwrap(
            (1...EQLayout.Tuning.attack.values.count).first {
                EQLayout.Tuning.attack.value(at: $0) != EQLayout.Mixer.meterAttack
                    && EQLayout.Tuning.release.value(at: $0) != EQLayout.Mixer.meterRelease
            }
        )
        viewModel.attackLevel = apart
        viewModel.releaseLevel = apart
        XCTAssertNotEqual(viewModel.attackCoef, EQLayout.Mixer.meterAttack, "前提: 設定側が定数と違う値であること")
        XCTAssertNotEqual(viewModel.releaseCoef, EQLayout.Mixer.meterRelease, "前提: 設定側が定数と違う値であること")

        let clock = MixerRenderClock(levelStore: MixerLevelStore(slotCount: 4), viewModel: viewModel)
        XCTAssertEqual(clock.attackCoef, EQLayout.Mixer.meterAttack)
        XCTAssertEqual(clock.releaseCoef, EQLayout.Mixer.meterRelease)
    }

    /// 刻みは上限で頭打ちにし、それより遅い設定のときはその設定より速く回さない。
    func testClockIsCappedButNeverFasterThanTheVisualizer() {
        let cap = EQLayout.Mixer.meterFpsCap
        XCTAssertEqual(MixerRenderClock.fps(visualizerFps: cap * 2), cap)
        XCTAssertEqual(MixerRenderClock.fps(visualizerFps: cap), cap)
        XCTAssertEqual(MixerRenderClock.fps(visualizerFps: cap / 2), cap / 2)
    }

    /// ウィンドウを閉じてもビューはウィンドウに載ったままなので、行の出入りだけでは止まらない。
    func testClockFollowsVisibilityWhileTheRowsStayAttached() {
        let clock = makeClock()
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        clock.add(view)
        clock.active = true
        XCTAssertTrue(clock.isRunning)

        clock.active = false
        XCTAssertFalse(clock.isRunning, "見えていない間は回さない")

        clock.active = true
        XCTAssertTrue(clock.isRunning)
    }

    /// 見えていない間に行が付いても回り出さない。
    func testRowsAddedWhileInactiveDoNotStartTheClock() {
        let clock = makeClock()
        clock.add(MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock))
        XCTAssertFalse(clock.isRunning)
    }

    func testClockStopsWhenTheLastRowLeaves() {
        let clock = makeClock()
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        clock.active = true
        clock.add(view)
        clock.remove(view)
        XCTAssertFalse(clock.isRunning)
    }

    // MARK: - 止まっている間に溜まる表示値

    /// 行は弱参照で持たれるため、止めて動かし直す間の生存を明示する。
    private func resumeAfterFolding(clock: MixerRenderClock, store: MixerLevelStore) {
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        withExtendedLifetime(view) {
            clock.add(view)
            clock.active = true
            clock.active = false

            store.beginFold(tableGeneration: 1)
            store.foldSlot(
                index: 0, clientID: 7, processID: 501, outputCycleSeq: 1,
                clipEventCount: 3, peak: 0.9, appliedGain: 1
            )

            clock.active = true
            XCTAssertTrue(clock.isRunning, "動き出していないので、以降の判定は成り立たない")
        }
    }

    func testPeakAccumulatedWhileStoppedIsDiscardedOnResume() {
        let store = MixerLevelStore(slotCount: 4)
        resumeAfterFolding(clock: makeClock(levelStore: store), store: store)
        var samples = store.makeSampleBuffer()
        store.takeSamples(into: &samples)
        XCTAssertEqual(samples[0].peak, 0, "止まっていた間のピークを持ち越している")
    }

    /// 行が付くより先に見え始めることがあるため、行の有無で捨てるかどうかが変わってはいけない。
    func testResumingWithoutRowsStillDiscards() {
        let store = MixerLevelStore(slotCount: 4)
        let clock = makeClock(levelStore: store)
        clock.active = false

        store.beginFold(tableGeneration: 1)
        store.foldSlot(
            index: 0, clientID: 7, processID: 501, outputCycleSeq: 1,
            clipEventCount: 3, peak: 0.9, appliedGain: 1
        )

        clock.active = true
        XCTAssertFalse(clock.isRunning, "行が無いのでクロックは回らない")

        var samples = store.makeSampleBuffer()
        store.takeSamples(into: &samples)
        XCTAssertEqual(samples[0].peak, 0, "止まっていた間のピークを持ち越している")
    }

    /// 見えている最中でも、行が全部外れている間は止まる。付き直す回も捨てる。
    func testRowsReattachedWhileVisibleAlsoDiscard() {
        let store = MixerLevelStore(slotCount: 4)
        let clock = makeClock(levelStore: store)
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        withExtendedLifetime(view) {
            clock.active = true
            clock.add(view)
            clock.remove(view)
            XCTAssertFalse(clock.isRunning)

            store.beginFold(tableGeneration: 1)
            store.foldSlot(
                index: 0, clientID: 7, processID: 501, outputCycleSeq: 1,
                clipEventCount: 3, peak: 0.9, appliedGain: 1
            )

            clock.add(view)
            XCTAssertTrue(clock.isRunning)
        }

        var samples = store.makeSampleBuffer()
        store.takeSamples(into: &samples)
        XCTAssertEqual(samples[0].peak, 0, "止まっていた間のピークを持ち越している")
    }

    /// 行が抱えている高さも捨てる。残ると、次のフレームが届くまで止まる前の高さが見える。
    func testRowHeightHeldFromBeforeIsClearedWhenVisibleAgain() {
        let store = MixerLevelStore(slotCount: 4)
        let clock = makeClock(levelStore: store)
        let view = MixerRowLayerView(gain: 1, muted: false, enabled: true, clock: clock)
        withExtendedLifetime(view) {
            clock.active = true
            clock.add(view)
            view.clientIDs = [7]

            store.beginFold(tableGeneration: 1)
            store.foldSlot(
                index: 0, clientID: 7, processID: 501, outputCycleSeq: 1,
                clipEventCount: 0, peak: 0.9, appliedGain: 1
            )
            clock.tick()
            XCTAssertGreaterThan(view.smoothedRatio, 0, "鳴っている行が振れていないので、以降の判定は成り立たない")

            clock.active = false
            clock.active = true
            XCTAssertEqual(view.smoothedRatio, 0, "止まる前の高さが残っている")
        }
    }

    /// 点灯は 1 フレームで消えるため、その 1 フレームだけを進めて見る。
    func testClipCountAccumulatedWhileStoppedDoesNotLightTheFirstFrame() {
        let store = MixerLevelStore(slotCount: 4)
        let clock = makeClock(levelStore: store)
        resumeAfterFolding(clock: clock, store: store)

        clock.tick()
        XCTAssertFalse(clock.level(forClientIDs: [7]).clipped, "止まっていた間のクリップを持ち越している")
    }
}
