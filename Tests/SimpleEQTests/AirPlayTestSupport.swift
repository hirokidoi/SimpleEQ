import CoreAudio
import Foundation
@testable import SimpleEQ

/// CoreAudio の資源を持たない取り込み経路。リングだけを本物で持つ。
/// この代役へ触れる経路は直列キューが順序を作るため、同時に触れることが無い。
final class FakeCaptureSource: AirPlayCaptureSource, @unchecked Sendable {
    let ring: CaptureRing
    let sampleRate: Double
    let endpointUID: String
    let endpointDeviceID: AudioDeviceID
    let ioBufferFrames: Int
    var startShouldSucceed = true
    var sampleRateReading: Double?
    var onDestroy: (() -> Void)?
    private(set) var startCount = 0
    private(set) var destroyCount = 0

    init(endpointUID: String = "airplay-uid", endpointDeviceID: AudioDeviceID = 150, sampleRate: Double = 44100, ioBufferFrames: Int = 512) {
        ring = CaptureRing(sampleRate: sampleRate)
        self.sampleRate = sampleRate
        self.endpointUID = endpointUID
        self.endpointDeviceID = endpointDeviceID
        self.ioBufferFrames = ioBufferFrames
        sampleRateReading = sampleRate
    }

    func currentSampleRate(_ token: AudioWorldToken) -> Double? { sampleRateReading }

    @discardableResult
    func start(_ token: AudioWorldToken) -> Bool {
        startCount += 1
        return startShouldSucceed
    }

    func destroy(_ token: AudioWorldToken) {
        destroyCount += 1
        onDestroy?()
    }
}
