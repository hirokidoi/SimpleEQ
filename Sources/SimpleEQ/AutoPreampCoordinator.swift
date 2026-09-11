import Dispatch
import Foundation

/// 既定の measure と既定の runMeasurement は組でしか使わないこと。片方だけ差し替えると、
/// 測定を閉じ込めたキューの外から測定器に触れる経路ができる。
@MainActor
final class AutoPreampCoordinator {
    /// 導出結果が確定するたびに呼ばれる (適用は呼び出し側の責務)。
    var didDerive: ((Double) -> Void)?

    /// 設計値 (実測から選定)。
    static let defaultCacheCapacity = 16

    private static let measurementQueue = DispatchQueue(label: "com.simpleeq.autopreamp.measurement", qos: .utility)

    private let measure: @Sendable ([Double], Double, MeasuredSoundLab) -> AutoPreampResponse?
    private let runMeasurement: (@escaping @Sendable () -> Void) -> Void
    private let deliver: @Sendable (@escaping @MainActor () -> Void) -> Void

    private var current: Input?
    private var memo: Memo?
    private var responses: ResponseCache
    private var pendingDerivation: PendingRequest?
    private var pendingPreview: PendingRequest?
    private var measuring = false

    private struct Input: Equatable {
        let curve: [Double]
        let sampleRate: Double
        let targetDb: Double
        let soundLab: MeasuredSoundLab
    }

    private struct Memo: Equatable {
        let input: Input
        let appliedPreampDb: Double
    }

    private struct ResponseKey: Hashable {
        let curve: [Double]
        let sampleRate: Double
        let soundLab: MeasuredSoundLab
    }

    private struct PendingRequest {
        let curve: [Double]
        let sampleRate: Double
        let soundLab: MeasuredSoundLab
    }

    /// 既定引数は呼び出し側 (main) で評価されるため、CoreAudio 資源の生成を初回の測定まで遅らせる。
    private final class LazyProbeBox: @unchecked Sendable {
        var eq: EQResponseProbe?
        var stereo: SoundLabStereoProbe?
        var stereoSampleRate: Double?
    }

    init(
        measure: @escaping @Sendable ([Double], Double, MeasuredSoundLab) -> AutoPreampResponse? = AutoPreampCoordinator.makeDefaultMeasure(),
        runMeasurement: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            AutoPreampCoordinator.measurementQueue.async(execute: work)
        },
        deliver: @escaping @Sendable (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { work() }
        },
        cacheCapacity: Int = AutoPreampCoordinator.defaultCacheCapacity
    ) {
        self.measure = measure
        self.runMeasurement = runMeasurement
        self.deliver = deliver
        self.responses = ResponseCache(capacity: cacheCapacity)
    }

    static func makeDefaultMeasure() -> @Sendable ([Double], Double, MeasuredSoundLab) -> AutoPreampResponse? {
        let box = LazyProbeBox()
        return { curve, sampleRate, soundLab in
            if box.eq == nil { box.eq = EQResponseProbe() }
            guard let eq = box.eq?.measure(curve: curve, sampleRate: sampleRate) else { return nil }
            guard soundLab.anyEnabled else { return AutoPreampResponse(eq: eq) }
            if box.stereo == nil || box.stereoSampleRate != sampleRate {
                box.stereo = SoundLabStereoProbe(sampleRate: sampleRate)
                box.stereoSampleRate = sampleRate
            }
            guard let stereo = box.stereo?.measure(
                expander: soundLab.stereoExpander, bass: soundLab.bassHarmonics, exciter: soundLab.trebleExciter
            ) else { return AutoPreampResponse(eq: eq) }
            return AutoPreampResponse(eq: eq, soundLab: stereo)
        }
    }

    func refresh(
        enabled: Bool, curve: [Double], targetDb: Double, sampleRate: Double,
        soundLab: SoundLabSettings, currentPreampDb: Double
    ) {
        guard enabled else {
            current = nil
            pendingDerivation = nil
            pendingPreview = nil
            return
        }
        // 勘定に入れる機能だけを入口で取り出す。以降のキーも保留もこの形で持つ。
        let soundLab = MeasuredSoundLab(soundLab)
        let input = Input(curve: curve, sampleRate: sampleRate, targetDb: targetDb, soundLab: soundLab)
        current = input
        // 保留は 1 つ前の入力に対するもので、入力が動いた時点で用済みになる。
        pendingDerivation = nil
        guard memo != Memo(input: input, appliedPreampDb: currentPreampDb) else { return }

        if let response = responses.value(for: ResponseKey(curve: curve, sampleRate: sampleRate, soundLab: soundLab)) {
            apply(AutoPreampSpec.derivedPreampDb(response: response, targetDb: targetDb), for: input)
            return
        }
        pendingDerivation = PendingRequest(curve: curve, sampleRate: sampleRate, soundLab: soundLab)
        startMeasurementIfIdle()
    }

    /// 適用を伴わない問い合わせ。
    func previewPreampDb(
        curve: [Double], targetDb: Double, sampleRate: Double,
        soundLab: SoundLabSettings, measureIfMissing: Bool
    ) -> Double? {
        let soundLab = MeasuredSoundLab(soundLab)
        let key = ResponseKey(curve: curve, sampleRate: sampleRate, soundLab: soundLab)
        if let response = responses.value(for: key) {
            return AutoPreampSpec.derivedPreampDb(response: response, targetDb: targetDb)
        }
        guard measureIfMissing else { return nil }
        pendingPreview = PendingRequest(curve: curve, sampleRate: sampleRate, soundLab: soundLab)
        startMeasurementIfIdle()
        return nil
    }

    private func apply(_ preampDb: Double, for input: Input) {
        memo = Memo(input: input, appliedPreampDb: preampDb)
        didDerive?(preampDb)
    }

    private func resolveCurrentInputIfCached() {
        guard let input = current,
              let response = responses.value(for: ResponseKey(
                  curve: input.curve, sampleRate: input.sampleRate, soundLab: input.soundLab))
        else { return }
        let preampDb = AutoPreampSpec.derivedPreampDb(response: response, targetDb: input.targetDb)
        guard memo != Memo(input: input, appliedPreampDb: preampDb) else { return }
        apply(preampDb, for: input)
    }

    /// 導出を優先する。プレビューの問い合わせが未処理の導出要求を押し出さないため。
    private func startMeasurementIfIdle() {
        guard !measuring else { return }
        guard let request = pendingDerivation ?? pendingPreview else { return }
        if pendingDerivation != nil { pendingDerivation = nil } else { pendingPreview = nil }

        let key = ResponseKey(curve: request.curve, sampleRate: request.sampleRate, soundLab: request.soundLab)
        if responses.value(for: key) != nil {
            // 保留に積まれてから実行されるまでの間に、別の測定の完了で同じキーが埋まっていることがある。
            resolveCurrentInputIfCached()
            startMeasurementIfIdle()
            return
        }

        measuring = true
        let curve = request.curve
        let sampleRate = request.sampleRate
        let soundLab = request.soundLab
        let measure = self.measure
        let deliver = self.deliver
        runMeasurement { [weak self] in
            let result = measure(curve, sampleRate, soundLab)
            deliver {
                self?.completeMeasurement(
                    curve: curve, sampleRate: sampleRate, soundLab: soundLab, result: result
                )
            }
        }
    }

    private func completeMeasurement(
        curve: [Double], sampleRate: Double, soundLab: MeasuredSoundLab, result: AutoPreampResponse?
    ) {
        measuring = false
        // 測定失敗時は値を据え置き、再試行しない (次の入力変化で自然に再挑戦する)。
        if let result {
            responses.insert(result, for: ResponseKey(curve: curve, sampleRate: sampleRate, soundLab: soundLab))
        }
        resolveCurrentInputIfCached()
        startMeasurementIfIdle()
    }

    private struct ResponseCache {
        private let capacity: Int
        private var storage: [ResponseKey: AutoPreampResponse] = [:]
        /// 先頭が最も古い。
        private var order: [ResponseKey] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        mutating func value(for key: ResponseKey) -> AutoPreampResponse? {
            guard let value = storage[key] else { return nil }
            touch(key)
            return value
        }

        mutating func insert(_ value: AutoPreampResponse, for key: ResponseKey) {
            storage[key] = value
            touch(key)
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }

        private mutating func touch(_ key: ResponseKey) {
            order.removeAll { $0 == key }
            order.append(key)
        }
    }
}
