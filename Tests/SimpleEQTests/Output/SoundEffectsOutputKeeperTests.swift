import XCTest
import CoreAudio
@testable import SimpleEQ

final class SoundEffectsOutputKeeperTests: XCTestCase {
    private let driverUID = "driver-device-uid"
    private static let driverID: AudioDeviceID = 40
    private var driverID: AudioDeviceID { Self.driverID }
    private let speakerUID = "speaker-uid"
    private static let speakerID: AudioDeviceID = 10
    private var speakerID: AudioDeviceID { Self.speakerID }
    private let hdmiUID = "hdmi-uid"
    private let hdmiID: AudioDeviceID = 11
    /// どのデバイスとも対応しない ID。
    private let unresolvableID: AudioDeviceID = 99

    private struct Fixture {
        let keeper: SoundEffectsOutputKeeper
        let directory: MockAudioDeviceDirectory
        let scheduler: ManualRoutingScheduler
    }

    private func makeFixture(systemOutputID: AudioDeviceID? = speakerID) -> Fixture {
        let directory = MockAudioDeviceDirectory()
        directory.deviceIDsByUID = [driverUID: driverID, speakerUID: speakerID, hdmiUID: hdmiID]
        directory.uidsByDeviceID = [driverID: driverUID, speakerID: speakerUID, hdmiID: hdmiUID]
        directory.currentDefaultSystemOutputID = systemOutputID
        directory.currentDefaultOutputID = driverID
        let scheduler = ManualRoutingScheduler()
        let keeper = SoundEffectsOutputKeeper(
            directory: directory, audioWorld: makeTestAudioWorld(), driverDeviceUID: driverUID,
            schedule: scheduler.schedule
        )
        return Fixture(keeper: keeper, directory: directory, scheduler: scheduler)
    }

    private func moveSystemOutput(of f: Fixture, to id: AudioDeviceID) {
        f.directory.currentDefaultSystemOutputID = id
        f.keeper.soundEffectsOutputDidChange(testToken)
    }

    func testPutsTheSoundEffectsOutputBackWhenItMovesToTheDriverWithinTheWindow() {
        let f = makeFixture()
        XCTAssertTrue(f.keeper.keepingSoundEffectsOutput(across: { true }, testToken))

        moveSystemOutput(of: f, to: driverID)

        XCTAssertEqual(f.directory.setDefaultSystemOutputCalls, [speakerID])
    }

    func testLeavesAMoveAfterTheWindowAndStopsWatching() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        f.scheduler.fire()

        f.directory.currentDefaultSystemOutputID = driverID
        let readsBefore = f.directory.defaultSystemOutputReadCount
        f.keeper.soundEffectsOutputDidChange(testToken)

        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
        XCTAssertEqual(f.directory.defaultSystemOutputReadCount, readsBefore, "保持が無ければ読みにも行かない")
        XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 1)
        XCTAssertEqual(f.directory.removedDefaultSystemOutputListenerCount, 1)
    }

    func testStillHoldsTheSoundEffectsOutputWhileTheDefaultOutputCannotBeRead() {
        for defaultOutputID in [nil, unresolvableID] {
            let f = makeFixture()
            f.directory.currentDefaultOutputID = defaultOutputID
            f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)

            moveSystemOutput(of: f, to: driverID)

            XCTAssertEqual(f.directory.setDefaultSystemOutputCalls, [speakerID], "既定出力 \(String(describing: defaultOutputID))")
        }
    }

    func testHoldsNothingWhenTheSoundEffectsOutputIsTheDefaultOutput() {
        let f = makeFixture(systemOutputID: hdmiID)
        f.directory.currentDefaultOutputID = hdmiID
        var claimed = 0

        f.keeper.keepingSoundEffectsOutput(across: { claimed += 1; return true }, testToken)
        moveSystemOutput(of: f, to: driverID)

        XCTAssertEqual(claimed, 1, "名乗りは実行される")
        XCTAssertGreaterThan(f.directory.defaultSystemOutputReadCount, 0, "判定へ到達していること")
        XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 0)
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testHoldsNothingWhenTheSoundEffectsOutputWasAlreadyTheDriver() {
        let f = makeFixture(systemOutputID: driverID)
        var claimed = 0

        f.keeper.keepingSoundEffectsOutput(across: { claimed += 1; return true }, testToken)
        moveSystemOutput(of: f, to: driverID)

        XCTAssertEqual(claimed, 1, "名乗りは実行される")
        XCTAssertGreaterThan(f.directory.defaultSystemOutputReadCount, 0, "判定へ到達していること")
        XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 0)
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testHoldsNothingWhenTheSoundEffectsOutputCannotBeRead() {
        for readable in [false, true] {
            let f = makeFixture(systemOutputID: readable ? unresolvableID : nil)
            var claimed = 0

            f.keeper.keepingSoundEffectsOutput(across: { claimed += 1; return true }, testToken)

            let label = readable ? "ID は読めるが UID に解決できない" : "ID が読めない"
            XCTAssertEqual(claimed, 1, "名乗りは実行される: \(label)")
            XCTAssertGreaterThan(f.directory.defaultSystemOutputReadCount, 0, "判定へ到達していること: \(label)")
            XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 0, label)
        }
    }

    func testDoesNothingWhenTheHeldDeviceCanNoLongerBeResolved() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        f.directory.deviceIDsByUID[speakerUID] = nil
        f.directory.resetCallRecords()

        moveSystemOutput(of: f, to: driverID)

        XCTAssertTrue(f.directory.deviceIDByUIDCalls.contains(speakerUID), "解決まで到達していること")
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testLeavesAMoveToADeviceOtherThanTheDriver() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        f.directory.resetCallRecords()

        moveSystemOutput(of: f, to: hdmiID)

        XCTAssertGreaterThan(f.directory.defaultSystemOutputReadCount, 0, "判定へ到達していること")
        XCTAssertTrue(f.directory.deviceIDByUIDCalls.isEmpty, "戻す手前で止まる")
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testReleasesTheWatchAtOnceAndSchedulesNothingWhenTheClaimFails() {
        let f = makeFixture()
        let scheduledBefore = f.scheduler.scheduleCallCount

        XCTAssertFalse(f.keeper.keepingSoundEffectsOutput(across: { false }, testToken))
        moveSystemOutput(of: f, to: driverID)

        XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 1)
        XCTAssertEqual(f.directory.removedDefaultSystemOutputListenerCount, 1)
        XCTAssertEqual(f.scheduler.scheduleCallCount, scheduledBefore)
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testClaimingAgainWithinTheWindowKeepsTheFirstHeldDeviceAndRestartsTheWindow() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        f.directory.currentDefaultSystemOutputID = driverID

        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        f.scheduler.fireNext()

        XCTAssertEqual(f.directory.addedDefaultSystemOutputListenerCount, 1, "購読は 1 つのまま")
        XCTAssertEqual(f.directory.removedDefaultSystemOutputListenerCount, 0, "1 回目の終わりでは窓は閉じない")
        f.keeper.soundEffectsOutputDidChange(testToken)
        XCTAssertEqual(f.directory.setDefaultSystemOutputCalls, [speakerID], "最初に覚えた装置へ戻す")

        f.scheduler.fireNext()
        XCTAssertEqual(f.directory.removedDefaultSystemOutputListenerCount, 1, "2 回目の終わりで閉じる")
    }

    func testDoesNotWriteAgainOnTheNotificationCausedByItsOwnWrite() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)
        moveSystemOutput(of: f, to: driverID)

        f.directory.resetCallRecords()
        f.keeper.soundEffectsOutputDidChange(testToken)

        XCTAssertGreaterThan(f.directory.defaultSystemOutputReadCount, 0, "判定へ到達していること")
        XCTAssertTrue(f.directory.setDefaultSystemOutputCalls.isEmpty)
    }

    func testSubscribesAndReadsBeforeTheClaimIsWritten() {
        let f = makeFixture()
        var observed: (added: Int, reads: Int)?

        f.keeper.keepingSoundEffectsOutput(across: {
            observed = (f.directory.addedDefaultSystemOutputListenerCount, f.directory.defaultSystemOutputReadCount)
            return true
        }, testToken)

        XCTAssertEqual(observed?.added, 1)
        XCTAssertGreaterThanOrEqual(observed?.reads ?? 0, 1)
    }

    func testPutsTheSoundEffectsOutputBackEachTimeItMovesToTheDriverWithinTheWindow() {
        let f = makeFixture()
        f.keeper.keepingSoundEffectsOutput(across: { true }, testToken)

        moveSystemOutput(of: f, to: driverID)
        moveSystemOutput(of: f, to: driverID)

        XCTAssertEqual(f.directory.setDefaultSystemOutputCalls, [speakerID, speakerID])
    }
}
