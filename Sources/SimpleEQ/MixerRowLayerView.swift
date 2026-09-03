import AppKit
import QuartzCore
import SwiftUI

/// 行のメーターを 1 本のタイマで駆動する。表示値の取り出しは 1 フレームに 1 回だけ行い
/// (取り出しでピークが 0 へ戻るため)、結果を各行へ配る。
@MainActor
final class MixerRenderClock {
    private let levelStore: MixerLevelStore
    private let viewModel: EQViewModel
    private var samples: [MixerLevelStore.Sample]
    private var slotIndexByClientID: [UInt32: Int] = [:]
    /// クリップは取りこぼしてはならない判定なので、表示用のピークとは別にカウンタの差分で見る。
    private var lastClipCounts: [UInt32]
    private var clippedSlots: Set<Int> = []
    private let views = NSHashTable<MixerRowLayerView>.weakObjects()
    private var timer: Timer?

    init(levelStore: MixerLevelStore, viewModel: EQViewModel) {
        self.levelStore = levelStore
        self.viewModel = viewModel
        samples = levelStore.makeSampleBuffer()
        lastClipCounts = Array(repeating: 0, count: levelStore.slotCount)
    }

    var attackCoef: Double { viewModel.attackCoef }
    var releaseCoef: Double { viewModel.releaseCoef }
    var isRunning: Bool { timer != nil }

    /// 見えているかどうかを受ける。行の出入りだけでは止まらない。
    /// 偽で始まるため、はじめて見えた回も 2 回目以降と同じ経路を通る。
    var active = false {
        didSet {
            guard active != oldValue else { return }
            guard active else { return stop() }
            discardValuesAccumulatedWhileStopped()
            start()
        }
    }

    func add(_ view: MixerRowLayerView) {
        views.add(view)
        start()
    }

    func remove(_ view: MixerRowLayerView) {
        views.remove(view)
        if views.count == 0 { stop() }
    }

    /// 対象のクライアント群のうち最大の充填比と、この回にクリップが届いたか。
    func level(forClientIDs clientIDs: [UInt32]) -> (ratio: Double, clipped: Bool) {
        var ratio: Double = 0
        var clipped = false
        for clientID in clientIDs {
            guard let index = slotIndexByClientID[clientID] else { continue }
            let peak = samples[index].peak
            if peak > 0 {
                ratio = max(ratio, LevelMeterRenderer.levelRatio(Double(20 * log10(peak)), viewModel: viewModel))
            }
            if clippedSlots.contains(index) { clipped = true }
        }
        return (ratio, clipped)
    }

    private var appliedFps: Double?

    private func start() {
        guard active, views.count > 0 else { return }
        guard timer == nil || appliedFps != viewModel.visualizerFps else { return }
        if timer == nil { discardValuesAccumulatedWhileStopped() }
        stop()
        appliedFps = viewModel.visualizerFps
        let timer = Timer.scheduledTimer(withTimeInterval: 1 / viewModel.visualizerFps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        appliedFps = nil
    }

    /// 止まっている間もピークは溜まり、クリップの数も進む。
    private func discardValuesAccumulatedWhileStopped() {
        levelStore.takeSamples(into: &samples)
        for index in samples.indices { lastClipCounts[index] = samples[index].clipEventCount }
        for view in views.allObjects { view.resetDisplayedLevel() }
    }

    func tick() {
        start()
        levelStore.takeSamples(into: &samples)
        slotIndexByClientID.removeAll(keepingCapacity: true)
        clippedSlots.removeAll(keepingCapacity: true)
        for index in samples.indices {
            let sample = samples[index]
            if sample.clientID != 0 { slotIndexByClientID[sample.clientID] = index }
            // 席が再利用されるとカウンタは 0 から数え直しになるため、後退は差分にしない。
            if sample.clipEventCount > lastClipCounts[index] { clippedSlots.insert(index) }
            lastClipCounts[index] = sample.clipEventCount
        }
        for view in views.allObjects { view.applyFrame(clock: self) }
    }
}

/// 行のスライダー・dB 値・メーターを CALayer の幾何更新で描く。
final class MixerRowLayerView: NSView {
    var clientIDs: [UInt32] = []
    var enabled = true
    var muted = false
    var onGainChange: ((Double) -> Void)?
    var onGainCommit: (() -> Void)?

    private let track = CALayer()
    private let fill = CALayer()
    private let knob = CALayer()
    private let valueText = CATextLayer()
    private var segments: [CALayer] = []

    private var position: Double
    private(set) var smoothedRatio: Double = 0
    /// 段の幾何はレイアウトが変わったときだけ決まる。毎フレーム組み立て直さない。
    private var segmentGrid: EQLayout.SegmentGrid?
    private weak var clock: MixerRenderClock?

    init(gain: Double, muted: Bool, enabled: Bool, clock: MixerRenderClock?) {
        self.position = MixerGainScale.position(ofGain: gain)
        self.muted = muted
        self.enabled = enabled
        self.clock = clock
        super.init(frame: .zero)
        wantsLayer = true
        setUpLayerTree()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 操作できない間はポインタもフォーカスも通さない。
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clock?.remove(self) } else { clock?.add(self) }
    }

    private func setUpLayerTree() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, fill, knob] {
            layer.actions = VisualizerHostView.disabledLayerActions
            root.addSublayer(layer)
        }
        track.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        fill.backgroundColor = NSColor(EQLayout.Palette.cyan).cgColor
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = EQLayout.Mixer.sliderKnobDiameter / 2
        track.cornerRadius = EQLayout.Mixer.sliderTrackHeight / 2
        fill.cornerRadius = EQLayout.Mixer.sliderTrackHeight / 2

        valueText.actions = VisualizerHostView.disabledLayerActions
        valueText.alignmentMode = .right
        valueText.font = NSFont.monospacedDigitSystemFont(ofSize: valueFontSize, weight: .bold)
        valueText.fontSize = valueFontSize
        valueText.foregroundColor = NSColor(EQLayout.Palette.cyanSoft).cgColor
        root.addSublayer(valueText)

        segments = (0..<EQLayout.Mixer.meterSegmentCount).map { _ in
            let segment = CALayer()
            segment.actions = VisualizerHostView.disabledLayerActions
            segment.cornerRadius = 1
            root.addSublayer(segment)
            return segment
        }
        CATransaction.commit()
    }

    private let valueFontSize: CGFloat = 12

    // MARK: - 反映

    func update(gain: Double, muted: Bool, enabled: Bool, clientIDs: [UInt32]) {
        self.muted = muted
        self.enabled = enabled
        self.clientIDs = clientIDs
        position = MixerGainScale.position(ofGain: gain)
        applyGeometry()
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyGeometry()
    }

    private var pixelGrid: EQLayout.PixelGrid {
        EQLayout.PixelGrid(scale: window?.backingScaleFactor ?? 1)
    }

    private var meterRect: CGRect {
        CGRect(
            x: bounds.maxX - EQLayout.Mixer.meterWidth,
            y: (bounds.height - EQLayout.Mixer.meterHeight) / 2,
            width: EQLayout.Mixer.meterWidth, height: EQLayout.Mixer.meterHeight
        )
    }

    private var valueRect: CGRect {
        CGRect(
            x: meterRect.minX - EQLayout.Mixer.rowSpacing - EQLayout.Mixer.valueColumnWidth,
            y: (bounds.height - valueFontSize * 1.2) / 2,
            width: EQLayout.Mixer.valueColumnWidth, height: valueFontSize * 1.2
        )
    }

    /// 左端はノブの半径ぶん空ける。位置 0 のノブが隣の要素へはみ出さない。
    private var sliderRect: CGRect {
        let originX = EQLayout.Mixer.sliderKnobDiameter / 2
        let width = max(0, valueRect.minX - EQLayout.Mixer.rowSpacing - originX)
        return CGRect(x: originX, y: 0, width: width, height: bounds.height)
    }

    private func applyGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let dimmed = muted ? 0.4 : 1
        let slider = sliderRect
        let trackY = (bounds.height - EQLayout.Mixer.sliderTrackHeight) / 2
        track.frame = CGRect(x: slider.minX, y: trackY, width: slider.width, height: EQLayout.Mixer.sliderTrackHeight)
        fill.frame = CGRect(x: slider.minX, y: trackY, width: slider.width * position, height: EQLayout.Mixer.sliderTrackHeight)
        knob.frame = CGRect(
            x: slider.minX + slider.width * position - EQLayout.Mixer.sliderKnobDiameter / 2,
            y: (bounds.height - EQLayout.Mixer.sliderKnobDiameter) / 2,
            width: EQLayout.Mixer.sliderKnobDiameter, height: EQLayout.Mixer.sliderKnobDiameter
        )
        track.opacity = Float(dimmed)
        fill.opacity = Float(dimmed)
        knob.opacity = Float(dimmed)

        valueText.frame = valueRect
        valueText.contentsScale = pixelGrid.scale
        valueText.string = muted
            ? MixerGainScale.mutedText
            : MixerGainScale.text(forGain: MixerGainScale.gain(atPosition: position))
        valueText.opacity = Float(dimmed)

        applySegmentGeometry()
    }

    /// 縦横の違いは、段の進行方向をどちらの辺に取るかだけに閉じ込める。
    private func makeSegmentGrid() -> EQLayout.SegmentGrid {
        EQLayout.SegmentGrid(
            height: meterRect.width, bottomY: meterRect.width,
            pixelGrid: pixelGrid, rowCount: EQLayout.Mixer.meterSegmentCount
        )
    }

    private func applySegmentGeometry() {
        let grid = makeSegmentGrid()
        segmentGrid = grid
        let rect = meterRect
        for (index, segment) in segments.enumerated() {
            guard index < grid.rowCount else {
                segment.isHidden = true
                continue
            }
            segment.isHidden = false
            let span = grid.rowY(index)
            segment.frame = CGRect(
                x: rect.minX + (rect.width - span.bottom), y: rect.minY,
                width: max(0, span.bottom - span.top), height: rect.height
            )
        }
        applyMeter(ratio: smoothedRatio, clipped: false)
    }

    /// 残しておくと、次のフレームが届くまで止まる前の高さを見せてしまう。
    func resetDisplayedLevel() {
        smoothedRatio = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMeter(ratio: 0, clipped: false)
        CATransaction.commit()
    }

    func applyFrame(clock: MixerRenderClock) {
        let level = clock.level(forClientIDs: clientIDs)
        smoothedRatio = LevelMeter.smoothed(
            prev: smoothedRatio, target: level.ratio, attack: clock.attackCoef, release: clock.releaseCoef
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMeter(ratio: smoothedRatio, clipped: level.clipped)
        CATransaction.commit()
    }

    private func applyMeter(ratio: Double, clipped: Bool) {
        guard let segmentGrid else { return }
        let lit = segmentGrid.litRowCountByRatio(ratio)
        let last = segments.count - 1
        for (index, segment) in segments.enumerated() {
            if index == last, clipped {
                segment.backgroundColor = Self.clipColor
                continue
            }
            segment.backgroundColor = index < lit ? Self.litColors[index] : Self.dimColors[index]
        }
    }

    /// 段の色は添字と点灯の有無だけで決まる。
    private static let litColors = segmentColors(alpha: EQLayout.segmentLitAlpha)
    private static let dimColors = segmentColors(alpha: EQLayout.segmentDimAlpha)
    private static let clipColor = NSColor(EQLayout.Palette.clip).cgColor

    private static func segmentColors(alpha: Double) -> [CGColor] {
        let last = EQLayout.Mixer.meterSegmentCount - 1
        return (0...last).map {
            cgColor(EQLayout.segmentColor(atRatio: Double($0) / Double(max(1, last))), alpha: alpha)
        }
    }

    // MARK: - ドラッグ

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        applyDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled else { return }
        applyDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        onGainCommit?()
    }

    private func applyDrag(with event: NSEvent) {
        let slider = sliderRect
        guard slider.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x - slider.minX
        position = min(1, max(0, Double(x / slider.width)))
        applyGeometry()
        onGainChange?(MixerGainScale.gain(atPosition: position))
    }
}

/// 行の操作面を SwiftUI へ橋渡しする。
struct MixerRowControls: NSViewRepresentable {
    @ObservedObject var model: MixerModel
    let channel: MixerModel.Channel
    let enabled: Bool
    let clock: MixerRenderClock?

    func makeNSView(context: Context) -> MixerRowLayerView {
        let view = MixerRowLayerView(
            gain: channel.gain, muted: channel.muted, enabled: enabled, clock: clock
        )
        view.onGainChange = { model.updateGainDuringDrag($0, for: channel.key) }
        view.onGainCommit = { model.commitGain(for: channel.key) }
        return view
    }

    func updateNSView(_ nsView: MixerRowLayerView, context: Context) {
        nsView.onGainChange = { model.updateGainDuringDrag($0, for: channel.key) }
        nsView.onGainCommit = { model.commitGain(for: channel.key) }
        nsView.update(
            gain: model.gain(for: channel.key), muted: channel.muted, enabled: enabled,
            clientIDs: model.clientIDsByChannelKey[channel.key] ?? []
        )
    }
}
