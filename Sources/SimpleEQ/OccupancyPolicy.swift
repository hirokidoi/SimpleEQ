import Foundation

/// 共有メモリリングのバッファ量制御 (目標バッファ量・上限バッファ量・トリム保留時間の導出、上限超過時の経路判定) を
/// 担う純粋関数群。すべての入力を引数で受け取り副作用を持たない。実際の観測 (書き手のブロック長・
/// クライアント要求フレーム数の追跡、時刻の読み取り、カーソル操作) は呼び出し側の責務であり、
/// ここでは「値が与えられたら何を返すか」だけを持つ。
enum OccupancyPolicy {
    /// フィルタ構造上の量のためサンプルレートに依存しない (設計値)。
    private static let geometricDelayFrames = 8
    private static let renegotiationMarginFrames = 0
    /// 基準レートでの内訳フレーム数を秒へ換算した設計値。
    private static let writerJitterSeconds: TimeInterval = 60.0 / AudioConfig.baseSampleRate
    private static let readerJitterSeconds: TimeInterval = 60.0 / AudioConfig.baseSampleRate
    private static let acquisitionValleySeconds: TimeInterval = 48.0 / AudioConfig.baseSampleRate

    /// 書き込み・読み取り双方の位相ジッタと幾何遅延を積んだ、瞬時下限に対する余裕 (実行時の
    /// 観測値ではない)。
    static func minimumMarginFrames(sampleRate: Double) -> Int {
        geometricDelayFrames
            + Int((writerJitterSeconds * sampleRate).rounded(.up))
            + Int((readerJitterSeconds * sampleRate).rounded(.up))
            + renegotiationMarginFrames
            + Int((acquisitionValleySeconds * sampleRate).rounded(.up))
    }

    /// 実測値。
    static let readerStopWorstCaseSeconds: TimeInterval = 0.024

    /// N_p の推定が確定するまで仮に使う初期値。実際のブロック長は HAL が IO サイクルごとに決める
    /// ため一定しない。窓が閉じるまでの目標バッファ量を過大にしないための下寄りの見積もり (仮の値)。
    static let bootstrapWriterBlockFrames = 512

    /// 継ぎ目 (不連続の再同期のクロスフェード・出力段のフェード) に共通してかける時間。数msで
    /// 振幅の不連続を耳につかない水準まで均せる一方、長すぎると新旧が混ざった音の継続が不自然に
    /// なるため、両者のバランスから決めた設計値 (実測値ではない)。
    static let seamFadeSeconds: TimeInterval = 0.003

    static func seamFadeFrames(sampleRate: Double) -> Int {
        Int((seamFadeSeconds * sampleRate).rounded(.up))
    }

    /// 無音との継ぎ目で振幅を動かすのにかける時間。EQ が扱う最も低い帯域の周期より遅く動かす
    /// 必要がある (速いとその帯域にエネルギーが残る)。
    static var silenceSeamFadeSeconds: TimeInterval {
        guard let lowestBandHz = EQSpec.FREQS.min(), lowestBandHz > 0 else { return seamFadeSeconds }
        return 1 / lowestBandHz
    }

    static func silenceSeamFadeFrames(sampleRate: Double) -> Int {
        Int((silenceSeamFadeSeconds * sampleRate).rounded(.up))
    }

    /// 端点吸着の許容誤差の、歩幅 (1/totalFrames) に対する比率。歩幅の累積を浮動小数で行うと
    /// 端点ちょうどに一致しないため、歩幅より小さい比率で吸収する。
    private static let seamGainSnapEpsilonFractionOfStep: Float = 0.5

    /// 実データからゼロ埋めへ落ちる区間で毎フレーム呼び、フェード総フレーム数ぶんで 0 まで下げ止まる。
    static func fallingSeamGain(current: Float, totalFrames: Int) -> Float {
        let step = 1 / Float(max(1, totalFrames))
        let next = current - step
        let epsilon = step * seamGainSnapEpsilonFractionOfStep
        return next <= epsilon ? 0 : next
    }

    /// ゼロ埋めから実データへ戻る区間で毎フレーム呼び、フェード総フレーム数ぶんで 1 まで上げ止まる。
    static func risingSeamGain(current: Float, totalFrames: Int) -> Float {
        let step = 1 / Float(max(1, totalFrames))
        let next = current + step
        let epsilon = step * seamGainSnapEpsilonFractionOfStep
        return next >= 1 - epsilon ? 1 : next
    }

    /// 上限超過時の扱いを、原因によって 2 経路のどちらへ振り分けるかの判定結果。
    enum OverflowResponse: Equatable {
        /// 超過なし、または上限以下 (通常のバースト振幅の範囲)。
        case withinBounds
        /// 不連続 (読み手側の中断・出力先/段の切替などの内部事象) を原因とする即時の再同期。
        case immediateResync
        /// クロックドリフトの蓄積を原因とする、保留時間経過後のトリム。
        case sustainedDriftTrim
    }

    /// 目標バッファ量 o* = N_p + N_c + 瞬時下限の余裕、を N_p の倍数へ切り上げた値。プライミング完了時の
    /// バッファ量は N_p 単位でしか変化しないため、o* 自体を N_p の倍数に揃えることでバッファ量 0 から積み
    /// 上がる場合の着地が o* とちょうど一致する。
    static func targetOccupancyFrames(writerBlockFrames: Int, clientRequestFrames: Int, sampleRate: Double) -> Int {
        precondition(writerBlockFrames > 0, "writerBlockFrames must be positive")
        let required = writerBlockFrames + clientRequestFrames + minimumMarginFrames(sampleRate: sampleRate)
        let blocks = (required + writerBlockFrames - 1) / writerBlockFrames
        return blocks * writerBlockFrames
    }

    static func readerStopWorstCaseFrames(sampleRate: Double) -> Int {
        Int((readerStopWorstCaseSeconds * sampleRate).rounded(.up))
    }

    /// 読み手が最悪値ぶん停止しても、復帰した瞬間にその間の書き込みバックログが上限を超えたと
    /// 誤判定しないための余白。
    static func maxOccupancyFrames(targetOccupancyFrames: Int, writerBlockFrames: Int, sampleRate: Double) -> Int {
        targetOccupancyFrames + readerStopWorstCaseFrames(sampleRate: sampleRate) + writerBlockFrames
    }

    /// M_eff = o* − (N_p + N_c)。minimumMarginFrames(sampleRate:) 以上であることが構造的に
    /// 保たれるべき不変条件で、これを下回ると瞬時下限を割り込み部分読みが発生しうる。
    static func effectiveMarginFrames(targetOccupancyFrames: Int, writerBlockFrames: Int, clientRequestFrames: Int) -> Int {
        targetOccupancyFrames - (writerBlockFrames + clientRequestFrames)
    }

    /// T_trim = 補正ループが上限バッファ量から目標バッファ量まで最大レートで歩いて戻るのに要する時間。
    /// これより短い超過は通常の補正の権限内として待つ。
    static func trimHoldDuration(
        targetOccupancyFrames: Int, maxOccupancyFrames: Int,
        sampleRate: Double, driftCorrectionMaxRateFraction: Double
    ) -> TimeInterval {
        Double(maxOccupancyFrames - targetOccupancyFrames) / (driftCorrectionMaxRateFraction * sampleRate)
    }

    /// 読み手側コールバックの間隔が「不連続」とみなされる閾値 (秒)。読み手停止の最悪値に、
    /// クライアントの実要求フレーム数 1 回ぶんの時間を足す (通常のコールバック周期のジッタでは
    /// 超えない水準に、実際の停止だけが超える水準を置く)。
    static func discontinuityIntervalThreshold(clientRequestFrames: Int, sampleRate: Double) -> TimeInterval {
        readerStopWorstCaseSeconds + Double(clientRequestFrames) / sampleRate
    }

    /// 目標バッファ量を超えて溜まっているぶん (破棄対象フレーム数)。0 以下なら破棄不要。
    static func framesToDiscard(available: Int, targetOccupancyFrames: Int) -> Int {
        max(0, available - targetOccupancyFrames)
    }

    /// 導出された目標バッファ量が (N_p または N_c の増加により) 拡大し、かつ現在のバッファ量がまだ新しい
    /// 目標に達していないなら、消費を止めて目標へ再度満ちるまで待つ (再プライミング) 必要が
    /// あると判定する。目標が縮小する側、あるいは現在のバッファ量が既に新目標を満たしている側は、
    /// 瞬時下限を割る恐れが無いため何もしない (安全側)。
    static func requiresReprime(
        currentAvailable: Int, newTargetOccupancyFrames: Int, previousTargetOccupancyFrames: Int
    ) -> Bool {
        newTargetOccupancyFrames > previousTargetOccupancyFrames && currentAvailable < newTargetOccupancyFrames
    }

    /// 無音のサンプルを書き続けているストリームの実体は 0 かそれに準ずる水準のため、判定には
    /// この程度の余裕を取れる (設計値)。
    static let silenceLevelThresholdDb: Float = -60

    static let silenceLevelThresholdAmplitude = Float(pow(10, Double(silenceLevelThresholdDb) / 20))

    /// ピークはシステム音量適用後の実出力であるため、実効出力ゲインを閾値の側へ掛けて比べる
    /// (素の閾値と比べると、音量を絞っているだけの通常再生を無音と誤判定する)。
    static func isOutputSilent(peak: Float, effectiveOutputGain: Float) -> Bool {
        peak <= silenceLevelThresholdAmplitude * effectiveOutputGain
    }

    /// 短いと楽曲中の休符で発火し、長いと再生の一時停止を取りこぼす。リセット 1 回が要する
    /// 無音時間に対して 1 桁大きい水準に置いた設計値 (実測値ではない)。
    static let silenceHoldSeconds: TimeInterval = 1.0

    static func silenceHoldFrames(sampleRate: Double) -> Int {
        Int((silenceHoldSeconds * sampleRate).rounded(.up))
    }

    /// 出力段の無音が継続時間ぶん続いていることと、バッファ量が目標を超えていることの AND。ずれの側に
    /// 書き込み単位 1 個分の遊びを置く (無いと健全な状態でも無音のたびに捨ててしまう)。
    static func requiresSilenceReset(
        silentFrames: Int, available: Int, targetOccupancyFrames: Int,
        writerBlockFrames: Int, sampleRate: Double
    ) -> Bool {
        silentFrames >= silenceHoldFrames(sampleRate: sampleRate)
            && available > targetOccupancyFrames + writerBlockFrames
    }

    static let millisecondsDisplayFractionDigits = 1

    static func occupancyMilliseconds(frames: Int, sampleRate: Double) -> Double {
        Double(frames) / sampleRate * 1000
    }

    static func formattedMilliseconds(frames: Int, sampleRate: Double) -> String {
        String(format: "%.\(millisecondsDisplayFractionDigits)f", occupancyMilliseconds(frames: frames, sampleRate: sampleRate))
    }

    static func durationSeconds(frames: Int, sampleRate: Double) -> TimeInterval {
        Double(frames) / sampleRate
    }

    static func formattedDuration(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 { return String(format: "%d時間%02d分", hours, minutes) }
        if minutes > 0 { return String(format: "%d分%02d秒", minutes, secs) }
        return "\(secs)秒"
    }

    static func occupancyGaugePosition(frames: Int, maxOccupancyFrames: Int) -> Double {
        guard maxOccupancyFrames > 0 else { return 0 }
        return min(1, max(0, Double(frames) / Double(maxOccupancyFrames)))
    }

    /// 混ぜる相手 (旧カーソル側) は、書き手が 1 周してその位置を書き直した時点で別の音になる。
    /// リング容量とバッファ量の差が書き込み粒度に満たない回は、次の 1 バーストで書き直されうるため
    /// 混ぜる相手が無いと判定する。
    static func hasMixableSource(available: Int, ringFrames: Int, writerBlockFrames: Int) -> Bool {
        available + writerBlockFrames <= ringFrames
    }

    /// 段差 (読み手側の中断・出力先/段の切替) は補正ループの権限では到底取り戻せない規模になる
    /// ため即座に再同期し、ドリフト (緩やかな超過) だけを保留時間の対象にする。
    static func classifyOverflow(
        discontinuityDetected: Bool,
        available: Int,
        maxOccupancyFrames: Int,
        overshootElapsed: TimeInterval?,
        trimHoldDuration: TimeInterval
    ) -> OverflowResponse {
        guard available > maxOccupancyFrames else { return .withinBounds }
        if discontinuityDetected { return .immediateResync }
        if let overshootElapsed, overshootElapsed >= trimHoldDuration { return .sustainedDriftTrim }
        return .withinBounds
    }
}
