import Foundation

/// EQ プリセットの枠識別子。5 枠固定、UI のプリセットボタン・選択状態と共有する。
/// ケース名自体に意味は持たせない (枠の位置のみを表す)。
enum EQPreset: String, CaseIterable {
    case slot1
    case slot2
    case slot3
    case slot4
    case slot5
}

/// UI と音声エンジンが共有する EQ 仕様の定数。
enum EQSpec {
    /// 各バンドの中心周波数 (Hz)。UI の列描画と AUNBandEQ の各バンド周波数設定の両方の源。
    static let FREQS: [Double] = [
        22, 31.5, 44, 63, 87, 125, 175, 250, 350, 500,
        700, 1000, 1400, 2000, 2800, 4000, 5600, 8000, 11000, 16000
    ]

    /// バンド数。FREQS から導出 (ハードコード禁止)。
    static let bandCount = FREQS.count

    /// EQ ゲインの範囲 (dB)。0 = フラット。
    static let DB_MIN: Double = -12
    static let DB_MAX: Double = 12

    struct PresetSeed: Equatable {
        let title: String
        let curve: [Double]
    }

    /// slot4/slot5 はエントリを持たず、それ自体が「組み込みを持たない空スロット」を表す。
    static let builtInSeeds: [EQPreset: PresetSeed] = [
        .slot1: PresetSeed(title: "Flat",              curve: Array(repeating: 0, count: bandCount)),
        .slot2: PresetSeed(title: "Perfect",           curve: [-6, -3, -1, 1, 2, 3, 2, 1, 0, -1, -2, -1, 0, 1, 2, 3, 4, 6, 4, 2]),
        .slot3: PresetSeed(title: "Eargasm Explosion", curve: [-6, -3, -1, 1, 2, 3, 2, 1, 0, -1, -2, -1, 0, 1, 2, 0, -3, 6, 4, 2]),
    ]

    /// ゲインを DB_MIN...DB_MAX の範囲へ丸める。
    static func clampDb(_ db: Double) -> Double {
        min(DB_MAX, max(DB_MIN, db))
    }
}
