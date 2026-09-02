import Foundation
import SimpleEQRingC

/// ミキサーのチャンネル (行) の規約。
enum MixerSpec {
    static let maxChannelCount = 30

    /// 永続化キーの前置き。共有ヘッダの突き合わせキーとは別に持つ (保存値であり、ドライバ側の
    /// 都合で動かさない)。
    static let bundleKeyPrefix = "bundle:"
    static let processKeyPrefix = "proc:"

    static func bundleKey(_ bundleID: String) -> String { bundleKeyPrefix + bundleID }
    static func processKey(_ executableName: String) -> String { processKeyPrefix + executableName }

    static func bundleID(inKey key: String) -> String? { body(of: key, after: bundleKeyPrefix) }
    static func processName(inKey key: String) -> String? { body(of: key, after: processKeyPrefix) }

    static func isValidKey(_ key: String) -> Bool {
        bundleID(inKey: key) != nil || processName(inKey: key) != nil
    }

    private static func body(of key: String, after prefix: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let body = String(key.dropFirst(prefix.count))
        return body.isEmpty ? nil : body
    }

    // MARK: - 初期セット

    /// 表示名もアイコンも持たない。腐る面をバンドル ID が変わったときだけに絞るため。
    static let initialSeedBundleIDs = [
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.QuickTimePlayerX",
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos",
        "com.hnc.Discord",
    ]

    static func initialSeedChannelKeys(isInstalled: (String) -> Bool) -> [String] {
        initialSeedBundleIDs.filter(isInstalled).map(bundleKey)
    }

    // MARK: - 突き合わせキー

    /// ドライバとアプリが同じ規則で作る鍵。組み立ては共有ヘッダの関数だけが行う。
    static func matchKey(bundleID: String, processID: UInt32) -> String? {
        let capacity = Int(simpleeq_mixer_match_key_max_bytes())
        var storage = [CChar](repeating: 0, count: capacity)
        let built = storage.withUnsafeMutableBufferPointer { out -> Bool in
            guard let base = out.baseAddress else { return false }
            if bundleID.isEmpty {
                return simpleeq_mixer_build_match_key(base, capacity, nil, processID)
            }
            return bundleID.withCString { simpleeq_mixer_build_match_key(base, capacity, $0, processID) }
        }
        guard built else { return nil }
        return storage.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// ミキサーのゲイン軸。減衰のみ (上限 0dB)。段を等幅で並べるため、指の移動量あたりの段数は
/// 全域で一定になり、0dB 付近ほど 1 段の dB が小さくなる。
/// ビジュアライザの表示下限とは無関係にミキサー専用に持つ。
enum MixerGainScale {
    static let floorDb: Double = -50
    static let unityGain: Double = 1
    static let silentGain: Double = 0

    /// 0dB 側から下限へ向かって、どこまでをどの刻みで刻むか。
    static let bands: [(untilDb: Double, step: Double)] = [(-2, 0.1), (-10, 0.5), (floorDb, 1)]

    /// 下限から 0dB までの段の値。位置はこの並びの上に等間隔で載る。
    static let detentsDb: [Double] = {
        var values: [Double] = [0]
        var db = 0.0
        for band in bands {
            while db - band.step >= band.untilDb - 1e-9 {
                db -= band.step
                values.append((db * 10).rounded() / 10)
            }
        }
        return values.reversed()
    }()

    static var stepCount: Int { detentsDb.count }

    static func snappedDb(_ db: Double) -> Double {
        detentsDb[detentIndex(ofDb: db)]
    }

    static func db(atPosition position: Double) -> Double {
        let p = min(1, max(0, position))
        return detentsDb[Int((p * Double(stepCount - 1)).rounded())]
    }

    static func position(ofDb db: Double) -> Double {
        Double(detentIndex(ofDb: db)) / Double(stepCount - 1)
    }

    private static func detentIndex(ofDb db: Double) -> Int {
        let clamped = min(0, max(floorDb, db))
        var nearest = 0
        for (index, value) in detentsDb.enumerated()
        where abs(value - clamped) < abs(detentsDb[nearest] - clamped) {
            nearest = index
        }
        return nearest
    }

    /// 最下端は 0dB 刻みの延長ではなく無音 (線形 0) の別状態。
    static func gain(atPosition position: Double) -> Double {
        position <= 0 ? silentGain : pow(10, db(atPosition: position) / 20)
    }

    static func position(ofGain gain: Double) -> Double {
        gain <= 0 ? 0 : position(ofDb: 20 * log10(gain))
    }

    /// 外から読んだ値を、そのまま使ってよい値へ揃える。
    static func normalizedGain(_ gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return silentGain }
        guard gain < unityGain else { return unityGain }
        let db = 20 * log10(gain)
        guard let bottomStep = bands.last?.step, db >= floorDb - bottomStep / 2 else { return silentGain }
        return pow(10, snappedDb(db) / 20)
    }

    static let silentText = "−∞"
    static let mutedText = "——"

    /// 0.1 の帯を持つため小数第一位まで出す。桁が固定されることで値の幅もぶれない。
    static func text(forGain gain: Double) -> String {
        guard gain > 0 else { return silentText }
        return String(format: "%.1f dB", snappedDb(20 * log10(gain)))
    }
}
