import CoreAudio
import Foundation

enum DriverSampleRatePolicy {
    /// ドライバへ依頼するレート。依頼が要らなければ nil。
    static func rateToRequest(
        outputRate: Double?, driverRate: Double?, driverAvailableRates: [ClosedRange<Double>], requestedRate: Double?
    ) -> Double? {
        guard let outputRate, outputRate > 0, let driverRate, driverRate > 0 else { return nil }
        guard driverAvailableRates.contains(where: { $0.contains(outputRate) }) else { return nil }
        guard outputRate != (requestedRate ?? driverRate) else { return nil }
        return outputRate
    }
}

/// レート追従の判断が読み書きする先。テストが CoreAudio に触れずに判断を駆動できるよう差し替え可能にする。
protocol DriverSampleRateFollowerPort {
    /// 門を通らなければ nil (そのときは一覧を読まない)。
    func readDriver() -> DriverSampleRateFollower.DriverReading?
    /// 出力先の申告をそのレートで読み直した合計。
    func declaredLatencyTotal(at rate: Double) -> Int
    func writeDeclaredLatency(_ frames: Int)
    func writeDriverRate(_ rate: Double) -> Bool
}

/// ドライバのレートを出力先に合わせる判断。
struct DriverSampleRateFollower {
    struct DriverReading {
        let rate: Double
        let availableRates: [ClosedRange<Double>]
    }

    private struct Request {
        let rate: Double
        /// 依頼を出した周では手放さないための印。
        var passedPeriodicPass = false
    }

    /// ドライバの公称値は構成変更が済むまで旧値を返すため、依頼中の値を別に持つ。
    private var requested: Request?
    /// 周期パスの追従の起点。直前の判定で読んだ出力先のレート。
    private var decisionOutputRate: Double?

    /// 依頼中は、ドライバが行き先のレートでの申告を持っているので、追従以外の申告を書かない。
    var holdsDeclarations: Bool { requested != nil }

    /// 出力先が決まった地点。appliedTotal は適用中のレートでの申告の合計。
    mutating func decide(outputRate: Double?, appliedTotal: Int, port: some DriverSampleRateFollowerPort) {
        let target = rateToRequest(outputRate: outputRate, port: port)
        guard let headed = target ?? requested?.rate else {
            port.writeDeclaredLatency(appliedTotal)
            return
        }
        if let target {
            request(target, appliedTotal: appliedTotal, port: port)
        } else {
            port.writeDeclaredLatency(port.declaredLatencyTotal(at: headed))
        }
    }

    /// 周期パスを 1 回越えても反映されない依頼は届かないものとして手放す (再依頼はしない)。
    mutating func periodicPassDidBegin() {
        if requested?.passedPeriodicPass == true {
            requested = nil
        } else {
            requested?.passedPeriodicPass = true
        }
    }

    mutating func followOutputRate(_ outputRate: Double?, appliedTotal: Int?, port: some DriverSampleRateFollowerPort) {
        guard outputRate != decisionOutputRate, let target = rateToRequest(outputRate: outputRate, port: port) else { return }
        request(target, appliedTotal: appliedTotal, port: port)
    }

    /// 届いたか追い越されたかに関わらず決着とする。ここから依頼はしない (ドライバ側の変更を起点にすると外部の変更と書き合う)。
    mutating func driverRateDidChange() {
        requested = nil
    }

    mutating func reset() {
        requested = nil
        decisionOutputRate = nil
    }

    private mutating func rateToRequest(outputRate: Double?, port: some DriverSampleRateFollowerPort) -> Double? {
        guard let driver = port.readDriver() else {
            decisionOutputRate = nil
            return nil
        }
        // ドライバ側が読めなかった判定は起点に残さず、次の周に判定し直す。
        decisionOutputRate = driver.availableRates.isEmpty || driver.rate <= 0 ? nil : outputRate
        return DriverSampleRatePolicy.rateToRequest(
            outputRate: outputRate, driverRate: driver.rate,
            driverAvailableRates: driver.availableRates, requestedRate: requested?.rate
        )
    }

    /// 申告はレートの変更で出力を開き直すプレーヤーが読むので、レートより先に置く。
    /// 依頼が拒否されたら、申告をこの依頼の前の行き先の値へ戻す。
    private mutating func request(_ rate: Double, appliedTotal: Int?, port: some DriverSampleRateFollowerPort) {
        port.writeDeclaredLatency(port.declaredLatencyTotal(at: rate))
        if port.writeDriverRate(rate) {
            requested = Request(rate: rate)
        } else if let pending = requested?.rate {
            port.writeDeclaredLatency(port.declaredLatencyTotal(at: pending))
        } else if let appliedTotal {
            port.writeDeclaredLatency(appliedTotal)
        }
    }
}

/// デバイスの公称レートの読み書き。テストが実機のドライバへ書かないよう差し替え可能にする。
protocol DeviceSampleRateIO: Sendable {
    func nominalRate(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Double?
    func availableNominalRates(_ id: AudioDeviceID, _ token: AudioWorldToken) -> [ClosedRange<Double>]
    func writeNominalRate(_ rate: Double, _ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool
}

final class CoreAudioDeviceSampleRateIO: DeviceSampleRateIO {
    func nominalRate(_ id: AudioDeviceID, _ token: AudioWorldToken) -> Double? {
        nominalSampleRate(id, token)
    }

    func availableNominalRates(_ id: AudioDeviceID, _ token: AudioWorldToken) -> [ClosedRange<Double>] {
        availableNominalSampleRates(id, token)
    }

    func writeNominalRate(_ rate: Double, _ id: AudioDeviceID, _ token: AudioWorldToken) -> Bool {
        setNominalSampleRate(id, rate, token)
    }
}
