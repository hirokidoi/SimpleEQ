import SwiftUI

/// UI レイアウト・タイミング・配色の定数。レイアウトを支配する寸法・タイミング・配色は
/// ここに集約し、定数から導出できる値をベタ書きしない。字サイズや細かな余白などの cosmetic 値は、
/// View 側に置くことがある (支配的でなく集約する利得が小さいため)。
enum EQLayout {

    // MARK: - ウィンドウ / 上部バー / レール

    /// 初期ウィンドウサイズ。
    static let windowDefaultSize = CGSize(width: 1000, height: 480)

    static let windowCornerRadius: CGFloat = 14

    // MARK: - コンパクトビュー

    static let compactWindowDefaultSize = CGSize(width: 500, height: 240)
    static let compactMargin: CGFloat = 12
    /// ラベルの文字が下側に持つ空きのぶん、下だけ薄くする。
    static let compactMarginBottom: CGFloat = 10
    /// EQ 本体と L/R レベルメーターの間隔。
    static let compactMeterGap: CGFloat = 20
    static let compactLabelRowHeight: CGFloat = 14
    static let compactLabelRowGap: CGFloat = 4

    static let compactLedHeight: CGFloat = compactWindowDefaultSize.height - compactMargin - compactMarginBottom
        - compactLabelRowGap - compactLabelRowHeight

    /// ノーマルビューの初期ウィンドウに並ぶ段数へ揃える。拡大率には依存させない。
    static let compactRowCount: Int = {
        let hostHeight = windowDefaultSize.height - topBarHeight - freqRowHeight
        let vertical = contentVerticalInset(canvasHeight: hostHeight)
        return SegmentGrid(height: vertical.height, bottomY: vertical.height, pixelGrid: PixelGrid(scale: 1)).rowCount
    }()

    /// Settings ウィンドウの幅 (固定)。高さのみユーザがリサイズできる。
    static let settingsWindowWidth: CGFloat = 640
    /// Settings ウィンドウの高さの下限。
    static let settingsWindowMinHeight: CGFloat = 460
    /// Settings ウィンドウを開いたときの高さ。
    static let settingsWindowDefaultHeight: CGFloat = 820

    /// Diagnostics ウィンドウの幅 (固定)。値の桁が揃って読めるよう Settings と同じ幅に合わせる。
    static let diagnosticsWindowWidth: CGFloat = settingsWindowWidth
    /// Diagnostics ウィンドウの高さの下限。
    static let diagnosticsWindowMinHeight: CGFloat = settingsWindowMinHeight

    /// About ウィンドウの幅 (固定)。面としての見え方で決める値で、下限は載せる行が折り返さずに
    /// 収まること。高さは内容が決めるため定数を持たない。
    static let aboutWindowWidth: CGFloat = 450

    /// ミキサーの寸法。面はビジュアライザ領域を覆い、行はその中央に置く列へ収める。
    enum Mixer {
        /// 行を収める列の左右に取る余白。列の幅はこれを引いた残り。
        static let columnHorizontalInset: CGFloat = 50
        /// 列の上下に取る余白。
        static let columnVerticalInset: CGFloat = 36
        static let rowHorizontalPadding: CGFloat = 12
        static let rowVerticalPadding: CGFloat = 8
        static let rowSpacing: CGFloat = 9
        static let gripWidth: CGFloat = 13
        static let checkboxColumnWidth: CGFloat = 16
        static let checkboxSize: CGFloat = 14
        static let checkboxCornerRadius: CGFloat = 3
        static let iconSize: CGFloat = 22
        static let nameColumnWidth: CGFloat = 158
        static let muteButtonSize = CGSize(width: 27, height: 22)
        static let controlsHeight: CGFloat = 22
        static let sliderTrackHeight: CGFloat = 4
        static let sliderKnobDiameter: CGFloat = 14
        static let valueColumnWidth: CGFloat = 72
        static let meterWidth: CGFloat = 132
        static let meterHeight: CGFloat = 14
        static let meterSegmentCount = 21

        /// 編集モードで、ポインタが載っている行の下地。
        static let rowHoverFill = Color.white.opacity(0.05)

        /// 並べ替えの開始とみなす移動量 (設計値)。これ未満はチェックの切り替えとして扱う。
        static let reorderMinimumDrag: CGFloat = 3

        /// 行のメーターを描き直す頻度の上限 (fps)。これより速く描き直しても見た目が変わらない。
        static let meterFpsCap: Double = 15

        /// 行のメーターの平滑化。1 回の更新あたりの係数 (設計値)。立ち上がりは平滑化しない。
        static let meterAttack: Double = 1
        static let meterRelease: Double = 0.33

        static let separatorThickness: CGFloat = 1
        static var rowHeight: CGFloat { rowVerticalPadding * 2 + iconSize }
        static var rowPitch: CGFloat { rowHeight + separatorThickness }
    }

    /// 文字主体の面 (Settings / Diagnostics / About) の背景。
    static let textPanelBackground = Color(hex: 0x14171e)

    /// 操作できない要素を減光する際の共通の不透明度。
    static let disabledOpacity: Double = 0.5

    /// トップバー高さ。
    static let topBarHeight: CGFloat = 56
    /// レール幅。
    static let railWidth: CGFloat = 172
    /// レール下端に横並びで置くボタンのうち、記号ぶんの幅だけ取る側。残りはもう一方が占める。
    static let railCompactButtonWidth: CGFloat = 40
    /// L/R レベルメーター列の幅。
    static let levelMeterColumnWidth: CGFloat = 52
    /// プリセットボタンの最小高さ (最大2行ぶんで高さ統一・中央寄せ)。
    static let presetButtonMinHeight: CGFloat = 56
    /// プリセットボタン長押しで保存ダイアログを開くまでの時間 (秒)。
    static let presetSaveLongPressDuration: Double = 0.5
    /// プリセットタイトルの最大幅。全角 = 2・半角 = 1 として計算し、全角20文字・半角40文字
    /// 相当を上限とする (ASCII のみを半角とみなす簡易換算)。
    static let presetTitleMaxWidth: Int = 40

    /// 指定文字列を presetTitleMaxWidth に収まるよう先頭から切り詰める。
    static func clampToPresetTitleMaxWidth(_ text: String) -> String {
        var result = ""
        var width = 0
        for ch in text {
            let charWidth = ch.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2
            guard width + charWidth <= presetTitleMaxWidth else { break }
            width += charWidth
            result.append(ch)
        }
        return result
    }

    /// dB 値を符号付き整数表記へ整形する。
    static func formatSignedDb(_ db: Double) -> String {
        let rounded = Int(db.rounded())
        let sign = rounded > 0 ? "+" : ""
        return "\(sign)\(rounded) dB"
    }

    /// 電源スイッチのトラックサイズ。
    static let powerTrackSize = CGSize(width: 36, height: 19)
    /// 電源スイッチのノブ直径。
    static let powerKnobDiameter: CGFloat = 15
    /// ON/OFF 切替時にラベル位置がぶれないための固定幅。
    static let powerLabelMinWidth: CGFloat = 46

    // MARK: - EQ プロット

    /// EQ プロット描画の余白 (左/右/上/下)。
    enum Padding {
        static let left: CGFloat = 36
        static let right: CGFloat = 10
        static let top: CGFloat = 30
        static let bottom: CGFloat = 6
    }
    /// 周波数ラベル行の高さ。
    static let freqRowHeight: CGFloat = 28

    /// EQ プロットと L/R レベルメーターバーの縦方向の描画領域 (上端 y・高さ) を導出する。
    /// canvasHeight はラベル行を除いた、バー描画対象領域そのものの高さを渡すこと。
    static func contentVerticalInset(canvasHeight: CGFloat, compact: Bool = false) -> (top: CGFloat, height: CGFloat) {
        let top = compact ? 0 : Padding.top
        let bottom = compact ? 0 : Padding.bottom
        return (top, max(0, canvasHeight - top - bottom))
    }

    static func horizontalPadding(compact: Bool) -> (left: CGFloat, right: CGFloat) {
        compact ? (0, 0) : (Padding.left, Padding.right)
    }

    static func meterColumnWidth(compact: Bool) -> CGFloat {
        compact
            ? LevelMeterRenderer.compactBarsWidth + compactMeterGap
            : levelMeterColumnWidth
    }

    static func compactBarEdgeInset(eqWidth: CGFloat, pixelGrid: PixelGrid) -> CGFloat {
        let geo = EQPlotGeometry(
            size: CGSize(width: eqWidth, height: 0), floorDb: Tuning.floorDbDefault,
            pixelGrid: pixelGrid, compact: true
        )
        return geo.barRect(0).minX - geo.plotRect.minX
    }

    /// バー幅を列幅から決める際の比率と上限 (列幅×比率を上限で頭打ち)。
    static let barWidthRatio: CGFloat = 0.54
    static let barWidthMax: CGFloat = 20
    /// LED セグメントの縦方向ステップ・高さ。
    static let segmentStep: CGFloat = 9
    static let segmentHeight: CGFloat = 6
    /// ハンドル線の左右はみ出し量。
    static let handleLineOverhang: CGFloat = 8
    /// ゲイン設定ライン (ハンドル) の線の太さ。
    static let handleLineWidth: CGFloat = 4
    /// ゲイン設定ラインへのホバー判定の許容縦距離 (px)。この範囲内なら上下リサイズカーソルを出す。
    static let handleHitTolerance: CGFloat = 6
    /// 連続クリックを同じ列とみなす押下位置のずれの上限 (px、設計値)。
    static let clickSequenceMaxDrift: CGFloat = 4
    /// ハンドル関連要素のレイヤを、アルファがこれ未満なら isHidden にする閾値。ハンドルのアルファ
    /// 自体もこの値を対称に使って 0/1 へ吸着させる。
    static let handleVisibilityThreshold: Double = 0.004

    /// ハンドル線の表示値が目標値へ指数イージングで寄るとき、この幅を
    /// 下回ったら目標へ吸着させる。出荷時のウィンドウ寸法で 1 ピクセル未満に相当する値。
    static let handleDisplaySettleThresholdDb: Double = 0.02

    /// EQ 本体の描画幅 (L/R レベルメーター表示中はその列幅ぶんを差し引く)。
    static func eqContentWidth(totalWidth: CGFloat, showLevelMeter: Bool, compact: Bool = false) -> CGFloat {
        totalWidth - (showLevelMeter ? meterColumnWidth(compact: compact) : 0)
    }

    /// dBFS レベル軸の目盛り値 (0 から floorDb まで等間隔)。各目盛りは 0 に向かって 5 刻みに丸める
    /// (例: -24 → -20、-37 → -35)。
    static func axisDbTicks(floorDb: Double, steps: Int = 3) -> [Double] {
        (0...steps).map { roundTowardZero(floorDb * Double($0) / Double(steps), to: 5) }
    }

    /// 値を 0 に向かって指定幅 (5 刻み等) に丸める。符号は保持する。
    private static func roundTowardZero(_ value: Double, to step: Double) -> Double {
        let magnitude = (abs(value) / step).rounded(.down) * step
        return value < 0 ? -magnitude : magnitude
    }

    // MARK: - 画素グリッド / ゲイン軸 / LED セグメントの縦方向グリッド

    /// ゲイン (dB) と縦座標の相互変換。EQ 本体と L/R レベルメーターの双方が使う。
    struct GainAxis {
        let top: CGFloat
        let height: CGFloat

        init(canvasHeight: CGFloat, pixelGrid: PixelGrid, compact: Bool = false) {
            let vertical = EQLayout.contentVerticalInset(canvasHeight: canvasHeight, compact: compact)
            top = pixelGrid.snap(vertical.top)
            height = pixelGrid.snap(vertical.height)
        }

        func dbToY(_ db: Double) -> CGFloat {
            let t = (EQSpec.DB_MAX - db) / (EQSpec.DB_MAX - EQSpec.DB_MIN)
            return top + CGFloat(t) * height
        }

        func yToDb(_ y: CGFloat) -> Double {
            guard height > 0 else { return 0 }
            var rel = Double((y - top) / height)
            rel = max(0, min(1, rel))
            return (EQSpec.DB_MAX - rel * (EQSpec.DB_MAX - EQSpec.DB_MIN)).rounded()
        }
    }

    /// バー矩形・段の矩形の物理ピクセル境界への丸めを担う小さなグリッド。
    struct PixelGrid {
        /// 画面の拡大率 (backingScaleFactor 相当)。0 以下・非数のときは 1.0 にフォールバックする。
        let scale: CGFloat

        init(scale: CGFloat) {
            self.scale = scale.isFinite && scale > 0 ? scale : 1
        }

        /// 値を画素境界 (1/scale の整数倍) へ丸める。原点・長さのどちらにも使う。
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }

        func snapDown(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.down) / scale
        }
    }

    /// LED セグメントの縦方向グリッド。段数・各段の縦範囲・点灯段数/キャップ段の判定を持ち、
    /// EQ 本体とレベルメーターの双方が使う。
    struct SegmentGrid {
        /// 画素境界へ丸めた段の下端 (プロット/メーター領域の下端)。
        let bottomY: CGFloat
        /// 段の数。
        let rowCount: Int
        /// 画素境界へ丸めた段の高さ・段の刻み幅。
        let rowHeight: CGFloat
        let rowStep: CGFloat

        /// - Parameters:
        ///   - height: 段を敷き詰める領域の高さ (プロット高またはメーター領域高)。
        ///   - bottomY: 領域の下端 y (画素境界へ丸める前の値でよい)。
        init(height: CGFloat, bottomY: CGFloat, pixelGrid: PixelGrid) {
            self.init(height: height, bottomY: bottomY, pixelGrid: pixelGrid, rowCount: nil)
        }

        /// - Parameters:
        ///   - rowCount: 段数を先に決める場合の段数。nil のときは段の寸法から段数が決まる。
        init(height: CGFloat, bottomY: CGFloat, pixelGrid: PixelGrid, rowCount: Int?) {
            self.bottomY = pixelGrid.snap(bottomY)
            if let rowCount, rowCount > 0 {
                let rawStep = height / CGFloat(rowCount)
                rowStep = pixelGrid.snapDown(rawStep)
                rowHeight = pixelGrid.snapDown(rawStep * segmentHeight / segmentStep)
                self.rowCount = rowStep > 0 && rowHeight > 0 ? rowCount : 0
            } else {
                rowStep = pixelGrid.snap(segmentStep)
                rowHeight = pixelGrid.snap(segmentHeight)
                self.rowCount = rowStep > 0 && height >= rowHeight
                    ? Int(((height - rowHeight) / rowStep).rounded(.down)) + 1
                    : 0
            }
        }

        /// 第 index 段 (0 = 最下段) の縦範囲。x/width は含まない (呼び出し側のバー矩形が持つ)。
        func rowY(_ index: Int) -> (top: CGFloat, bottom: CGFloat) {
            let bottom = bottomY - CGFloat(index) * rowStep
            return (bottom - rowHeight, bottom)
        }

        /// 第 index 段の矩形。x/width は呼び出し側の (既に画素境界へ丸めた) バー矩形から渡す。
        func rowRect(_ index: Int, x: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: x, y: rowY(index).top, width: width, height: rowHeight)
        }

        /// EQ 本体の点灯段数。
        func litRowCountByFillTop(_ fillTop: CGFloat) -> Int {
            guard rowCount > 0, fillTop <= bottomY else { return 0 }
            return min(Int(((bottomY - fillTop) / rowStep).rounded(.down)) + 1, rowCount)
        }

        /// EQ 本体のキャップ段。
        func capRowIndex(peakTop: CGFloat) -> Int? {
            let count = litRowCountByFillTop(peakTop)
            return count > 0 ? count - 1 : nil
        }

        /// レベルメーターの点灯段数。充填比率 (0...1) に段数を掛けて四捨五入して求める。
        func litRowCountByRatio(_ ratio: Double) -> Int {
            Int((ratio * Double(rowCount)).rounded())
        }

        /// レベルメーターのキャップ段。比率が 0 以下 (点灯なし) のときは nil。
        func capRowIndexByRatio(_ ratio: Double) -> Int? {
            guard ratio > 0, rowCount > 0 else { return nil }
            let n = litRowCountByRatio(ratio)
            return min(rowCount - 1, max(0, n - 1))
        }

        /// 点灯段数 n から点灯レイヤの高さを導く (n=0 のときは 0)。下端・段の刻みが画素境界に
        /// 乗っているため、この高さぶん切り取った上端も自動的に画素境界へ乗る。
        func litHeight(forRowCount n: Int) -> CGFloat {
            guard n > 0 else { return 0 }
            return CGFloat(n) * rowStep
        }

        /// 縦範囲 [top, bottom) に重なる段の index 範囲。
        func rowIndexRange(intersectingTop top: CGFloat, bottom: CGFloat) -> ClosedRange<Int>? {
            guard rowCount > 0 else { return nil }
            let lower = max(0, Int(((bottomY - rowHeight - bottom) / rowStep).rounded(.down)) + 1)
            let upper = min(rowCount - 1, Int(((bottomY - top) / rowStep).rounded(.up)) - 1)
            guard lower <= upper else { return nil }
            return lower...upper
        }
    }

    // MARK: - チューニング設定 (Settings 画面で調整可能)

    /// Settings 画面で調整可能な値の既定・範囲・レベル対応表を集約する。
    enum Tuning {
        /// ビジュアライザを描き直す頻度の上限 (fps)。
        static let visualizerFpsChoices: [Double] = [10, 12, 15, 20, 30, 60]
        static let visualizerFpsDefault: Double = 30
        /// 描画 tick の間隔として想定する上限 (秒)。
        static let visualizerTickIntervalCap: Double = 1.0 / min(visualizerFpsChoices.min()!, idleFps)

        /// ビジュアライザ (バーレベル) の dBFS 下限。バー全高 = [下限..0]dBFS として扱う。
        static let floorDbDefault: Double = -60
        static let floorDbRange: ClosedRange<Double> = -120...(-40)
        /// 下限値スライダーの刻み幅。
        static let floorDbStep: Double = 2

        /// レベル方式の項目が持つ、段の並びと既定の段。段の数は並びの長さで決まり、既定が真ん中とは限らない。
        struct LevelScale {
            let values: [Double]
            let defaultLevel: Int

            /// 段から実値を引く。範囲外は端にクランプする。
            func value(at level: Int) -> Double {
                values[max(1, min(values.count, level)) - 1]
            }
        }

        /// レベルメーター (バーの点灯段と L/R マスターレベル) の非対称平滑化係数。立ち上がり
        /// (attack) を速く、下がり (release) をゆっくりにするほどピークに機敏かつ暴れない見栄えになる。
        static let attack = LevelScale(values: [0.30, 0.50, 0.65, 0.80, 1.0], defaultLevel: 5)

        static let release = LevelScale(values: [0.04, 0.08, 0.18, 0.30, 0.65], defaultLevel: 3)

        /// ハンドル表示アルファの指数フェードの時間定数 (秒)。フレームレートに依存せず、経過時間 dt から
        /// `1 - exp(-dt/tau)` で目標へ寄せる (小さいほど速く追従して速く消える)。
        static let handleFade = LevelScale(values: [0.32, 0.22, 0.15, 0.10, 0.06], defaultLevel: 3)

        /// ハンドル線の表示値がプレビュー対象 (hover 中プリセット or 現在値) へ寄る指数イージングの
        /// 時間定数 (秒)。
        static let handlePreview = LevelScale(values: [0.28, 0.20, 0.13, 0.07, 0.04], defaultLevel: 3)

        /// ピークホールド表示の有効/無効。
        static let peakHoldEnabledDefault = true

        /// L/R レベルメーター表示の既定値。
        static let showLevelMeterDefault = true

        /// ピーク到達後、減衰を始めるまで保持する時間 (秒)。
        static let peakHoldSecondsDefault: Double = 0.8
        static let peakHoldSecondsRange: ClosedRange<Double> = 0.1...2.5
        static let peakHoldSecondsStep: Double = 0.1

        /// クリップ表示を点灯させ続ける時間 (秒、設計値)。
        static let clipHoldSeconds: Double = 0.08

        /// 音が届かず絵も動かない状態が続いたときに落とす刻み (fps、設計値)。
        static let idleFps: Double = 10
        /// 落とすまでに要する静止フレーム数 (設計値)。
        static let idleFrameThreshold = 60

        /// ホールド終了後にピークが下がっていく速度 (dB/秒)。
        static let peakDecayDbPerSecDefault: Double = 30
        static let peakDecayDbPerSecRange: ClosedRange<Double> = 0...100
        static let peakDecayDbPerSecStep: Double = 10

        /// ピークホールド LED を白へ寄せる度合い (0=通常点灯と同色、1=白)。
        static let peakCapBrightenAmountDefault: Double = 0.3
        static let peakCapBrightenAmountRange: ClosedRange<Double> = 0...1
        static let peakCapBrightenAmountStep: Double = 0.05
    }

    // MARK: - アイコンモチーフ

    /// アプリアイコン・メニューバーアイコンが共有するバーモチーフ (本数・高さ比・バー間ギャップ比)。
    enum IconMotif {
        static let barHeightRatios: [CGFloat] = [0.42, 0.72, 1.0, 0.58, 0.85]
        static let barGapRatio: CGFloat = 0.42
    }

    // MARK: - 配色

    enum Palette {
        /// 背景色。
        static let bg = Color(hex: 0x050608)
        /// パネル背景色。
        static let panel = Color(hex: 0x0b0d12)
        /// 境界線色。
        static let line = Color(hex: 0x191c24)
        /// 非アクティブなボタン (プリセット・レベル選択) の枠線色。line はパネル背景と同化して
        /// ボタンの輪郭が判別しづらいため、ボタン専用にコントラストを上げた色を使う。
        static let buttonLine = Color.white.opacity(0.14)
        /// 本文文字色。
        static let text = Color(hex: 0xe9edf4)
        /// 減光文字色。
        static let dim = Color(hex: 0xaab1c0)
        /// 最も淡い文字色 (周波数ラベル等)。
        static let faint = Color(hex: 0x8b92a3)
        /// アクセントのシアン。
        static let cyan = Color(hex: 0x63e9ff)
        /// 警告色 (ドライバ未検出・音声取得失敗などの異常状態表示)。
        static let danger = Color(hex: 0xff5d6c)
        /// フルスケール超過を伝えるレベルメーター最上段の色。異常状態の警告色とは別に持つ
        /// (伝えるのは利用者の設定が生んだ結果であって、アプリの不調ではない)。
        static let clip = Color(hex: 0xff2033)
        /// 淡いシアン。
        static let cyanSoft = Color(hex: 0xa8f2ff)
        /// EQ OFF 時の電源トラック色。
        static let powerOffTrack = Color(hex: 0x2a2e38)
        /// プリセット選択時グラデーションの青成分。
        static let presetActiveBlue = Color(hex: 0x2f6bff)

        /// 編集モードにいることを示すボタンの背景グラデーション。
        static var editingButtonGradient: LinearGradient {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }

        /// 選択中のボタン (プリセット・Settings のレベル選択等) に共通の背景グラデーション。
        static var activeButtonGradient: LinearGradient {
            LinearGradient(
                colors: [cyan.opacity(0.16), presetActiveBlue.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// RGB 0...255 成分。セグメント発光色のグラデーション補間・アルファ合成に使う。
    struct RGB {
        let r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        func opacity(_ a: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a) }
        /// 指定色 target へ向けて amount (0...1) だけ寄せた色 (既定は白)。ピークホールドの LED を
        /// 同系色のまま明るく見せるのに使う。
        func brightened(_ amount: Double, toward target: RGB = RGB(255, 255, 255)) -> RGB {
            RGB(r + (target.r - r) * amount, g + (target.g - g) * amount, b + (target.b - b) * amount)
        }
    }

    /// セグメント発光グラデーションの基準色 (teal→blue→magenta の 3 停止点)。
    private static let segmentGradientStops = (RGB(16, 231, 180), RGB(47, 107, 255), RGB(194, 59, 255))
    /// バイパス時のセグメント色。
    static let bypassSegmentRGB = RGB(158, 165, 177)
    /// ハンドル線 (ゲイン設定ライン) と同系色の青灰がかった白。ピークホールド LED の明るさ寄せ先にも使う。
    static let handleTintRGB = RGB(208, 221, 232)

    /// セグメントの点灯/非点灯アルファ (通常時 / バイパス時)。
    static let segmentLitAlpha: Double = 0.96
    static let segmentDimAlpha: Double = 0.17
    static let bypassLitAlpha: Double = 0.42
    static let bypassDimAlpha: Double = 0.15

    /// ピークホールド表示 (LED キャップ) のアルファ (固定値)。色相を保ったまま白へ寄せる度合いは
    /// Settings で調整可能なため別の集約先に置く。
    static let peakCapAlpha: Double = 1.0

    /// バー内の垂直位置比率 (0=下端..1=上端) からセグメント発光色を補間する (定数から導出、色をベタ書きしない)。
    static func segmentColor(atRatio pr: Double) -> RGB {
        let p = max(0, min(1, pr))
        let (c1, c2, c3) = segmentGradientStops
        if p < 0.5 {
            let t = p / 0.5
            return RGB(c1.r + (c2.r - c1.r) * t, c1.g + (c2.g - c1.g) * t, c1.b + (c2.b - c1.b) * t)
        } else {
            let t = (p - 0.5) / 0.5
            return RGB(c2.r + (c3.r - c2.r) * t, c2.g + (c3.g - c2.g) * t, c2.b + (c3.b - c2.b) * t)
        }
    }

    /// ハンドル線 (ゲイン設定ライン) の色。
    static let handleLineColor = handleTintRGB.opacity(1)
    /// 0dB ラインからゲイン設定ライン (ハンドル) までの範囲に重ねる半透明オーバーレイ色。ハンドル線と
    /// 同系色 (handleLineColor) を使う。リアルタイムのレベル表示 (lit/dim/peak) はそのまま描いた上に、
    /// この色を重ね塗りする。
    static let gainRangeFillColor = handleLineColor.opacity(0.15)
    /// ドラッグ中のバンドのみ、0dB ラインから現在ゲインまでの範囲を最前面 (バーより手前) で
    /// 塗りつぶす色。ハンドル線と同系色。
    static let dragBandFillColor = handleLineColor.opacity(1)
    /// ドラッグ中の現在値ツールチップの背景色。バー・白塗りとの重なりに関係なく常に読める
    /// 不透明度を確保する。
    static let dragBadgeBackgroundColor = Palette.panel.opacity(0.92)
    /// 0dB 基準の破線の色と破線パターン。
    static let baselineColor = Color(white: 1, opacity: 0.14)
    static let baselineDash: [CGFloat] = [4, 5]
    /// gutter (+/−) の文字色。
    static let gutterSignColor = Color(red: 202 / 255, green: 216 / 255, blue: 240 / 255, opacity: 0.9)
    /// gutter (0) の文字色。
    static let gutterZeroColor = Color(red: 188 / 255, green: 200 / 255, blue: 224 / 255, opacity: 0.88)
    /// dBFS 軸目盛りの文字色。
    static let axisDbColor = Color(red: 150 / 255, green: 160 / 255, blue: 180 / 255, opacity: 0.75)
    /// ドラッグ中の dB 数値表示色 (boost/cut/zero)。
    static let dragValueBoostColor = Color(hex: 0x8af3ff)
    static let dragValueCutColor = Color(hex: 0x7fa8ff)
    static let dragValueZeroColor = Color(red: 205 / 255, green: 214 / 255, blue: 232 / 255, opacity: 0.8)
}

extension Color {
    /// 6 桁 hex カラーから Color を生成する変換ヘルパー。
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
