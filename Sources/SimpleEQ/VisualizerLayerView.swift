import AppKit
import QuartzCore
import SwiftUI

/// LED バー・ピークキャップ・L/R レベルメーター (クリップセル込み) の描画を CALayer の
/// 幾何更新で担う View。当たり判定は持たない (hitTest 常に nil)。ジェスチャ・カーソル出し分けは
/// 手前に重なる別のビューが担う。
struct VisualizerLayerView: View {
    @ObservedObject var viewModel: EQViewModel
    var compact: Bool = false

    @ViewBuilder
    var body: some View {
        if compact {
            VStack(spacing: 0) {
                VisualizerHostRepresentable(viewModel: viewModel, compact: true)
                Color.clear.frame(height: EQLayout.compactLabelRowGap + EQLayout.compactLabelRowHeight)
            }
        } else {
            VStack(spacing: 0) {
                VisualizerHostRepresentable(viewModel: viewModel, compact: false)
                Color.clear.frame(height: EQLayout.freqRowHeight)
            }
        }
    }
}

/// CALayer ホストを SwiftUI へ橋渡しする NSViewRepresentable 本体。
private struct VisualizerHostRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: EQViewModel
    let compact: Bool

    func makeNSView(context: Context) -> VisualizerHostView {
        VisualizerHostView(viewModel: viewModel, compact: compact)
    }

    func updateNSView(_ nsView: VisualizerHostView, context: Context) {
        nsView.viewModelSettingsChanged()
    }
}

/// タイマ起動可否の門 (LED レイヤの毎フレーム駆動)。ビジュアライザの表示要否と、ホストビューが実際に
/// 利用者から見えているかの両方が真のときだけ起動可とする。
enum VisualizerTimerGate {
    static func shouldRun(visualizerActive: Bool, hostViewVisible: Bool) -> Bool {
        visualizerActive && hostViewVisible
    }
}

/// LED バー (EQ 本体)・L/R レベルメーター・EQ chrome (ゲイン範囲の白オーバーレイ/
/// ハンドル線/ドラッグ帯・バッジ/baseline/gutter/dBFS 軸目盛り) の描画を CALayer で担うホストビュー。
///
/// レイヤの並び順は合成順序に効く。崩さないこと。
///
/// 座標系: このビューは isFlipped=true (y 下方向)。画像を貼るレイヤの contentsRect は、y=0 が
/// 画像の論理上端・y=1 が論理下端という規約で解釈される。
final class VisualizerHostView: NSView {
    private let viewModel: EQViewModel
    private let compact: Bool

    let eqContainer = CALayer()
    let meterContainer = CALayer()
    lazy var chromeLayers = EQChromeLayers()
    private(set) var eqColumns: [BandColumn] = []
    private(set) var meterColumns: [BandColumn] = []
    private(set) var clipCells: [CALayer] = []

    private(set) var imageSet: BandImageSet?
    private var lastBakedScale: CGFloat?
    private var lastBakedPlotHeight: CGFloat?
    private var lastBakedBrighten: Double?
    private var lastAppliedFloorDb: Double?
    private var currentlyShowingInEffect = true
    private var lastAppliedShowLevelMeter: Bool?
    /// 直近のレイアウトで組み立てた幾何。chrome の反映 (applyGeometry) が読む。
    private var geo: EQPlotGeometry?
    /// 直近のレイアウトで求めたメーター列の絶対矩形 (列全体とバー2枚)。chrome の反映が読む。
    private var meter: MeterChromeGeometry?

    private var timer: Timer?
    private var lastTimerFps: Double?
    private var idleFrameCount = 0
    private var lastSeenPrimingSilenceCount: UInt64 = 0
    private var effectiveFps: Double {
        idleFrameCount >= EQLayout.Tuning.idleFrameThreshold
            ? min(viewModel.visualizerFps, EQLayout.Tuning.idleFps)
            : viewModel.visualizerFps
    }
    /// 反映済みの描画リビジョン。nil は「まだ何も反映していない」。
    private var appliedDisplayRevision: Int?
    /// 描画リビジョンでは表せない契機で反映が要ることを表す。
    private var needsFrameApply = true
    /// ウィンドウが表示されているか (NSWindow.isVisible の KVO 監視から更新)。遮蔽状態
    /// (NSWindow.occlusionState) は検出に失敗する実行環境があるため可視性の根拠にしない。
    var windowVisible = false
    /// アプリ全体が非表示か (NSApplication.didHide/didUnhide から更新)。
    var appHidden = false
    /// 毎フレームの駆動が動いているか。
    var visualizerTimerRunning: Bool { timer != nil }
    var visualizerTimerFps: Double? { lastTimerFps }
    private var windowVisibleObservation: NSKeyValueObservation?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?

    init(viewModel: EQViewModel, compact: Bool) {
        self.viewModel = viewModel
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        setUpLayerTree()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var fixedRowCount: Int? { compact ? EQLayout.compactRowCount : nil }

    private func segmentGrid(height: CGFloat, bottomY: CGFloat, pixelGrid: EQLayout.PixelGrid) -> EQLayout.SegmentGrid {
        EQLayout.SegmentGrid(height: height, bottomY: bottomY, pixelGrid: pixelGrid, rowCount: fixedRowCount)
    }

    /// 当たり判定を常に無効化する。実際のジェスチャは手前に重なる別のビューが担う。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// ポインタの現在の状態の取得口。
    var pointerState: () -> (locationOnScreen: NSPoint, buttonDown: Bool) = {
        (NSEvent.mouseLocation, NSEvent.pressedMouseButtons != 0)
    }

    /// ポインタの位置とボタンの状態を毎フレーム読み直す。
    private func refreshPointerInsideVisualizeArea() {
        guard !compact, viewModel.handlesRevealed, let window, window.isVisible else { return }
        let state = pointerState()
        let inside = bounds.contains(convert(window.convertPoint(fromScreen: state.locationOnScreen), from: nil))
        viewModel.refreshHandleReveal(pointerInsideCanvas: inside, pointerButtonDown: state.buttonDown)
    }

    /// レイヤの暗黙アクションを一括で無効化する。幾何の代入は必ず CATransaction 側の無効化
    /// (setDisableActions) と併用する。
    nonisolated(unsafe) static let disabledLayerActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
        "contentsRect": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(),
    ]

    private func setUpLayerTree() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eqContainer.actions = Self.disabledLayerActions
        meterContainer.actions = Self.disabledLayerActions
        if !compact { root.addSublayer(chromeLayers.backChromeContainer) }
        root.addSublayer(eqContainer)
        root.addSublayer(meterContainer)
        if !compact { root.addSublayer(chromeLayers.frontChromeContainer) }
        eqColumns = (0..<EQSpec.bandCount).map { _ in BandColumn(container: eqContainer) }
        meterColumns = (0..<2).map { _ in BandColumn(container: meterContainer) }
        clipCells = (0..<2).map { _ in
            let cell = CALayer()
            cell.actions = Self.disabledLayerActions
            cell.backgroundColor = NSColor(EQLayout.Palette.clip).cgColor
            cell.isHidden = true
            meterContainer.addSublayer(cell)
            return cell
        }
        CATransaction.commit()
    }

    // MARK: - SwiftUI からの入力反映

    /// SwiftUI 側の更新契機から呼ぶ。@Published の変化を受けて、レイアウトの
    /// invalidate・タイマ起動可否の再評価・(Timer 停止中に限った) chrome の現在値反映を行う唯一の口。
    func viewModelSettingsChanged() {
        needsFrameApply = true
        idleFrameCount = 0
        if lastAppliedShowLevelMeter != viewModel.showLevelMeter { needsLayout = true }
        if let lastBakedBrighten, lastBakedBrighten != viewModel.peakCapBrightenAmount { needsLayout = true }
        if let lastAppliedFloorDb, lastAppliedFloorDb != viewModel.floorDb { needsLayout = true }
        updateTimerRunning()
        if timer == nil { applyGeometry() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeVisibilityObservers()
        if let window {
            addVisibilityObservers(window: window)
            appHidden = NSApp.isHidden
        } else {
            windowVisible = false
        }
        updateTimerRunning()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        needsFrameApply = true
        applyLayoutAndRebakeIfNeeded()
        applyGeometry()
    }

    // MARK: - 可視性とタイマ (visualizerActive かつホストビューが実際に見えている間だけ駆動)

    private func addVisibilityObservers(window: NSWindow) {
        windowVisibleObservation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.windowVisible = window.isVisible
                self?.updateTimerRunning()
            }
        }
        appHideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appHidden = true
                self?.updateTimerRunning()
            }
        }
        appUnhideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appHidden = false
                self?.updateTimerRunning()
            }
        }
    }

    private func removeVisibilityObservers() {
        windowVisibleObservation = nil
        for observer in [appHideObserver, appUnhideObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        appHideObserver = nil
        appUnhideObserver = nil
    }

    /// タイマ起動可否を再評価する。ウィンドウの表示状態はビジュアライザの表示要否へ書き戻さない
    /// (可視性の門はこのホストビュー内部の局所状態に留める)。
    func updateTimerRunning() {
        let hostViewVisible = windowVisible && !appHidden
        let shouldRun = VisualizerTimerGate.shouldRun(visualizerActive: viewModel.visualizerActive, hostViewVisible: hostViewVisible)
        let fpsChanged = timer != nil && lastTimerFps != effectiveFps
        guard shouldRun != (timer != nil) || fpsChanged else { return }
        if !shouldRun { idleFrameCount = 0 }
        stopTimer()
        if shouldRun { startTimer() }
        applyGeometry()
    }

    private func startTimer() {
        let fps = max(effectiveFps, 1)
        lastTimerFps = fps
        let interval = 1.0 / fps
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPointerInsideVisualizeArea()
                let inEffect = self.viewModel.processingInEffect
                self.viewModel.tick(now: Date(), processingInEffect: inEffect)
                let applied = self.applyGeometry(inEffect: inEffect)
                self.advanceIdleTracking(applied: applied)
            }
        }
        t.tolerance = interval * 0.1
        // .common モードへ登録する (既定モードだとドラッグ中に発火が止まる、実測で確認済み)。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastTimerFps = nil
    }

    private func advanceIdleTracking(applied: Bool) {
        let priming = viewModel.primingSilenceCountSinceLaunch
        let signalPresent = priming == lastSeenPrimingSilenceCount
        lastSeenPrimingSilenceCount = priming
        idleFrameCount = (signalPresent || applied) ? 0 : idleFrameCount + 1
        if lastTimerFps != effectiveFps { updateTimerRunning() }
    }

    // MARK: - レイアウト (拡大率・プロット高・showLevelMeter・明るさ寄せ量が変わったときのみ)

    private func applyLayoutAndRebakeIfNeeded() {
        let scale = window?.backingScaleFactor ?? 1
        let pixelGrid = EQLayout.PixelGrid(scale: scale)
        let showMeter = viewModel.showLevelMeter
        let totalSize = bounds.size
        guard totalSize.width > 0, totalSize.height > 0 else { return }
        lastAppliedShowLevelMeter = showMeter
        lastAppliedFloorDb = viewModel.floorDb

        let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: showMeter, compact: compact)
        let geo = EQPlotGeometry(
            size: CGSize(width: eqWidth, height: totalSize.height), floorDb: viewModel.floorDb,
            pixelGrid: pixelGrid, compact: compact
        )
        self.geo = geo
        let plotRect = geo.plotRect

        // メーター領域の矩形。EQ 本体側と同じ縦方向の余白算出を経由し、縦方向を一致させる。
        let vertical = EQLayout.contentVerticalInset(canvasHeight: totalSize.height, compact: compact)
        let meterBarWidth = pixelGrid.snap(LevelMeterRenderer.barWidth(compact: compact))
        let meterSecondBarX = pixelGrid.snap(
            LevelMeterRenderer.barWidth(compact: compact) + LevelMeterRenderer.channelGap(compact: compact)
        )
        let meterBarOriginX = [pixelGrid.snap(0), meterSecondBarX]
        let meterWidth = meterSecondBarX + meterBarWidth
        let meterHeight = pixelGrid.snap(vertical.height)
        let meterOriginX = compact
            ? pixelGrid.snap(totalSize.width - EQLayout.compactBarEdgeInset(eqWidth: eqWidth, pixelGrid: pixelGrid) - meterWidth)
            : pixelGrid.snap(eqWidth + (EQLayout.meterColumnWidth(compact: false) - meterWidth) / 2)
        let meterOriginY = pixelGrid.snap(vertical.top)
        let meterRect = CGRect(x: meterOriginX, y: meterOriginY, width: meterWidth, height: meterHeight)
        self.meter = MeterChromeGeometry(
            rect: meterRect,
            barRects: meterBarOriginX.map {
                CGRect(x: meterOriginX + $0, y: meterOriginY, width: meterBarWidth, height: meterHeight)
            }
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        eqContainer.frame = plotRect
        meterContainer.frame = meterRect
        meterContainer.isHidden = !showMeter
        if !compact {
            chromeLayers.layout(hostBounds: CGRect(origin: .zero, size: totalSize), geo: geo)
        }
        CATransaction.commit()

        let brighten = viewModel.peakCapBrightenAmount
        let needsRebake = imageSet == nil || lastBakedScale != scale
            || lastBakedPlotHeight != plotRect.height || lastBakedBrighten != brighten
        if needsRebake {
            guard let baked = BandImageBaker.bake(
                plotHeight: plotRect.height, pixelGrid: pixelGrid, peakCapBrightenAmount: brighten,
                rowCount: fixedRowCount, includesChrome: !compact
            ) else {
                return
            }
            imageSet = baked
            lastBakedScale = scale
            lastBakedPlotHeight = plotRect.height
            lastBakedBrighten = brighten
            if let fills = baked.chromeFills { chromeLayers.applyChromeFills(fills, scale: baked.scale) }
        }
        guard let imageSet else { return }
        currentlyShowingInEffect = viewModel.processingInEffect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in 0..<EQSpec.bandCount {
            let localX = geo.barRect(band).minX - plotRect.minX
            eqColumns[band].layout(
                localX: localX, barWidth: geo.barWidth, plotHeight: plotRect.height,
                imageSet: imageSet, inEffect: currentlyShowingInEffect
            )
        }
        if meterRect.height > 0 {
            let meterGrid = segmentGrid(height: meterRect.height, bottomY: meterRect.height, pixelGrid: pixelGrid)
            for i in 0..<2 {
                meterColumns[i].layout(
                    localX: meterBarOriginX[i], barWidth: meterBarWidth, plotHeight: meterRect.height,
                    imageSet: imageSet, inEffect: currentlyShowingInEffect
                )
                if meterGrid.rowCount > 0 {
                    clipCells[i].frame = meterGrid.rowRect(meterGrid.rowCount - 1, x: meterBarOriginX[i], width: meterBarWidth)
                }
            }
        }
        CATransaction.commit()
    }

    // MARK: - フレームの幾何代入

    @MainActor
    private struct MeterReflectionSnapshot: Equatable {
        let levels: [Double]
        let peaks: [Double]
        let stereo: LevelMeter.Snapshot.Stereo
        let leftClipped: Bool
        let rightClipped: Bool
        let floorDb: Double
        let peakHoldEnabled: Bool
        let showLevelMeter: Bool

        init(_ viewModel: EQViewModel, inEffect: Bool) {
            levels = viewModel.displayedLevels
            peaks = viewModel.displayedPeaks
            stereo = viewModel.displayedStereoLevel
            leftClipped = inEffect && viewModel.leftClipHolding
            rightClipped = inEffect && viewModel.rightClipHolding
            floorDb = viewModel.floorDb
            peakHoldEnabled = viewModel.peakHoldEnabled
            showLevelMeter = viewModel.showLevelMeter
        }
    }
    private var lastAppliedMeterSnapshot: MeterReflectionSnapshot?

    /// 表示値を読み、点灯レイヤの高さ・キャップレイヤの位置/選択スライス/可視性・クリップセルの
    /// 可視性を更新する。タイマ発火のたびに呼ぶほか、レイアウト直後・タイマの開始/停止の直後にも呼ぶ。
    @discardableResult
    private func applyGeometry(inEffect: Bool? = nil) -> Bool {
        guard let imageSet else { return false }
        let revision = viewModel.displayRevision
        let inEffect = inEffect ?? viewModel.processingInEffect
        let meterSnapshot = MeterReflectionSnapshot(viewModel, inEffect: inEffect)
        let meterChanged = meterSnapshot != lastAppliedMeterSnapshot
        guard needsFrameApply || appliedDisplayRevision != revision || meterChanged else { return false }
        if inEffect != currentlyShowingInEffect {
            currentlyShowingInEffect = inEffect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for column in eqColumns + meterColumns {
                column.setContents(inEffect: inEffect, imageSet: imageSet)
            }
            CATransaction.commit()
        }

        let plotHeight = eqContainer.bounds.height
        guard plotHeight > 0 else { return false }
        needsFrameApply = false
        appliedDisplayRevision = revision
        lastAppliedMeterSnapshot = meterSnapshot
        let pixelGrid = EQLayout.PixelGrid(scale: imageSet.scale)
        let peakHoldEnabled = meterSnapshot.peakHoldEnabled
        let levels = meterSnapshot.levels
        let peaks = meterSnapshot.peaks
        let floorDb = meterSnapshot.floorDb

        // バンドごとの点灯上端。ローカル y 下方向座標 (0=コンテナ上端、plotHeight=下端) で表す。
        func fillTop(_ level: Double) -> CGFloat {
            let frac = (level - floorDb) / (0 - floorDb)
            return plotHeight - CGFloat(frac) * plotHeight
        }

        let grid = segmentGrid(height: plotHeight, bottomY: plotHeight, pixelGrid: pixelGrid)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in 0..<EQSpec.bandCount {
            let litCount = grid.litRowCountByFillTop(fillTop(levels[band]))
            let capIndex = peakHoldEnabled ? grid.capRowIndex(peakTop: fillTop(peaks[band])) : nil
            eqColumns[band].apply(litRowCount: litCount, capRowIndex: capIndex, grid: grid, plotHeight: plotHeight)
        }

        if meterSnapshot.showLevelMeter {
            let meterHeight = meterContainer.bounds.height
            if meterHeight > 0 {
                let stereo = meterSnapshot.stereo
                let meterGrid = segmentGrid(height: meterHeight, bottomY: meterHeight, pixelGrid: pixelGrid)
                applyMeterChannel(
                    index: 0, level: stereo.leftDb, peak: stereo.leftPeakDb, clipped: meterSnapshot.leftClipped,
                    grid: meterGrid, plotHeight: meterHeight
                )
                applyMeterChannel(
                    index: 1, level: stereo.rightDb, peak: stereo.rightPeakDb, clipped: meterSnapshot.rightClipped,
                    grid: meterGrid, plotHeight: meterHeight
                )
            }
        }
        if !compact, let geo {
            chromeLayers.applyFrame(
                viewModel: viewModel, geo: geo, meter: meter, showLevelMeter: meterSnapshot.showLevelMeter, inEffect: inEffect
            )
        }
        CATransaction.commit()
        return true
    }

    /// L/R いずれか 1 チャンネルぶんの点灯段数・キャップ段・クリップセルの可視性を更新する。
    /// 超過中、その段が最上段のときはキャップレイヤを隠す (最上段に見えるのはクリップ側)。
    private func applyMeterChannel(
        index: Int, level: Double, peak: Double, clipped: Bool, grid: EQLayout.SegmentGrid, plotHeight: CGFloat
    ) {
        let litCount = grid.litRowCountByRatio(LevelMeterRenderer.levelRatio(level, viewModel: viewModel))
        var capIndex = viewModel.peakHoldEnabled
            ? grid.capRowIndexByRatio(LevelMeterRenderer.levelRatio(peak, viewModel: viewModel))
            : nil
        if clipped && capIndex == grid.rowCount - 1 { capIndex = nil }
        clipCells[index].isHidden = !clipped
        meterColumns[index].apply(litRowCount: litCount, capRowIndex: capIndex, grid: grid, plotHeight: plotHeight)
    }
}

/// RGB 値から CGColor を直接組み立てる (SwiftUI Color 経由の変換を挟まない。Color.cgColor は
/// 環境依存の解決を伴いうるため、定数の色の変換はこちらのほうが単純で確実)。
func cgColor(_ rgb: EQLayout.RGB, alpha: Double = 1) -> CGColor {
    CGColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: alpha)
}

/// 1 バンド (EQ 本体) または 1 チャンネル (L/R レベルメーター) ぶんの消灯/点灯/キャップの各レイヤを
/// まとめて持つ。いずれも焼いた同じ帯画像の組を共有し、反映のたびに触るのは
/// 点灯の高さとキャップの位置/選択スライス/可視性だけ (消灯は静的)。
final class BandColumn {
    let dimLayer = CALayer()
    let litLayer = CALayer()
    let capLayer = CALayer()
    private var localX: CGFloat = 0
    private var barWidth: CGFloat = 0

    init(container: CALayer) {
        for layer in [dimLayer, litLayer, capLayer] {
            layer.actions = VisualizerHostView.disabledLayerActions
            layer.contentsGravity = .resize
            container.addSublayer(layer)
        }
    }

    /// レイアウト変更時 (拡大率・プロット高・L/R レベルメーター表示・焼き直し契機) にのみ呼ぶ。
    func layout(localX: CGFloat, barWidth: CGFloat, plotHeight: CGFloat, imageSet: BandImageSet, inEffect: Bool) {
        self.localX = localX
        self.barWidth = barWidth
        dimLayer.frame = CGRect(x: localX, y: 0, width: barWidth, height: plotHeight)
        dimLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        for layer in [dimLayer, litLayer, capLayer] {
            layer.contentsScale = imageSet.scale
        }
        setContents(inEffect: inEffect, imageSet: imageSet)
    }

    /// 素通し状態の遷移で画像の組を切り替える (焼き直しではなく contents の差し替えのみ)。
    func setContents(inEffect: Bool, imageSet: BandImageSet) {
        dimLayer.contents = inEffect ? imageSet.dimInEffect : imageSet.dimBypass
        litLayer.contents = inEffect ? imageSet.litInEffect : imageSet.litBypass
        capLayer.contents = inEffect ? imageSet.capInEffect : imageSet.litBypass
    }

    /// 反映するフレームで呼ぶ。点灯帯とキャップは排他 (同じ段を両方で塗らない):
    /// 重なる場合は点灯帯をその1段ぶん短くし、その段はキャップの色だけで描く。
    func apply(litRowCount: Int, capRowIndex: Int?, grid: EQLayout.SegmentGrid, plotHeight: CGFloat) {
        let litRowCount = capRowIndex == litRowCount - 1 ? litRowCount - 1 : litRowCount
        let litHeight = grid.litHeight(forRowCount: litRowCount)
        litLayer.frame = CGRect(x: localX, y: plotHeight - litHeight, width: barWidth, height: litHeight)
        if plotHeight > 0 {
            litLayer.contentsRect = CGRect(x: 0, y: (plotHeight - litHeight) / plotHeight, width: 1, height: litHeight / plotHeight)
        }
        guard let capRowIndex else {
            if !capLayer.isHidden { capLayer.isHidden = true }
            return
        }
        if capLayer.isHidden { capLayer.isHidden = false }
        let row = grid.rowY(capRowIndex)
        capLayer.frame = CGRect(x: localX, y: row.top, width: barWidth, height: row.bottom - row.top)
        if plotHeight > 0 {
            capLayer.contentsRect = CGRect(x: 0, y: row.top / plotHeight, width: 1, height: (row.bottom - row.top) / plotHeight)
        }
    }
}

/// L/R メーター列の chrome 反映に使う絶対座標の組 (ホスト座標系)。
struct MeterChromeGeometry {
    /// 列全体の矩形。
    let rect: CGRect
    /// L/R 各バーの矩形 (常に 2 枚)。
    let barRects: [CGRect]
}

/// EQ chrome (ゲイン範囲の白オーバーレイ / ハンドル線 / ドラッグ帯・バッジ / baseline / gutter /
/// dBFS 軸目盛り) のレイヤ一式。サブレイヤの並び順は合成順序に効く。崩さないこと。
@MainActor
final class EQChromeLayers {
    /// LED の奥に置くコンテナ。ゲイン範囲の白オーバーレイ (EQ バンドごと 1 枚 + L/R メーターぶん 2 枚) のみを持つ。
    let backChromeContainer = CALayer()
    /// LED・メーターの手前に置くコンテナ。
    let frontChromeContainer = CALayer()
    let handleLinesContainer = CALayer()
    let gainRangeLayers: [CALayer] = (0..<EQSpec.bandCount).map { _ in CALayer() }
    /// L/R メーターの各バーに対応するゲイン範囲の白オーバーレイ。
    let preampGainRangeLayers: [CALayer] = (0..<2).map { _ in CALayer() }
    let handleLineLayers: [CALayer] = (0..<EQSpec.bandCount).map { _ in CALayer() }
    /// L/R メーターをまたぐプリアンプハンドルの線。
    let preampHandleLineLayer = CALayer()
    let dragFillLayer = CALayer()
    /// L/R メーターの各バーに対応するドラッグ中の塗り。
    let preampDragFillLayers: [CALayer] = (0..<2).map { _ in CALayer() }
    let baselineLayer = CALayer()
    let gutterLayer = CALayer()
    let axisLayer = CALayer()
    let dragBadgeLayer = CALayer()

    /// baseline/gutter/axis を焼き直す契機。
    private struct ChromeBakeKey: Equatable {
        let scale: CGFloat
        let plotRect: CGRect
        let hostHeight: CGFloat
        let floorDb: Double
    }
    private var chromeBakeKey: ChromeBakeKey?

    /// ドラッグバッジを焼き直す契機。色は整数 dB の符号のみで決まるため鍵に含めない。
    private struct BadgeBakeKey: Equatable {
        let db: Int
        let scale: CGFloat
    }
    private var badgeBakeKey: BadgeBakeKey?
    /// 直近に焼いたバッジ画像の論理サイズ。
    private var badgeSize: CGSize = .zero

    init() {
        backChromeContainer.actions = VisualizerHostView.disabledLayerActions
        // 白オーバーレイは横方向に重ならないため、オフスクリーン合成バッファを作らせない。
        backChromeContainer.allowsGroupOpacity = false
        frontChromeContainer.actions = VisualizerHostView.disabledLayerActions
        handleLinesContainer.actions = VisualizerHostView.disabledLayerActions
        handleLinesContainer.allowsGroupOpacity = false

        for layer in gainRangeLayers + preampGainRangeLayers {
            layer.actions = VisualizerHostView.disabledLayerActions
            layer.contentsGravity = .resize
            backChromeContainer.addSublayer(layer)
        }
        for layer in handleLineLayers + [preampHandleLineLayer] {
            layer.actions = VisualizerHostView.disabledLayerActions
            // ハンドル線は単色の帯 (画像を貼らない)。太さ・幅とも一定の矩形のため焼く利得が無い。
            layer.backgroundColor = NSColor(EQLayout.handleLineColor).cgColor
            handleLinesContainer.addSublayer(layer)
        }
        for layer in [dragFillLayer, baselineLayer, gutterLayer, axisLayer, dragBadgeLayer] + preampDragFillLayers {
            layer.actions = VisualizerHostView.disabledLayerActions
            layer.contentsGravity = .resize
        }
        frontChromeContainer.addSublayer(handleLinesContainer)
        frontChromeContainer.addSublayer(dragFillLayer)
        for layer in preampDragFillLayers { frontChromeContainer.addSublayer(layer) }
        frontChromeContainer.addSublayer(baselineLayer)
        frontChromeContainer.addSublayer(gutterLayer)
        frontChromeContainer.addSublayer(axisLayer)
        frontChromeContainer.addSublayer(dragBadgeLayer)
    }

    // MARK: - レイアウト時 (拡大率・プロット矩形・ホスト高・フロア値が変わったときのみ)

    /// レイアウト時にのみ呼ぶ。コンテナの frame をホスト全域へ合わせ、焼き直し契機が変わっていれば
    /// baseline/gutter/axis を焼き直して静止配置する。
    func layout(hostBounds: CGRect, geo: EQPlotGeometry) {
        backChromeContainer.frame = hostBounds
        frontChromeContainer.frame = hostBounds

        let key = ChromeBakeKey(scale: geo.pixelGrid.scale, plotRect: geo.plotRect, hostHeight: geo.size.height, floorDb: geo.floorDb)
        guard chromeBakeKey != key, let chrome = ChromeImageBaker.bake(geo: geo) else { return }
        chromeBakeKey = key

        // gutter/axis はホスト上端 (y=0) から、baseline のみプロット矩形基準 (dB からの縦座標変換で db=0 を与えた位置) から置く。
        let rect = geo.plotRect
        baselineLayer.frame = CGRect(x: rect.minX, y: geo.dbToY(0), width: chrome.baselineSize.width, height: chrome.baselineSize.height)
        gutterLayer.frame = CGRect(x: geo.gutterCenterX - chrome.gutterSize.width / 2, y: 0, width: chrome.gutterSize.width, height: chrome.gutterSize.height)
        axisLayer.frame = CGRect(x: geo.gutterCenterX - chrome.axisSize.width / 2, y: 0, width: chrome.axisSize.width, height: chrome.axisSize.height)
        baselineLayer.contents = chrome.baseline
        gutterLayer.contents = chrome.gutter
        axisLayer.contents = chrome.axis
        for layer in [baselineLayer, gutterLayer, axisLayer] {
            layer.contentsScale = chrome.scale
        }
    }

    /// LED と共有する帯画像の組が焼き直された契機で呼ぶ。段の位相が LED と一致することを構造で保証する。
    func applyChromeFills(_ fills: BandImageSet.ChromeFills, scale: CGFloat) {
        for layer in gainRangeLayers + preampGainRangeLayers {
            layer.contents = fills.gainRange
            layer.contentsScale = scale
        }
        for layer in [dragFillLayer] + preampDragFillLayers {
            layer.contents = fills.dragBand
            layer.contentsScale = scale
        }
    }

    // MARK: - フレームごとの反映

    func applyFrame(viewModel: EQViewModel, geo: EQPlotGeometry, meter: MeterChromeGeometry?, showLevelMeter: Bool, inEffect: Bool) {
        let plotRect = geo.plotRect
        let plotHeight = plotRect.height
        // このグリッドの bottomY は plotRect.maxY (ホスト座標) を取る。backChromeContainer/
        // frontChromeContainer は frame = ホスト全域で、子はこのビューのローカル座標をそのまま使う。
        let grid = EQLayout.SegmentGrid(height: plotHeight, bottomY: plotRect.maxY, pixelGrid: geo.pixelGrid)
        let handleAlpha = viewModel.handleAlpha
        let handleVisible = handleAlpha >= EQLayout.handleVisibilityThreshold
        let displayGains = viewModel.handleDisplayGains
        let baselineY = geo.dbToY(0)

        backChromeContainer.isHidden = !(handleVisible && inEffect)
        backChromeContainer.opacity = Float(handleAlpha)
        for layer in preampGainRangeLayers { layer.isHidden = true }
        if !backChromeContainer.isHidden {
            for band in 0..<EQSpec.bandCount {
                let gy = geo.dbToY(displayGains[band])
                applyRange(
                    layer: gainRangeLayers[band], bar: geo.barRect(band),
                    top: min(baselineY, gy), bottom: max(baselineY, gy), grid: grid, plotTop: plotRect.minY, plotHeight: plotHeight
                )
            }
            if showLevelMeter, let meter {
                applyMeterRange(
                    layers: preampGainRangeLayers, bars: meter.barRects, targetY: geo.dbToY(viewModel.handleDisplayPreamp),
                    grid: grid, plotTop: plotRect.minY, plotHeight: plotHeight, baselineY: baselineY
                )
            }
        }

        handleLinesContainer.isHidden = !handleVisible
        handleLinesContainer.opacity = Float(handleAlpha)
        if handleVisible {
            let lineWidth = geo.barWidth + EQLayout.handleLineOverhang
            for band in 0..<EQSpec.bandCount {
                let cx = geo.columnCenterX(band)
                let ly = geo.dbToY(displayGains[band])
                handleLineLayers[band].frame = CGRect(
                    x: cx - lineWidth / 2, y: ly - EQLayout.handleLineWidth / 2,
                    width: lineWidth, height: EQLayout.handleLineWidth
                )
            }

            let preampVisible = showLevelMeter && meter != nil
            preampHandleLineLayer.isHidden = !preampVisible
            if preampVisible, let meter {
                let preampLineWidth = meter.rect.width + EQLayout.handleLineOverhang
                let py = geo.dbToY(viewModel.handleDisplayPreamp)
                preampHandleLineLayer.frame = CGRect(
                    x: meter.rect.midX - preampLineWidth / 2, y: py - EQLayout.handleLineWidth / 2,
                    width: preampLineWidth, height: EQLayout.handleLineWidth
                )
            }
        } else {
            preampHandleLineLayer.isHidden = true
        }

        baselineLayer.isHidden = !handleVisible
        baselineLayer.opacity = Float(handleAlpha)
        gutterLayer.isHidden = !handleVisible
        gutterLayer.opacity = Float(handleAlpha)

        // dBFS 軸目盛りはハンドル群と交差フェードする (アルファの補数)。
        let axisAlpha = 1 - handleAlpha
        let axisVisible = axisAlpha >= EQLayout.handleVisibilityThreshold
        axisLayer.isHidden = !axisVisible
        axisLayer.opacity = Float(axisAlpha)

        applyDrag(
            viewModel: viewModel, geo: geo, grid: grid, plotTop: plotRect.minY, plotHeight: plotHeight, baselineY: baselineY,
            inEffect: inEffect, meter: meter, showLevelMeter: showLevelMeter
        )
    }

    private func applyMeterRange(
        layers: [CALayer], bars: [CGRect], targetY: CGFloat,
        grid: EQLayout.SegmentGrid, plotTop: CGFloat, plotHeight: CGFloat, baselineY: CGFloat
    ) {
        for (layer, bar) in zip(layers, bars) {
            applyRange(
                layer: layer, bar: bar,
                top: min(baselineY, targetY), bottom: max(baselineY, targetY), grid: grid, plotTop: plotTop, plotHeight: plotHeight
            )
        }
    }

    private func applyRange(layer: CALayer, bar: CGRect, top: CGFloat, bottom: CGFloat, grid: EQLayout.SegmentGrid, plotTop: CGFloat, plotHeight: CGFloat) {
        guard let range = grid.rowIndexRange(intersectingTop: top, bottom: bottom) else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        let rectTop = grid.rowY(range.upperBound).top
        let rectBottom = grid.rowY(range.lowerBound).bottom
        layer.frame = CGRect(x: bar.minX, y: rectTop, width: bar.width, height: rectBottom - rectTop)
        guard plotHeight > 0 else { return }
        layer.contentsRect = CGRect(x: 0, y: (rectTop - plotTop) / plotHeight, width: 1, height: (rectBottom - rectTop) / plotHeight)
    }

    /// 両方が真になりうる場合は EQ 側を優先する。
    private func applyDrag(
        viewModel: EQViewModel, geo: EQPlotGeometry, grid: EQLayout.SegmentGrid, plotTop: CGFloat, plotHeight: CGFloat, baselineY: CGFloat,
        inEffect: Bool, meter: MeterChromeGeometry?, showLevelMeter: Bool
    ) {
        dragFillLayer.isHidden = true
        for layer in preampDragFillLayers { layer.isHidden = true }
        dragBadgeLayer.isHidden = true
        guard inEffect else { return }
        if let di = viewModel.dragIndex {
            let gy = geo.dbToY(viewModel.gains[di])
            applyRange(layer: dragFillLayer, bar: geo.barRect(di), top: min(baselineY, gy), bottom: max(baselineY, gy), grid: grid, plotTop: plotTop, plotHeight: plotHeight)
            applyDragBadge(
                db: Int(viewModel.gains[di].rounded()), scale: geo.pixelGrid.scale,
                anchorCenterX: geo.columnCenterX(di), anchorHalfWidth: geo.barWidth / 2, y: gy, clampRect: geo.plotRect
            )
            return
        }
        guard viewModel.draggingPreamp, showLevelMeter, let meter else { return }
        let preampY = geo.dbToY(viewModel.preampDb)
        applyMeterRange(
            layers: preampDragFillLayers, bars: meter.barRects, targetY: preampY,
            grid: grid, plotTop: plotTop, plotHeight: plotHeight, baselineY: baselineY
        )
        let plotRect = geo.plotRect
        let clampRect = CGRect(x: plotRect.minX, y: plotRect.minY, width: meter.rect.maxX - plotRect.minX, height: plotRect.height)
        applyDragBadge(
            db: Int(viewModel.preampDb.rounded()), scale: geo.pixelGrid.scale,
            anchorCenterX: meter.rect.midX, anchorHalfWidth: meter.rect.width / 2, y: preampY, clampRect: clampRect
        )
    }

    /// バッジを焼き直し、位置決めのクランプ規則 (右へ出す→はみ出すなら左へ反転、縦はクランプ) で配置する。
    private func applyDragBadge(db: Int, scale: CGFloat, anchorCenterX: CGFloat, anchorHalfWidth: CGFloat, y: CGFloat, clampRect: CGRect) {
        let key = BadgeBakeKey(db: db, scale: scale)
        if badgeBakeKey != key {
            guard let badge = DragBadgeBaker.bake(db: db, scale: scale) else {
                dragBadgeLayer.isHidden = true
                return
            }
            badgeBakeKey = key
            badgeSize = badge.size
            dragBadgeLayer.contents = badge.image
            dragBadgeLayer.contentsScale = scale
        }
        dragBadgeLayer.isHidden = false

        let gap: CGFloat = 8
        let halfWidth = badgeSize.width / 2
        let halfHeight = badgeSize.height / 2
        var cxBadge = anchorCenterX + anchorHalfWidth + gap + halfWidth
        if cxBadge + halfWidth > clampRect.maxX {
            cxBadge = anchorCenterX - anchorHalfWidth - gap - halfWidth
        }
        let cyBadge = min(max(y, clampRect.minY + halfHeight), clampRect.maxY - halfHeight)
        dragBadgeLayer.frame = CGRect(x: cxBadge - halfWidth, y: cyBadge - halfHeight, width: badgeSize.width, height: badgeSize.height)
    }
}

/// CGImage を「y 下方向論理座標」(y=0 が画像の論理上端) で焼くための共通の土台。CALayer 側の
/// contentsRect もこれと同じ規約で解釈されることを実機検証済み。
private func bakeImage(logicalSize: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
    guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }
    let pixelWidth = Int((logicalSize.width * scale).rounded())
    let pixelHeight = Int((logicalSize.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    guard let ctx = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx)
    return ctx.makeImage()
}

/// 焼き付け先 (y 下方向に反転済みの CTM を持つ CGContext) へ文字を中央合わせで描く。文字の向きは
/// CTM の反転だけでは揃わないため、flipped:true の NSGraphicsContext を明示的に push する。
private func drawCenteredText(_ text: String, font: NSFont, color: Color, center: CGPoint, in ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(color)]
    let size = (text as NSString).size(withAttributes: attrs)
    let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    (text as NSString).draw(at: origin, withAttributes: attrs)
    NSGraphicsContext.current = previous
}

/// EQ 本体・L/R レベルメーターと EQ chrome が共有する帯画像 7 種の集合 (消灯/点灯 × 効いている/
/// 素通し + キャップ + ゲイン範囲の白オーバーレイ用 + ドラッグ帯用)。幅はバー幅の上限値で焼き、
/// 実際のバー幅へは横方向の伸縮で対応する。EQ 本体・レベルメーター・chrome が同じ縞パスを
/// 共有することで、白オーバーレイ・ドラッグ帯が LED と段の位置がずれることを構造的に避ける。
struct BandImageSet {
    let dimInEffect: CGImage
    let litInEffect: CGImage
    let dimBypass: CGImage
    let litBypass: CGImage
    let capInEffect: CGImage
    /// chrome を持たない側では焼かない。
    let chromeFills: ChromeFills?

    struct ChromeFills {
        let gainRange: CGImage
        let dragBand: CGImage
    }
    /// 焼いた画素寸法の元になった拡大率。段の矩形は必ずこの値で解釈する (window から都度
    /// 読み直す値とは、拡大率が変わる瞬間に食い違いうるため)。
    let scale: CGFloat
}

/// 帯画像の組を焼く。焼き直す契機は (1) 拡大率の変化、(2) プロット高の変化、(3) ピークキャップの
/// 明るさ寄せ量の設定変更の 3 つ。素通し状態の遷移は焼き直さず、画像の組の切り替えのみで
/// 対応する。
enum BandImageBaker {
    static func bake(
        plotHeight: CGFloat, pixelGrid: EQLayout.PixelGrid, peakCapBrightenAmount: Double, rowCount: Int?,
        includesChrome: Bool
    ) -> BandImageSet? {
        let scale = pixelGrid.scale
        guard plotHeight > 0 else { return nil }

        let grid = EQLayout.SegmentGrid(
            height: plotHeight, bottomY: plotHeight, pixelGrid: pixelGrid, rowCount: rowCount
        )

        // 消灯帯・点灯帯・chrome の 2 種は段の矩形を束ねた縞パスでクリップし、段の間の隙間を
        // 透明に抜く。キャップ帯は段ぴったりのスライスしか使わないため縞は要らず、全高を塗る。
        let stripedPath = CGMutablePath()
        for i in 0..<grid.rowCount {
            let row = grid.rowY(i)
            stripedPath.addRect(CGRect(x: 0, y: row.top, width: EQLayout.barWidthMax, height: row.bottom - row.top))
        }
        let fullPath = CGPath(rect: CGRect(x: 0, y: 0, width: EQLayout.barWidthMax, height: plotHeight), transform: nil)
        let logicalSize = CGSize(width: EQLayout.barWidthMax, height: plotHeight)

        func makeImage(clipPath: CGPath, fill: (CGContext) -> Void) -> CGImage? {
            bakeImage(logicalSize: logicalSize, scale: scale) { ctx in
                ctx.saveGState()
                ctx.addPath(clipPath)
                ctx.clip()
                fill(ctx)
                ctx.restoreGState()
            }
        }

        // 縦方向の連続グラデーション (teal→blue→magenta) を焼き込む。
        func gradientFill(alpha: Double, brighten: Double = 0) -> (CGContext) -> Void {
            let stops = [0.0, 0.5, 1.0].map {
                cgColor(EQLayout.segmentColor(atRatio: $0).brightened(brighten, toward: EQLayout.handleTintRGB), alpha: alpha)
            }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops as CFArray, locations: [0, 0.5, 1]) else {
                return { _ in }
            }
            return { ctx in
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plotHeight), end: CGPoint(x: 0, y: 0), options: [])
            }
        }
        func solidFill(_ rgb: EQLayout.RGB, alpha: Double) -> (CGContext) -> Void {
            let color = cgColor(rgb, alpha: alpha)
            return { ctx in
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: 0, y: 0, width: EQLayout.barWidthMax, height: plotHeight))
            }
        }
        func solidColorFill(_ color: Color) -> (CGContext) -> Void {
            let cgColor = NSColor(color).cgColor
            return { ctx in
                ctx.setFillColor(cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: EQLayout.barWidthMax, height: plotHeight))
            }
        }

        guard
            let dimInEffect = makeImage(clipPath: stripedPath, fill: gradientFill(alpha: EQLayout.segmentDimAlpha)),
            let litInEffect = makeImage(clipPath: stripedPath, fill: gradientFill(alpha: EQLayout.segmentLitAlpha)),
            let dimBypass = makeImage(clipPath: stripedPath, fill: solidFill(EQLayout.bypassSegmentRGB, alpha: EQLayout.bypassDimAlpha)),
            let litBypass = makeImage(clipPath: stripedPath, fill: solidFill(EQLayout.bypassSegmentRGB, alpha: EQLayout.bypassLitAlpha)),
            let capInEffect = makeImage(
                clipPath: fullPath, fill: gradientFill(alpha: EQLayout.peakCapAlpha, brighten: peakCapBrightenAmount)
            )
        else { return nil }

        var chromeFills: BandImageSet.ChromeFills?
        if includesChrome {
            guard
                let range = makeImage(clipPath: stripedPath, fill: solidColorFill(EQLayout.gainRangeFillColor)),
                let drag = makeImage(clipPath: stripedPath, fill: solidColorFill(EQLayout.dragBandFillColor))
            else { return nil }
            chromeFills = BandImageSet.ChromeFills(gainRange: range, dragBand: drag)
        }

        return BandImageSet(
            dimInEffect: dimInEffect, litInEffect: litInEffect, dimBypass: dimBypass, litBypass: litBypass,
            capInEffect: capInEffect, chromeFills: chromeFills, scale: scale
        )
    }
}

/// baseline (0dB 破線) / gutter (+/−/0 記号) / dBFS 軸目盛りの、chrome のうち「不透明度のみで
/// 変わる」要素が焼く画像の組。位置決め (レイヤ frame の原点) は呼び出し側が
/// 幾何から都度決めるため、ここでは論理サイズだけを添えて返す。
struct ChromeImageSet {
    let baseline: CGImage
    let baselineSize: CGSize
    let gutter: CGImage
    let gutterSize: CGSize
    let axis: CGImage
    let axisSize: CGSize
    /// 焼いた画素寸法の元になった拡大率。
    let scale: CGFloat
}

/// 画像の組を焼く。焼き直す契機は (拡大率, プロット矩形, ホスト高, フロア値) の組が
/// 変わったとき (呼び出し側が Equatable な鍵でこれを判定する)。
enum ChromeImageBaker {
    nonisolated(unsafe) static let gutterSignFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
    nonisolated(unsafe) static let gutterZeroFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    nonisolated(unsafe) static let axisTickFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    /// gutter/axis の画像幅を決める式のうち、文字の左右に足す余白ぶん。
    static let labelHorizontalMargin: CGFloat = 6

    static func bake(geo: EQPlotGeometry) -> ChromeImageSet? {
        let scale = geo.pixelGrid.scale
        let hostHeight = geo.size.height
        let rect = geo.plotRect
        guard hostHeight > 0, rect.width > 0 else { return nil }

        let baselineSize = CGSize(width: rect.width, height: 1)
        guard let baseline = bakeImage(logicalSize: baselineSize, scale: scale, draw: { ctx in
            ctx.setStrokeColor(NSColor(EQLayout.baselineColor).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: EQLayout.baselineDash)
            ctx.move(to: CGPoint(x: 0, y: 0.5))
            ctx.addLine(to: CGPoint(x: rect.width, y: 0.5))
            ctx.strokePath()
        }) else { return nil }

        func maxCharWidth(_ labels: [String], font: NSFont) -> CGFloat {
            labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }
        let gutterCharWidth = maxCharWidth(["+", "−", "0"], font: gutterSignFont)
        let gutterWidth = max(EQLayout.Padding.left, gutterCharWidth + labelHorizontalMargin * 2)
        let gutterSize = CGSize(width: gutterWidth, height: hostHeight)
        guard let gutter = bakeImage(logicalSize: gutterSize, scale: scale, draw: { ctx in
            let cx = gutterWidth / 2
            drawCenteredText("+", font: gutterSignFont, color: EQLayout.gutterSignColor, center: CGPoint(x: cx, y: rect.minY + 6), in: ctx)
            drawCenteredText("−", font: gutterSignFont, color: EQLayout.gutterSignColor, center: CGPoint(x: cx, y: rect.maxY + 1), in: ctx)
            drawCenteredText("0", font: gutterZeroFont, color: EQLayout.gutterZeroColor, center: CGPoint(x: cx, y: geo.dbToY(0) + 3), in: ctx)
        }) else { return nil }

        // 最も桁の多いラベルでも切れない幅を、実際のラベル文字列から都度求める。
        let ticks = EQLayout.axisDbTicks(floorDb: geo.floorDb)
        let tickLabels = ticks.map { String(Int($0)) }
        let axisWidth = max(EQLayout.Padding.left, maxCharWidth(tickLabels, font: axisTickFont) + labelHorizontalMargin * 2)
        let axisSize = CGSize(width: axisWidth, height: hostHeight)
        guard let axis = bakeImage(logicalSize: axisSize, scale: scale, draw: { ctx in
            let cx = axisWidth / 2
            for (tick, label) in zip(ticks, tickLabels) {
                drawCenteredText(label, font: axisTickFont, color: EQLayout.axisDbColor, center: CGPoint(x: cx, y: geo.levelDbToY(tick) + 3), in: ctx)
            }
        }) else { return nil }

        return ChromeImageSet(
            baseline: baseline, baselineSize: baselineSize, gutter: gutter, gutterSize: gutterSize,
            axis: axis, axisSize: axisSize, scale: scale
        )
    }
}

/// ドラッグ中バッジ (背景の角丸矩形 + dB 数値) を焼いた画像と論理サイズの組。
struct DragBadgeImage {
    let image: CGImage
    /// 論理サイズ (pt)。位置決めは呼び出し側が反映のたびに行う。
    let size: CGSize
}

/// ドラッグ中バッジの焼き口。色の出し分け (boost/cut/zero) は整数 dB の符号だけから決まるため、
/// 焼き直しの鍵に色を含める必要はない。
enum DragBadgeBaker {
    nonisolated(unsafe) static let font = NSFont.boldSystemFont(ofSize: 13)
    static let paddingH: CGFloat = 8
    static let paddingV: CGFloat = 4

    /// db は表示に使う整数 dB (呼び出し側が各バンドのゲイン値[band].rounded() から求めて渡す)。
    static func bake(db: Int, scale: CGFloat) -> DragBadgeImage? {
        let label = db > 0 ? "+\(db)" : "\(db)"
        let color: Color = db > 0 ? EQLayout.dragValueBoostColor : (db < 0 ? EQLayout.dragValueCutColor : EQLayout.dragValueZeroColor)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: textSize.width + paddingH * 2, height: textSize.height + paddingV * 2)
        guard let image = bakeImage(logicalSize: size, scale: scale, draw: { ctx in
            let backgroundPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil
            )
            ctx.addPath(backgroundPath)
            ctx.setFillColor(NSColor(EQLayout.dragBadgeBackgroundColor).cgColor)
            ctx.fillPath()
            drawCenteredText(label, font: font, color: color, center: CGPoint(x: size.width / 2, y: size.height / 2), in: ctx)
        }) else { return nil }
        return DragBadgeImage(image: image, size: size)
    }
}
