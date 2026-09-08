import AudioToolbox

/// ライブシミュレーターの空間。
enum LiveSimulationRoom: String, CaseIterable, Codable, Sendable {
    case musicBar
    case club
    case festival
    case dome

    var title: String {
        switch self {
        case .musicBar: return "Music Bar"
        case .club: return "Club"
        case .festival: return "Festival"
        case .dome: return "Dome"
        }
    }

    var reverbRoomType: AUReverbRoomType {
        switch self {
        case .musicBar: return .reverbRoomType_SmallRoom
        case .club: return .reverbRoomType_MediumRoom
        case .festival: return .reverbRoomType_LargeRoom2
        case .dome: return .reverbRoomType_LargeHall
        }
    }
}

/// Sound Lab の機能。一覧の並び順と、機能まるごとの入り切りの在り処を兼ねる。
enum SoundLabFeature: CaseIterable, Sendable {
    case liveSimulation
    case stereoExpander
    case bassHarmonics
    case trebleExciter
    case loudness

    var title: String {
        switch self {
        case .liveSimulation: return "ライブシミュレーター"
        case .stereoExpander: return "ステレオエクスパンダー"
        case .bassHarmonics: return "ベースハーモニクス"
        case .trebleExciter: return "トレブルエキサイター"
        case .loudness: return "ラウドネス"
        }
    }

    /// タブに出す名前。
    var tabTitle: String {
        switch self {
        case .liveSimulation: return "Live Simulator"
        case .stereoExpander: return "Stereo Expander"
        case .bassHarmonics: return "Bass Harmonics"
        case .trebleExciter: return "Treble Exciter"
        case .loudness: return "Loudness"
        }
    }

    var summary: String {
        switch self {
        case .liveSimulation: return "空間の響きを加える"
        case .stereoExpander: return "音像を左右に広げる"
        case .bassHarmonics: return "低音の倍音を作って量感を足す"
        case .trebleExciter: return "高域に倍音を足して輪郭を出す"
        case .loudness: return "音量が小さいときだけ低域と高域を補う"
        }
    }

    var enabledKeyPath: WritableKeyPath<SoundLabSettings, Bool> {
        switch self {
        case .liveSimulation: return \.liveSimulation.enabled
        case .stereoExpander: return \.stereoExpander.enabled
        case .bassHarmonics: return \.bassHarmonics.enabled
        case .trebleExciter: return \.trebleExciter.enabled
        case .loudness: return \.loudness.enabled
        }
    }
}

/// 機能をまたいで使う道具。範囲そのものは各機能の型が持つ。
enum SoundLabSpec {
    struct Range {
        let bounds: ClosedRange<Double>
        let step: Double
        let defaultValue: Double
    }

    /// 外から読んだ値を、そのまま使ってよい値へ揃える。
    /// 刻みには寄せない。既定値が刻みに乗っていても、丸めで別の値になりうるため。
    static func clamped(_ value: Double, to range: Range) -> Double {
        min(range.bounds.upperBound, max(range.bounds.lowerBound, value))
    }

    /// 一次フィルタの係数。周波数が高いほど 0 に近づく。
    static func onePoleCoefficient(frequency: Double, sampleRate: Double) -> Float {
        Float(exp(-2 * Double.pi * frequency / sampleRate))
    }

    static func linearGain(db: Double) -> Double { pow(10, db / 20) }
}

/// AU 段が受け持つ。
struct LiveSimulationSettings: Hashable, Codable, Sendable {
    static let mixRange = SoundLabSpec.Range(bounds: 0...100, step: 5, defaultValue: 10)

    var enabled = false
    var room: LiveSimulationRoom = .musicBar
    var mix = mixRange.defaultValue

    var normalized: LiveSimulationSettings {
        var s = self
        s.mix = SoundLabSpec.clamped(s.mix, to: Self.mixRange)
        return s
    }
}

/// ステレオ段が受け持つ。
struct StereoExpanderSettings: Hashable, Codable, Sendable {
    static let widthRange = SoundLabSpec.Range(bounds: 0...4, step: 0.1, defaultValue: 2.4)
    /// ここから上を広げる。下限まで下げると全帯域が対象になる。
    static let crossoverRange = SoundLabSpec.Range(bounds: 20...10000, step: 10, defaultValue: 5000)
    /// オールパスの段数。増やすほど位相の散らばりが大きくなる。
    static let diffusionStageCount = 4
    static let diffusionRange = SoundLabSpec.Range(bounds: 0...0.9, step: 0.05, defaultValue: 0.5)

    var enabled = false
    var width = widthRange.defaultValue
    var crossover = crossoverRange.defaultValue
    var diffusionEnabled = true
    var diffusionAmount = diffusionRange.defaultValue

    var normalized: StereoExpanderSettings {
        var s = self
        s.width = SoundLabSpec.clamped(s.width, to: Self.widthRange)
        s.crossover = SoundLabSpec.clamped(s.crossover, to: Self.crossoverRange)
        s.diffusionAmount = SoundLabSpec.clamped(s.diffusionAmount, to: Self.diffusionRange)
        return s
    }
}

/// ステレオ段が受け持つ。
struct BassHarmonicsSettings: Hashable, Codable, Sendable {
    /// 低音の基音から倍音を作る境目。
    static let cutoffRange = SoundLabSpec.Range(bounds: 40...200, step: 5, defaultValue: 100)
    static let driveRange = SoundLabSpec.Range(bounds: 1...20, step: 0.5, defaultValue: 6)
    static let mixRange = SoundLabSpec.Range(bounds: 0...100, step: 5, defaultValue: 30)

    var enabled = false
    var cutoff = cutoffRange.defaultValue
    var drive = driveRange.defaultValue
    var mix = mixRange.defaultValue

    var normalized: BassHarmonicsSettings {
        var s = self
        s.cutoff = SoundLabSpec.clamped(s.cutoff, to: Self.cutoffRange)
        s.drive = SoundLabSpec.clamped(s.drive, to: Self.driveRange)
        s.mix = SoundLabSpec.clamped(s.mix, to: Self.mixRange)
        return s
    }
}

/// ステレオ段が受け持つ。
struct TrebleExciterSettings: Hashable, Codable, Sendable {
    static let cutoffRange = SoundLabSpec.Range(bounds: 2000...12000, step: 500, defaultValue: 6000)
    static let driveRange = SoundLabSpec.Range(bounds: 1...20, step: 0.5, defaultValue: 6)
    static let mixRange = SoundLabSpec.Range(bounds: 0...100, step: 5, defaultValue: 20)

    var enabled = false
    var cutoff = cutoffRange.defaultValue
    var drive = driveRange.defaultValue
    var mix = mixRange.defaultValue

    var normalized: TrebleExciterSettings {
        var s = self
        s.cutoff = SoundLabSpec.clamped(s.cutoff, to: Self.cutoffRange)
        s.drive = SoundLabSpec.clamped(s.drive, to: Self.driveRange)
        s.mix = SoundLabSpec.clamped(s.mix, to: Self.mixRange)
        return s
    }
}

/// ラウドネス段が受け持つ。
struct LoudnessSettings: Hashable, Codable, Sendable {
    /// 音量が小さいときに持ち上げる量の上限。
    static let amountRange = SoundLabSpec.Range(bounds: 0...12, step: 0.5, defaultValue: 6)
    static let bassFrequencyRange = SoundLabSpec.Range(bounds: 60...300, step: 10, defaultValue: 150)
    static let trebleFrequencyRange = SoundLabSpec.Range(bounds: 2000...12000, step: 500, defaultValue: 6000)
    /// 空きが戻ったあと押し上げを回復させる時間。
    /// 伸ばすほどブロックごとの追従から素材全体の最小値へ寄る。
    static let headroomReleaseRange = SoundLabSpec.Range(bounds: 0.1...10, step: 0.1, defaultValue: 1.0)

    var enabled = false
    var amountDb = amountRange.defaultValue
    var bassFrequency = bassFrequencyRange.defaultValue
    var trebleFrequency = trebleFrequencyRange.defaultValue
    var headroomReleaseSeconds = headroomReleaseRange.defaultValue

    var normalized: LoudnessSettings {
        var s = self
        s.amountDb = SoundLabSpec.clamped(s.amountDb, to: Self.amountRange)
        s.bassFrequency = SoundLabSpec.clamped(s.bassFrequency, to: Self.bassFrequencyRange)
        s.trebleFrequency = SoundLabSpec.clamped(s.trebleFrequency, to: Self.trebleFrequencyRange)
        s.headroomReleaseSeconds = SoundLabSpec.clamped(s.headroomReleaseSeconds, to: Self.headroomReleaseRange)
        return s
    }
}

/// 5 機能の操作値。段へ配るときは、その段が受け持つぶんだけを渡す。
struct SoundLabSettings: Hashable, Codable, Sendable {
    var liveSimulation = LiveSimulationSettings()
    var stereoExpander = StereoExpanderSettings()
    var bassHarmonics = BassHarmonicsSettings()
    var trebleExciter = TrebleExciterSettings()
    var loudness = LoudnessSettings()

    /// 保存済みの値を読み込んだ直後に通す。
    var normalized: SoundLabSettings {
        SoundLabSettings(
            liveSimulation: liveSimulation.normalized,
            stereoExpander: stereoExpander.normalized,
            bassHarmonics: bassHarmonics.normalized,
            trebleExciter: trebleExciter.normalized,
            loudness: loudness.normalized
        )
    }
}
