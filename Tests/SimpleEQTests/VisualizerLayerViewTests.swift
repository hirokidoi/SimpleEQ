import AppKit
import SwiftUI
import XCTest
@testable import SimpleEQ

/// 出荷時ウィンドウのホストビュー高さ (寸法定数から導出、実寸をハードコードしない)。
private let shippedHostHeight =
    EQLayout.windowDefaultSize.height - EQLayout.topBarHeight - EQLayout.freqRowHeight

@MainActor
final class VisualizerTimerGateTests: XCTestCase {
    func testRunsOnlyWhenBothFlagsAreTrue() {
        XCTAssertTrue(VisualizerTimerGate.shouldRun(visualizerActive: true, hostViewVisible: true))
        XCTAssertFalse(VisualizerTimerGate.shouldRun(visualizerActive: true, hostViewVisible: false))
        XCTAssertFalse(VisualizerTimerGate.shouldRun(visualizerActive: false, hostViewVisible: true))
        XCTAssertFalse(VisualizerTimerGate.shouldRun(visualizerActive: false, hostViewVisible: false))
    }
}

/// 焼き込みと段位置が同一の情報源から出ていることを、透明/不透明のサンプリングで確認する。
@MainActor
final class BandImageBakerTests: XCTestCase {
    private let plotHeight: CGFloat = 200

    func testPixelDimensionsMatchRoundedLogicalSizeTimesScale() {
        for scale: CGFloat in [1, 2, 1.5, 3] {
            let pixelGrid = EQLayout.PixelGrid(scale: scale)
            let snappedHeight = pixelGrid.snap(plotHeight)
            guard let set = BandImageBaker.bake(plotHeight: snappedHeight, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true) else {
                XCTFail("scale=\(scale) で焼けなかった")
                continue
            }
            let expectedHeight = Int((snappedHeight * scale).rounded())
            let expectedWidth = Int((EQLayout.barWidthMax * scale).rounded())
            for image in [set.dimInEffect, set.litInEffect, set.dimBypass, set.litBypass, set.capInEffect] {
                XCTAssertEqual(image.height, expectedHeight, "scale=\(scale)")
                XCTAssertEqual(image.width, expectedWidth, "scale=\(scale)")
            }
            XCTAssertEqual(set.scale, scale)
        }
    }

    func testReturnsNilForNonPositivePlotHeight() {
        let pixelGrid = EQLayout.PixelGrid(scale: 1)
        XCTAssertNil(BandImageBaker.bake(plotHeight: 0, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true))
        XCTAssertNil(BandImageBaker.bake(plotHeight: -10, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true))
    }

    // 段の矩形の内側は不透明、段の間の隙間は透明であること。
    func testStripedImagesAreOpaqueWithinRowsAndTransparentInGaps() {
        let scale: CGFloat = 2
        let pixelGrid = EQLayout.PixelGrid(scale: scale)
        let snappedHeight = pixelGrid.snap(plotHeight)
        let grid = EQLayout.SegmentGrid(height: snappedHeight, bottomY: snappedHeight, pixelGrid: pixelGrid)
        guard let set = BandImageBaker.bake(plotHeight: snappedHeight, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true) else {
            return XCTFail("焼けなかった")
        }
        XCTAssertGreaterThan(grid.rowCount, 2, "前提: 隙間を挟む段が複数あること")

        for image in [set.litInEffect, set.dimInEffect, set.litBypass, set.dimBypass] {
            for i in 0..<grid.rowCount {
                let row = grid.rowY(i)
                let midY = (row.top + row.bottom) / 2
                XCTAssertGreaterThan(alpha(of: image, logicalY: midY, scale: scale), 0, "段 \(i) の内側は不透明であること")
            }
            for i in 0..<(grid.rowCount - 1) {
                // 段 i (下) と段 i+1 (上) の間の隙間の中点。
                let gapY = (grid.rowY(i).top + grid.rowY(i + 1).bottom) / 2
                XCTAssertEqual(alpha(of: image, logicalY: gapY, scale: scale), 0, "段 \(i)/\(i + 1) の間の隙間は透明であること")
            }
        }
    }

    // キャップ帯は段ぴったりのスライスしか使わないため縞を持たず、プロット全高が不透明であること。
    func testCapImageHasNoStripeAndIsOpaqueThroughout() {
        let scale: CGFloat = 2
        let pixelGrid = EQLayout.PixelGrid(scale: scale)
        let snappedHeight = pixelGrid.snap(plotHeight)
        let grid = EQLayout.SegmentGrid(height: snappedHeight, bottomY: snappedHeight, pixelGrid: pixelGrid)
        guard let set = BandImageBaker.bake(plotHeight: snappedHeight, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true) else {
            return XCTFail("焼けなかった")
        }
        for i in 0..<(grid.rowCount - 1) {
            let gapY = (grid.rowY(i).top + grid.rowY(i + 1).bottom) / 2
            XCTAssertGreaterThan(alpha(of: set.capInEffect, logicalY: gapY, scale: scale), 0, "段 \(i)/\(i + 1) の間もキャップ帯は不透明")
        }
    }

    // bypass はグレー、効いている帯は色相グラデーションであること (厳密一致ではなく構造的な差だけを見る)。
    func testBypassImagesAreGreyUnlikeTheInEffectGradient() {
        let scale: CGFloat = 1
        let pixelGrid = EQLayout.PixelGrid(scale: scale)
        let snappedHeight = pixelGrid.snap(plotHeight)
        let grid = EQLayout.SegmentGrid(height: snappedHeight, bottomY: snappedHeight, pixelGrid: pixelGrid)
        guard let set = BandImageBaker.bake(plotHeight: snappedHeight, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true) else {
            return XCTFail("焼けなかった")
        }
        let sampleY = (grid.rowY(0).top + grid.rowY(0).bottom) / 2
        let bypass = rgb(of: set.litBypass, logicalY: sampleY, scale: scale)
        let inEffect = rgb(of: set.litInEffect, logicalY: sampleY, scale: scale)

        func maxComponentSpread(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
            let values = [Int(c.r), Int(c.g), Int(c.b)]
            return values.max()! - values.min()!
        }
        XCTAssertLessThanOrEqual(maxComponentSpread(bypass), 10, "bypass はグレー (R≈G≈B) であること")
        XCTAssertGreaterThan(maxComponentSpread(inEffect), 20, "効いている帯は teal 寄りの色で R/G/B が離れていること (前提)")
    }

    // MARK: - ピクセルサンプリング

    /// 画像の指定 (焼く側と同じ y 下方向論理座標) の位置のアルファ値 (0...255) を返す。
    private func alpha(of image: CGImage, logicalY: CGFloat, scale: CGFloat) -> UInt8 {
        pixel(image, logicalY: logicalY, scale: scale).a
    }

    private func rgb(of image: CGImage, logicalY: CGFloat, scale: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8) {
        let p = pixel(image, logicalY: logicalY, scale: scale)
        return (p.r, p.g, p.b)
    }

    /// premultipliedLast (R,G,B,A) 8bit/component の前提で読む (焼く側の bitmapInfo と対で保守する)。
    private func pixel(_ image: CGImage, logicalY: CGFloat, scale: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
            XCTFail("画像データを取得できなかった")
            return (0, 0, 0, 0)
        }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        let row = min(image.height - 1, max(0, Int(logicalY * scale)))
        let x = image.width / 2
        let offset = row * bytesPerRow + x * bytesPerPixel
        return (ptr[offset], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
    }
}

/// CGImage のバッキングデータを直接読む共通ヘルパー。premultipliedLast (R,G,B,A) 8bit/component の前提で読む。
private func rawPixel(_ image: CGImage, pixelX: Int, pixelY: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else {
        return (0, 0, 0, 0)
    }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    let x = min(image.width - 1, max(0, pixelX))
    let y = min(image.height - 1, max(0, pixelY))
    let offset = y * bytesPerRow + x * bytesPerPixel
    return (ptr[offset], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
}

/// 中心が塗られているとは限らない字形もあるため (例: "0")、点ではなく小さな面で不透明画素の有無を見る。
private func hasInk(_ image: CGImage, logicalX: CGFloat, logicalY: CGFloat, scale: CGFloat, radius: CGFloat = 7) -> Bool {
    let minX = Int(((logicalX - radius) * scale).rounded(.down))
    let maxX = Int(((logicalX + radius) * scale).rounded(.up))
    let minY = Int(((logicalY - radius) * scale).rounded(.down))
    let maxY = Int(((logicalY + radius) * scale).rounded(.up))
    guard minY <= maxY, minX <= maxX else { return false }
    for y in minY...maxY {
        for x in minX...maxX where rawPixel(image, pixelX: x, pixelY: y).a > 0 {
            return true
        }
    }
    return false
}

/// 画像全体を走査し、参照色 (background) から最も色成分が離れた画素の RGB を返す。
/// 背景も alpha>0 のため、alpha だけでは文字の画素と区別できない。色差の大小で拾う。
private func mostDifferentColor(_ image: CGImage, from background: (r: UInt8, g: UInt8, b: UInt8)) -> (r: UInt8, g: UInt8, b: UInt8) {
    var best = background
    var bestDistance = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            let p = rawPixel(image, pixelX: x, pixelY: y)
            let distance = abs(Int(p.r) - Int(background.r)) + abs(Int(p.g) - Int(background.g)) + abs(Int(p.b) - Int(background.b))
            if distance > bestDistance {
                bestDistance = distance
                best = (p.r, p.g, p.b)
            }
        }
    }
    return best
}

@MainActor
final class ChromeImageBakerTests: XCTestCase {
    /// 出荷時ウィンドウの EQ 描画領域と同じ幾何を組み立てる。
    private func shippedGeo(scale: CGFloat = 2, floorDb: Double = EQLayout.Tuning.floorDbDefault) -> EQPlotGeometry {
        let canvasHeight = shippedHostHeight
        let width = EQLayout.eqContentWidth(totalWidth: EQLayout.windowDefaultSize.width, showLevelMeter: true)
        return EQPlotGeometry(size: CGSize(width: width, height: canvasHeight), floorDb: floorDb, pixelGrid: EQLayout.PixelGrid(scale: scale))
    }

    func testPixelDimensionsMatchRoundedLogicalSizeTimesScale() {
        for scale: CGFloat in [1, 2, 1.5, 3] {
            let geo = shippedGeo(scale: scale)
            guard let set = ChromeImageBaker.bake(geo: geo) else {
                XCTFail("scale=\(scale) で焼けなかった")
                continue
            }
            for (image, size) in [(set.baseline, set.baselineSize), (set.gutter, set.gutterSize), (set.axis, set.axisSize)] {
                XCTAssertEqual(image.width, Int((size.width * scale).rounded()), "scale=\(scale)")
                XCTAssertEqual(image.height, Int((size.height * scale).rounded()), "scale=\(scale)")
            }
            XCTAssertEqual(set.scale, scale)
        }
    }

    // CTM の上下反転を取り違えると +/− が入れ替わり、この検証で検出できる。
    func testGutterImageIsNotVerticallyFlipped() {
        let geo = shippedGeo()
        guard let set = ChromeImageBaker.bake(geo: geo) else { return XCTFail("焼けなかった") }
        let rect = geo.plotRect
        let cx = set.gutterSize.width / 2

        XCTAssertTrue(hasInk(set.gutter, logicalX: cx, logicalY: rect.minY + 6, scale: set.scale), "上端寄りに + の墨が乗ること")
        XCTAssertTrue(hasInk(set.gutter, logicalX: cx, logicalY: rect.maxY + 1, scale: set.scale), "下端寄りに − の墨が乗ること")

        let midway = (rect.minY + 6 + geo.dbToY(0)) / 2
        XCTAssertFalse(hasInk(set.gutter, logicalX: cx, logicalY: midway, scale: set.scale), "記号どうしの中間は透明であること")
    }

    func testBaselineImageIsDashedNotSolid() {
        let geo = shippedGeo()
        guard let set = ChromeImageBaker.bake(geo: geo) else { return XCTFail("焼けなかった") }
        var sawOpaque = false
        var sawTransparentAfterOpaque = false
        var x: CGFloat = 0
        while x < set.baselineSize.width {
            let opaque = rawPixel(set.baseline, pixelX: Int(x * set.scale), pixelY: 0).a > 0
            if opaque { sawOpaque = true }
            if sawOpaque && !opaque { sawTransparentAfterOpaque = true }
            x += 1
        }
        XCTAssertTrue(sawOpaque, "破線の不透明区間が存在すること")
        XCTAssertTrue(sawTransparentAfterOpaque, "不透明区間のあとに透明区間が現れる (実線でないこと)")
    }

    // この式 (フロア値ごとにラベル文字列から幅を求める) が固定値へ後退していないかを見る。
    func testAxisImageWidthCoversTheWidestLabelAtFloorLowerBound() {
        let floorDb = EQLayout.Tuning.floorDbRange.lowerBound
        let geo = shippedGeo(floorDb: floorDb)
        guard let set = ChromeImageBaker.bake(geo: geo) else { return XCTFail("焼けなかった") }
        let ticks = EQLayout.axisDbTicks(floorDb: floorDb)
        let labels = ticks.map { String(Int($0)) }
        let expectedCharWidth = labels.map { ($0 as NSString).size(withAttributes: [.font: ChromeImageBaker.axisTickFont]).width }.max() ?? 0
        let expectedWidth = max(EQLayout.Padding.left, expectedCharWidth + ChromeImageBaker.labelHorizontalMargin * 2)
        XCTAssertEqual(set.axisSize.width, expectedWidth, accuracy: 0.01)

        for (tick, label) in zip(ticks, labels) {
            let y = geo.levelDbToY(tick) + 3
            let width = (label as NSString).size(withAttributes: [.font: ChromeImageBaker.axisTickFont]).width
            XCTAssertTrue(
                hasInk(set.axis, logicalX: set.axisSize.width / 2, logicalY: y, scale: set.scale, radius: max(width / 2, 1)),
                "ラベル \(label) が画像内に収まって描かれていること"
            )
        }
    }

    func testGutterImageWidthMatchesWidthFormula() {
        let geo = shippedGeo()
        guard let set = ChromeImageBaker.bake(geo: geo) else { return XCTFail("焼けなかった") }
        let charWidth = ["+", "−", "0"].map { label -> CGFloat in
            let font = label == "0" ? ChromeImageBaker.gutterZeroFont : ChromeImageBaker.gutterSignFont
            return (label as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let expected = max(EQLayout.Padding.left, charWidth + ChromeImageBaker.labelHorizontalMargin * 2)
        XCTAssertEqual(set.gutterSize.width, expected, accuracy: 0.01)
    }
}

@MainActor
final class DragBadgeBakerTests: XCTestCase {
    // 余白側は変わらないため、幅の差分は文字幅の差分と一致する。
    func testBadgeWidthDeltaMatchesTextWidthDelta() {
        guard let narrow = DragBadgeBaker.bake(db: 3, scale: 1), let wide = DragBadgeBaker.bake(db: 13, scale: 1) else {
            return XCTFail("焼けなかった")
        }
        let narrowText = ("+3" as NSString).size(withAttributes: [.font: DragBadgeBaker.font]).width
        let wideText = ("+13" as NSString).size(withAttributes: [.font: DragBadgeBaker.font]).width
        XCTAssertEqual(wide.size.width - narrow.size.width, wideText - narrowText, accuracy: 0.5)
    }

    func testBadgeSizeMatchesTextSizePlusPadding() {
        guard let badge = DragBadgeBaker.bake(db: 7, scale: 1) else { return XCTFail("焼けなかった") }
        let textSize = ("+7" as NSString).size(withAttributes: [.font: DragBadgeBaker.font])
        XCTAssertEqual(badge.size.width, textSize.width + DragBadgeBaker.paddingH * 2, accuracy: 0.01)
        XCTAssertEqual(badge.size.height, textSize.height + DragBadgeBaker.paddingV * 2, accuracy: 0.01)
    }

    func testPixelDimensionsMatchRoundedLogicalSizeTimesScale() {
        for scale: CGFloat in [1, 2, 1.5, 3] {
            guard let badge = DragBadgeBaker.bake(db: -4, scale: scale) else {
                XCTFail("scale=\(scale) で焼けなかった")
                continue
            }
            XCTAssertEqual(badge.image.width, Int((badge.size.width * scale).rounded()), "scale=\(scale)")
            XCTAssertEqual(badge.image.height, Int((badge.size.height * scale).rounded()), "scale=\(scale)")
        }
    }

    // 画素サンプリングで色成分を比較する (厳密な一致は見ない)。
    func testTextColorDiffersByBoostCutZero() {
        let scale: CGFloat = 2
        guard
            let boost = DragBadgeBaker.bake(db: 5, scale: scale),
            let cut = DragBadgeBaker.bake(db: -5, scale: scale),
            let zero = DragBadgeBaker.bake(db: 0, scale: scale)
        else { return XCTFail("焼けなかった") }

        // ピル形の丸みで文字と重ならない位置を背景の参照色として使う。
        func textColor(_ badge: DragBadgeImage) -> (r: UInt8, g: UInt8, b: UInt8) {
            let background = rawPixel(badge.image, pixelX: Int(2 * scale), pixelY: Int(badge.size.height / 2 * scale))
            return mostDifferentColor(badge.image, from: (background.r, background.g, background.b))
        }
        func distance(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8)) -> Int {
            abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
        }

        let boostColor = textColor(boost)
        let cutColor = textColor(cut)
        let zeroColor = textColor(zero)
        XCTAssertGreaterThan(distance(boostColor, cutColor), 15, "boost/cut で色が異なること")
        XCTAssertGreaterThan(distance(boostColor, zeroColor), 15, "boost/zero で色が異なること")
        XCTAssertGreaterThan(distance(cutColor, zeroColor), 15, "cut/zero で色が異なること")
    }

    // 背景は常に不透明であること (バー・白塗りとの重なりに関係なく読めるための前提)。
    func testBackgroundIsOpaque() {
        guard let badge = DragBadgeBaker.bake(db: 0, scale: 1) else { return XCTFail("焼けなかった") }
        // 縦中央・左端寄り (ピル形の丸みが full width になる位置、文字とは重ならない) を見る。
        let p = rawPixel(badge.image, pixelX: 2, pixelY: Int(badge.size.height / 2))
        XCTAssertGreaterThan(p.a, 0)
    }
}

/// 実物のレイヤを組み立てる検証 (統合寄り・画素は見ない)。
@MainActor
final class VisualizerHostViewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    // 非同期版の setUp を使う (同期版はこの検証が要る隔離を持たない)。
    override func setUp() async throws {
        try await super.setUp()
        suiteName = TestDefaults.makeName("VisualizerHostViewTests")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        TestDefaults.remove(name: suiteName, defaults: defaults)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeVM() -> EQViewModel {
        makeVMWithEngine().vm
    }

    /// engine.levelMeter へテスト値を書き込みたい (→ pull 経由で vm へ引き出す) 場合に使う。
    private func makeVMWithEngine() -> (vm: EQViewModel, engine: AudioEngine) {
        let store = SettingsStore(defaults: defaults)
        let engine = AudioEngine()
        let vm = EQViewModel(
            engine: engine, settings: store,
            outputController: OutputDeviceController(settings: store, targetDeviceUID: "test-driver-uid"),
            audioWorld: makeTestAudioWorld()
        )
        // EQ が音に効いている状態を基準にする (可用性の既定値は未検出で、そのままだと全バンド灰色になる)。
        vm.confirmDriverProbe(.versionsUnreadable(.ok))
        vm.updateProcessingState(.active, activeDevice: nil)
        return (vm, engine)
    }

    private func makeLaidOutHostView(_ vm: EQViewModel) -> VisualizerHostView {
        let hostView = VisualizerHostView(viewModel: vm, compact: false)
        hostView.frame = CGRect(origin: .zero, size: CGSize(width: EQLayout.windowDefaultSize.width, height: shippedHostHeight))
        hostView.layoutSubtreeIfNeeded()
        hostView.pinPointerInsideVisualizeArea()
        return hostView
    }

    // 純粋関数が正しくても、呼び出し側の配線が誤っていれば止まらない (見えない CPU 消費として現れる)。
    func testTimerStopsWhenTheHostViewStopsBeingVisible() {
        let vm = makeVM()
        vm.visualizerActive = true
        let hostView = makeLaidOutHostView(vm)

        hostView.windowVisible = true
        hostView.appHidden = false
        hostView.updateTimerRunning()
        XCTAssertTrue(hostView.visualizerTimerRunning, "前提: 見えている間は駆動していること")

        hostView.windowVisible = false
        hostView.updateTimerRunning()
        XCTAssertFalse(hostView.visualizerTimerRunning, "ウィンドウが見えなくなったら止まる")

        hostView.windowVisible = true
        hostView.updateTimerRunning()
        XCTAssertTrue(hostView.visualizerTimerRunning, "戻れば再び駆動する")

        hostView.appHidden = true
        hostView.updateTimerRunning()
        XCTAssertFalse(hostView.visualizerTimerRunning, "アプリが非表示になったら止まる")
    }

    // LED 領域の高さは padding とラベル行の積み上げで決まる。段の刻みを決める定数がその実寸から
    // ずれると、段が領域を埋めきらず上端に余りが出る。
    func testCompactLedHeightMatchesTheLaidOutVisualizerHeight() throws {
        let hosting = NSHostingView(rootView: CompactRootView(viewModel: makeVM()))
        hosting.frame = CGRect(origin: .zero, size: EQLayout.compactWindowDefaultSize)
        hosting.layoutSubtreeIfNeeded()
        let hostView = try XCTUnwrap(
            Self.findVisualizerHostView(in: hosting), "コンパクトビューの描画ホストが見つかること"
        )
        XCTAssertEqual(hostView.bounds.height, EQLayout.compactLedHeight, accuracy: 0.01)
    }

    private static func findVisualizerHostView(in view: NSView) -> VisualizerHostView? {
        if let found = view as? VisualizerHostView { return found }
        for sub in view.subviews {
            if let found = findVisualizerHostView(in: sub) { return found }
        }
        return nil
    }

    // モード切替は contentView ごと差し替える。捨てたビューのタイマが止まらなければ、切り替えるたびに
    // 誰も見ていない描画の駆動が積み上がる。
    func testTimerStopsWhenTheHostViewLeavesItsWindow() {
        let vm = makeVM()
        vm.visualizerActive = true
        let hostView = makeLaidOutHostView(vm)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: EQLayout.compactWindowDefaultSize),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hostView
        hostView.windowVisible = true
        hostView.appHidden = false
        hostView.updateTimerRunning()
        XCTAssertTrue(hostView.visualizerTimerRunning, "前提: ウィンドウに載って見えている間は駆動していること")

        window.contentView = NSView()
        XCTAssertFalse(hostView.visualizerTimerRunning, "ウィンドウから外れたら止まること")
    }

    func testCompactBakeSkipsChromeOnlyImages() {
        let pixelGrid = EQLayout.PixelGrid(scale: 2)
        let height = EQLayout.PixelGrid(scale: 2).snap(shippedHostHeight)
        guard let normal = BandImageBaker.bake(plotHeight: height, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3, rowCount: nil, includesChrome: true) else {
            return XCTFail("通常モードの帯画像が焼けること")
        }
        XCTAssertNotNil(normal.chromeFills, "chrome を持つ側は chrome 専用の縞を焼くこと")

        guard let compact = BandImageBaker.bake(
            plotHeight: height, pixelGrid: pixelGrid, peakCapBrightenAmount: 0.3,
            rowCount: EQLayout.compactRowCount, includesChrome: false
        ) else {
            return XCTFail("コンパクトモードの帯画像が焼けること")
        }
        XCTAssertNil(compact.chromeFills, "chrome を持たない側は焼かないこと")
    }

    func testLayerTreeHasExpectedColumnAndClipCellCounts() {
        let hostView = makeLaidOutHostView(makeVM())
        XCTAssertEqual(hostView.eqColumns.count, EQSpec.bandCount)
        XCTAssertEqual(hostView.meterColumns.count, 2)
        XCTAssertEqual(hostView.clipCells.count, 2)
    }

    // 点灯帯とキャップの排他規則により、重なった段は点灯帯からキャップへ譲られる
    // (譲らないと二重に塗られて明るく光る)。
    func testLitLayerHeightMatchesDisplayedLevelWithoutEverStartingTheTimer() {
        let (vm, engine) = makeVMWithEngine()
        let band = 3
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[band] = -20
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot), vm: vm, engine: engine)

        let hostView = makeLaidOutHostView(vm)
        let plotHeight = hostView.eqContainer.bounds.height
        let grid = EQLayout.SegmentGrid(height: plotHeight, bottomY: plotHeight, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let frac = (-20 - vm.floorDb) / (0 - vm.floorDb)
        let fillTop = plotHeight - CGFloat(frac) * plotHeight
        let litRowCount = grid.litRowCountByFillTop(fillTop)
        guard let capRowIndex = grid.capRowIndex(peakTop: fillTop) else {
            return XCTFail("前提: このレベルならキャップ段が出ること")
        }
        XCTAssertEqual(capRowIndex, litRowCount - 1, "前提: peaks==levels のためキャップが点灯帯の最上段と重なること")
        let expectedHeight = grid.litHeight(forRowCount: litRowCount - 1)

        XCTAssertGreaterThan(expectedHeight, 0, "前提: 最上段を譲ってもなお点灯段が残ること")
        let litLayer = hostView.eqColumns[band].litLayer
        XCTAssertEqual(litLayer.frame.height, expectedHeight, accuracy: 1e-9, "キャップと重なる最上段のぶん、点灯帯が短くなっていること")
        XCTAssertEqual(litLayer.frame.minY, plotHeight - expectedHeight, accuracy: 1e-9, "下端がプロット下端に固定されていること")

        let capLayer = hostView.eqColumns[band].capLayer
        XCTAssertFalse(capLayer.isHidden)
        let capRow = grid.rowY(capRowIndex)
        XCTAssertEqual(capLayer.frame.minY, capRow.top, accuracy: 1e-9, "キャップは重なった最上段の位置のまま表示されること")
    }

    func testLitLayerHeightIsZeroWhenBandIsSilent() {
        let hostView = makeLaidOutHostView(makeVM())
        // makeVM 直後は観測が未到達。
        for column in hostView.eqColumns {
            XCTAssertEqual(column.litLayer.frame.height, 0)
        }
    }

    func testCapLayerIsVisibleAndPositionedAtThePeakRowWhenPeakHoldEnabled() {
        let (vm, engine) = makeVMWithEngine()
        let band = 5
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        var peaks = levels
        levels[band] = -50
        peaks[band] = -10
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: silentStereoSnapshot), vm: vm, engine: engine)

        let hostView = makeLaidOutHostView(vm)
        let plotHeight = hostView.eqContainer.bounds.height
        let grid = EQLayout.SegmentGrid(height: plotHeight, bottomY: plotHeight, pixelGrid: EQLayout.PixelGrid(scale: 1))
        func fillTop(_ level: Double) -> CGFloat {
            let frac = (level - vm.floorDb) / (0 - vm.floorDb)
            return plotHeight - CGFloat(frac) * plotHeight
        }
        guard let expectedCapIndex = grid.capRowIndex(peakTop: fillTop(-10)) else {
            return XCTFail("前提: このピーク値ならキャップ段が出ること")
        }
        let expectedRow = grid.rowY(expectedCapIndex)

        let capLayer = hostView.eqColumns[band].capLayer
        XCTAssertFalse(capLayer.isHidden)
        XCTAssertEqual(capLayer.frame.minY, expectedRow.top, accuracy: 1e-9)
        XCTAssertEqual(capLayer.frame.height, expectedRow.bottom - expectedRow.top, accuracy: 1e-9)
    }

    func testCapLayerIsHiddenWhenPeakHoldDisabled() {
        let (vm, engine) = makeVMWithEngine()
        vm.peakHoldEnabled = false
        let band = 2
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        var peaks = levels
        levels[band] = -50
        peaks[band] = -5
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: silentStereoSnapshot), vm: vm, engine: engine)

        let hostView = makeLaidOutHostView(vm)
        XCTAssertTrue(hostView.eqColumns[band].capLayer.isHidden)
    }

    /// 実際の解析を通じて左チャンネルだけをフルスケール超過させる (右は無音)。ちょうどフルスケールは
    /// 超過に含めないため、1 を上回る振幅を与える。
    private func captureLeftChannelClip(vm: EQViewModel, engine: AudioEngine, now: Date) {
        vm.visualizerActive = true
        let frameCount = 8192
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for f in 0..<frameCount { interleaved[f * 2] = 1.2 }
        interleaved.withUnsafeBufferPointer { ptr in
            engine.levelMeter.capture(ptr.baseAddress!, frameCount: frameCount, channels: 2)
        }
        vm.tick(now: now)
    }

    // 最上段に見えるのはクリップ側であること。
    func testClipCellAndCapAreExclusiveWhenCapWouldLandOnTheTopRow() {
        let (vm, engine) = makeVMWithEngine()
        captureLeftChannelClip(vm: vm, engine: engine, now: Date(timeIntervalSinceReferenceDate: 0))

        let hostView = makeLaidOutHostView(vm)
        XCTAssertFalse(hostView.clipCells[0].isHidden, "左チャンネルが超過中はクリップセルが表示されること")
        XCTAssertTrue(hostView.meterColumns[0].capLayer.isHidden, "超過中に最上段と重なるキャップは隠れること")
        XCTAssertTrue(hostView.clipCells[1].isHidden, "超過していない右チャンネルのクリップセルは隠れたままであること")
    }

    func testClipCellStaysLitForTheHoldDurationAfterASingleExceedance() {
        let (vm, engine) = makeVMWithEngine()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        captureLeftChannelClip(vm: vm, engine: engine, now: t0)
        XCTAssertTrue(vm.leftClipHolding, "前提: 超過を観測した回は点灯する")

        // 以降は新しい捕捉を与えず、保持時間の途中でも点灯し続けることを描画側で確認する。
        vm.tick(now: t0.addingTimeInterval(EQLayout.Tuning.clipHoldSeconds * 0.5))
        let hostView = makeLaidOutHostView(vm)
        XCTAssertFalse(hostView.clipCells[0].isHidden, "保持時間の途中ではクリップセルが表示され続けること")
    }

    // 排他は超過かつ最上段のときだけ効く。
    func testCapShowsNormallyWhenNotClippingOrNotAtTheTopRow() {
        let (vm, engine) = makeVMWithEngine()
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        var peaks = levels
        levels[0] = -50
        peaks[0] = -30
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: silentStereoSnapshot), vm: vm, engine: engine)

        let hostView = makeLaidOutHostView(vm)
        XCTAssertTrue(hostView.clipCells[0].isHidden)
        XCTAssertTrue(hostView.clipCells[1].isHidden)
    }

    // 素通し中もキャップはメーター・バーとも残る (どちらも点灯帯と同色になる)。
    func testCapsStayVisibleForBothTheMeterAndTheEqBarsWhileNotProcessingInEffect() {
        let stereo = LevelMeter.Snapshot.Stereo(leftDb: -50, rightDb: -50, leftPeakDb: -10, rightPeakDb: -10)
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        var peaks = levels
        levels[0] = -50
        peaks[0] = -10

        let (inEffect, inEffectEngine) = makeVMWithEngine()
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: stereo), vm: inEffect, engine: inEffectEngine)
        let shown = makeLaidOutHostView(inEffect)
        XCTAssertFalse(shown.meterColumns[0].capLayer.isHidden, "前提: 効いている間はキャップが出ること")
        XCTAssertFalse(shown.eqColumns[0].capLayer.isHidden, "前提: バー側もキャップが出ること")

        let (bypassed, bypassedEngine) = makeVMWithEngine()
        bypassed.bypass = true
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: stereo), vm: bypassed, engine: bypassedEngine)
        let stillShown = makeLaidOutHostView(bypassed)
        XCTAssertFalse(stillShown.meterColumns[0].capLayer.isHidden, "素通し中でもメーターはキャップ段を残す")
        XCTAssertFalse(stillShown.eqColumns[0].capLayer.isHidden, "素通し中でもバーはキャップ段を残す")
    }

    // キャップの可視性は、メーター・バーとも設定の一つだけに従う。
    func testCapsFollowThePeakHoldSettingForBothTheMeterAndTheEqBars() {
        let stereo = LevelMeter.Snapshot.Stereo(leftDb: -50, rightDb: -50, leftPeakDb: -10, rightPeakDb: -10)
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        var peaks = levels
        levels[0] = -50
        peaks[0] = -10

        let (vm, engine) = makeVMWithEngine()
        pushMeterSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: peaks, stereo: stereo), vm: vm, engine: engine)
        vm.peakHoldEnabled = false

        let hostView = makeLaidOutHostView(vm)
        XCTAssertTrue(hostView.meterColumns[0].capLayer.isHidden, "設定を切ればメーターのキャップは出ないこと")
        XCTAssertTrue(hostView.eqColumns[0].capLayer.isHidden, "設定を切ればバーのキャップも出ないこと")
    }

    func testContentsSwitchToTheBypassSetWhenNotProcessingInEffect() {
        let vm = makeVM()
        vm.bypass = true
        let hostView = makeLaidOutHostView(vm)
        guard let imageSet = hostView.imageSet else { return XCTFail("焼けていない") }
        let column = hostView.eqColumns[0]
        XCTAssertTrue((column.dimLayer.contents as! CGImage) === imageSet.dimBypass)
        XCTAssertTrue((column.litLayer.contents as! CGImage) === imageSet.litBypass)
        XCTAssertTrue((column.capLayer.contents as! CGImage) === imageSet.litBypass, "素通し中のキャップは点灯帯 (bypass) を流用すること")
    }

    func testContentsUseTheInEffectSetWhenProcessingInEffect() {
        let hostView = makeLaidOutHostView(makeVM())
        guard let imageSet = hostView.imageSet else { return XCTFail("焼けていない") }
        let column = hostView.eqColumns[0]
        XCTAssertTrue((column.dimLayer.contents as! CGImage) === imageSet.dimInEffect)
        XCTAssertTrue((column.litLayer.contents as! CGImage) === imageSet.litInEffect)
        XCTAssertTrue((column.capLayer.contents as! CGImage) === imageSet.capInEffect)
    }

    func testMeterContainerHidesWhenShowLevelMeterIsFalse() {
        let vm = makeVM()
        vm.showLevelMeter = false
        let hostView = makeLaidOutHostView(vm)
        XCTAssertTrue(hostView.meterContainer.isHidden)
    }

    // CALayer の暗黙アニメーションで幾何が勝手に補間されていないことを機械的に検出する。
    func testNoImplicitAnimationKeysAfterApplyingGeometry() {
        let (vm, engine) = makeVMWithEngine()
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[0] = -10
        engine.levelMeter.setSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot))
        vm.updateDrag(band: 1, db: 4)
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        let hostView = makeLaidOutHostView(vm)

        XCTAssertNil(hostView.eqContainer.animationKeys())
        XCTAssertNil(hostView.meterContainer.animationKeys())
        for column in hostView.eqColumns + hostView.meterColumns {
            XCTAssertNil(column.dimLayer.animationKeys())
            XCTAssertNil(column.litLayer.animationKeys())
            XCTAssertNil(column.capLayer.animationKeys())
        }
        for cell in hostView.clipCells {
            XCTAssertNil(cell.animationKeys())
        }

        let chrome = hostView.chromeLayers
        XCTAssertNil(chrome.backChromeContainer.animationKeys())
        XCTAssertNil(chrome.frontChromeContainer.animationKeys())
        XCTAssertNil(chrome.handleLinesContainer.animationKeys())
        for layer in chrome.gainRangeLayers + chrome.preampGainRangeLayers + chrome.handleLineLayers {
            XCTAssertNil(layer.animationKeys())
        }
        for layer in [chrome.dragFillLayer, chrome.baselineLayer, chrome.gutterLayer, chrome.axisLayer, chrome.dragBadgeLayer, chrome.preampHandleLineLayer] {
            XCTAssertNil(layer.animationKeys())
        }
    }

    func testContentsScaleMatchesTheBakedImageScale() {
        let hostView = makeLaidOutHostView(makeVM())
        guard let imageSet = hostView.imageSet else { return XCTFail("焼けていない") }
        for column in hostView.eqColumns + hostView.meterColumns {
            XCTAssertEqual(column.dimLayer.contentsScale, imageSet.scale)
            XCTAssertEqual(column.litLayer.contentsScale, imageSet.scale)
            XCTAssertEqual(column.capLayer.contentsScale, imageSet.scale)
        }
    }

    // MARK: - EQChromeLayers (chrome のレイヤ組み込み)

    // 合成順序を固定する。
    func testChromeLayerTreeOrderMatchesCompositingOrder() {
        let hostView = makeLaidOutHostView(makeVM())
        guard let root = hostView.layer else { return XCTFail("root layer が取得できない") }
        let chrome = hostView.chromeLayers
        XCTAssertEqual(root.sublayers?.map(ObjectIdentifier.init), [
            ObjectIdentifier(chrome.backChromeContainer), ObjectIdentifier(hostView.eqContainer),
            ObjectIdentifier(hostView.meterContainer), ObjectIdentifier(chrome.frontChromeContainer),
        ])
        XCTAssertEqual(
            chrome.frontChromeContainer.sublayers?.map(ObjectIdentifier.init),
            [ObjectIdentifier(chrome.handleLinesContainer), ObjectIdentifier(chrome.dragFillLayer)]
                + chrome.preampDragFillLayers.map(ObjectIdentifier.init)
                + [
                    ObjectIdentifier(chrome.baselineLayer), ObjectIdentifier(chrome.gutterLayer),
                    ObjectIdentifier(chrome.axisLayer), ObjectIdentifier(chrome.dragBadgeLayer),
                ]
        )
    }

    // 白オーバーレイ・ハンドル線が横方向に重ならないこと。ノーマルビューの幅とそれより狭い幅、
    // メーター表示/非表示の全組み合わせで確認する。
    func testGainRangeAndHandleLineLayersDoNotOverlapHorizontallyAcrossWidths() {
        for totalWidth in [EQLayout.windowDefaultSize.width, EQLayout.compactWindowDefaultSize.width] {
            for showMeter in [true, false] {
                let vm = makeVM()
                vm.showLevelMeter = showMeter
                vm.handlesRevealed = true
                for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
                XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")

                let hostView = VisualizerHostView(viewModel: vm, compact: false)
                hostView.frame = CGRect(origin: .zero, size: CGSize(width: totalWidth, height: shippedHostHeight))
                hostView.layoutSubtreeIfNeeded()
                let chrome = hostView.chromeLayers
                XCTAssertFalse(chrome.handleLinesContainer.isHidden, "前提: ハンドル線が可視であること")

                for band in 0..<(EQSpec.bandCount - 1) {
                    XCTAssertLessThanOrEqual(
                        chrome.gainRangeLayers[band].frame.maxX, chrome.gainRangeLayers[band + 1].frame.minX,
                        "白オーバーレイ band=\(band) totalWidth=\(totalWidth) showMeter=\(showMeter)"
                    )
                    XCTAssertLessThanOrEqual(
                        chrome.handleLineLayers[band].frame.maxX, chrome.handleLineLayers[band + 1].frame.minX,
                        "ハンドル線 band=\(band) totalWidth=\(totalWidth) showMeter=\(showMeter)"
                    )
                }

                let eqWidth = EQLayout.eqContentWidth(totalWidth: totalWidth, showLevelMeter: showMeter)
                let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: shippedHostHeight), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
                XCTAssertGreaterThan(
                    geo.columnWidth, geo.barWidth + EQLayout.handleLineOverhang,
                    "不変条件 columnWidth > barWidth + handleLineOverhang totalWidth=\(totalWidth) showMeter=\(showMeter)"
                )

                XCTAssertFalse(chrome.backChromeContainer.masksToBounds)
                XCTAssertFalse(chrome.frontChromeContainer.masksToBounds)
                XCTAssertFalse(chrome.handleLinesContainer.masksToBounds)
            }
        }
    }

    func testVisibilityFollowsHandleAlphaThresholdAndProcessingInEffectAsymmetrically() {
        let idleChrome = makeLaidOutHostView(makeVM()).chromeLayers
        XCTAssertTrue(idleChrome.backChromeContainer.isHidden, "待機中は白オーバーレイが隠れる")
        XCTAssertTrue(idleChrome.handleLinesContainer.isHidden, "待機中はハンドル線が隠れる")
        XCTAssertTrue(idleChrome.baselineLayer.isHidden, "待機中は baseline が隠れる")
        XCTAssertTrue(idleChrome.gutterLayer.isHidden, "待機中は gutter が隠れる")
        XCTAssertFalse(idleChrome.axisLayer.isHidden, "待機中は dBFS 目盛りが見える")

        // ハンドルを可視化してから素通しへ切り替える。
        let vm = makeVM()
        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")
        vm.bypass = true
        XCTAssertFalse(vm.processingInEffect, "前提: 素通しにより効いていないこと")

        let chrome = makeLaidOutHostView(vm).chromeLayers
        XCTAssertTrue(chrome.backChromeContainer.isHidden, "白オーバーレイは processingInEffect を条件に持つため即座に隠れる")
        XCTAssertFalse(chrome.handleLinesContainer.isHidden, "ハンドル線は handleAlpha のみに従うため、この時点ではまだ見える")
    }

    func testHandleLinePositionMatchesGeometry() {
        let vm = makeVM()
        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")

        let hostView = makeLaidOutHostView(vm)
        let totalSize = hostView.bounds.size
        let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
        let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))

        let chrome = hostView.chromeLayers
        for band in 0..<EQSpec.bandCount {
            let line = chrome.handleLineLayers[band]
            XCTAssertEqual(line.frame.width, geo.barWidth + EQLayout.handleLineOverhang, accuracy: 1e-9, "band=\(band)")
            XCTAssertEqual(line.frame.height, EQLayout.handleLineWidth, accuracy: 1e-9, "band=\(band)")
            XCTAssertEqual(line.frame.midX, geo.columnCenterX(band), accuracy: 1e-9, "band=\(band)")
            XCTAssertEqual(line.frame.midY, geo.dbToY(vm.handleDisplayGains[band]), accuracy: 1e-9, "band=\(band)")
        }
    }

    private func chromeGrid(for geo: EQPlotGeometry) -> EQLayout.SegmentGrid {
        EQLayout.SegmentGrid(height: geo.plotRect.height, bottomY: geo.plotRect.maxY, pixelGrid: geo.pixelGrid)
    }

    func testGainRangeOverlayFrameAndContentsRectMatchRowIndexRange() {
        let band = 4
        for db: Double in [10, -10] {
            let vm = makeVM()
            vm.noteCanvasPointerDown()
            vm.updateDrag(band: band, db: db)
            for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
            XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること db=\(db)")
            XCTAssertEqual(vm.handleDisplayGains[band], db, "前提: 表示値が現在値へ追従していること db=\(db)")

            let hostView = makeLaidOutHostView(vm)
            let totalSize = hostView.bounds.size
            let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
            let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
            let plotHeight = geo.plotRect.height
            let grid = chromeGrid(for: geo)
            let baselineY = geo.dbToY(0)
            let gy = geo.dbToY(vm.handleDisplayGains[band])
            guard let range = grid.rowIndexRange(intersectingTop: min(baselineY, gy), bottom: max(baselineY, gy)) else {
                return XCTFail("前提: 当たる段があること db=\(db)")
            }
            let expectedTop = grid.rowY(range.upperBound).top
            let expectedBottom = grid.rowY(range.lowerBound).bottom
            let bar = geo.barRect(band)

            let layer = hostView.chromeLayers.gainRangeLayers[band]
            XCTAssertFalse(layer.isHidden, "db=\(db)")
            XCTAssertEqual(layer.frame.minX, bar.minX, accuracy: 1e-9, "db=\(db)")
            XCTAssertEqual(layer.frame.width, bar.width, accuracy: 1e-9, "db=\(db)")
            XCTAssertEqual(layer.frame.minY, expectedTop, accuracy: 1e-9, "db=\(db)")
            XCTAssertEqual(layer.frame.height, expectedBottom - expectedTop, accuracy: 1e-9, "db=\(db)")
            XCTAssertEqual(layer.contentsRect.origin.y, (expectedTop - geo.plotRect.minY) / plotHeight, accuracy: 1e-9, "db=\(db)")
            XCTAssertEqual(layer.contentsRect.height, (expectedBottom - expectedTop) / plotHeight, accuracy: 1e-9, "db=\(db)")
        }
    }

    func testGainRangeOverlayHidesAtTheExactZeroDbRowBoundaryCoincidenceAtShippedWindowSize() {
        let band = 4
        let vm = makeVM()
        vm.noteCanvasPointerDown()
        vm.updateDrag(band: band, db: 0)
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")
        XCTAssertEqual(vm.handleDisplayGains[band], 0, "前提: 表示値が 0dB であること")

        let hostView = makeLaidOutHostView(vm)
        let totalSize = hostView.bounds.size
        let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
        let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let grid = chromeGrid(for: geo)
        let baselineY = geo.dbToY(0)
        XCTAssertNil(
            grid.rowIndexRange(intersectingTop: baselineY, bottom: baselineY),
            "前提: 出荷時サイズでは 0dB がちょうど段の境界に乗ること (この前提が崩れたら本テストごと見直す)"
        )
        XCTAssertTrue(hostView.chromeLayers.gainRangeLayers[band].isHidden, "上記の境界一致により、この 1 フレームは当たる段が無く隠れる")
    }

    // MARK: - preampGainRangeLayers (L/R メーター上のプリアンプゲイン範囲オーバーレイ)

    func testPreampGainRangeLayersHiddenWhileHandleNotVisible() {
        let hostView = makeLaidOutHostView(makeVM())
        for layer in hostView.chromeLayers.preampGainRangeLayers {
            XCTAssertTrue(layer.isHidden)
        }
    }

    func testPreampGainRangeLayersCoverRangeBetweenBaselineAndPreampLine() {
        for db: Double in [6, -6] {
            let vm = makeVM()
            vm.overridePreamp(db: db)
            vm.handlesRevealed = true
            for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
            XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること db=\(db)")
            XCTAssertEqual(vm.handleDisplayPreamp, db, "前提: 表示値が現在値へ追従していること db=\(db)")

            let hostView = makeLaidOutHostView(vm)
            let totalSize = hostView.bounds.size
            let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
            let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
            let grid = chromeGrid(for: geo)
            let baselineY = geo.dbToY(0)
            let py = geo.dbToY(vm.handleDisplayPreamp)
            guard let range = grid.rowIndexRange(intersectingTop: min(baselineY, py), bottom: max(baselineY, py)) else {
                return XCTFail("前提: 当たる段があること db=\(db)")
            }
            let expectedTop = grid.rowY(range.upperBound).top
            let expectedBottom = grid.rowY(range.lowerBound).bottom

            for layer in hostView.chromeLayers.preampGainRangeLayers {
                XCTAssertFalse(layer.isHidden, "db=\(db)")
                XCTAssertEqual(layer.frame.minY, expectedTop, accuracy: 1e-9, "db=\(db)")
                XCTAssertEqual(layer.frame.height, expectedBottom - expectedTop, accuracy: 1e-9, "db=\(db)")
            }
        }
    }

    func testPreampGainRangeLayersMoveToTheOppositeSideOfBaselineWhenSignFlips() {
        func frame(preampDb: Double) -> (rect: CGRect, baselineY: CGFloat) {
            let vm = makeVM()
            vm.overridePreamp(db: preampDb)
            vm.handlesRevealed = true
            for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
            let hostView = makeLaidOutHostView(vm)
            let totalSize = hostView.bounds.size
            let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
            let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
            return (hostView.chromeLayers.preampGainRangeLayers[0].frame, geo.dbToY(0))
        }

        let boost = frame(preampDb: 6)
        XCTAssertLessThanOrEqual(boost.rect.maxY, boost.baselineY, "プラス側は基準線より上 (小さい y) を覆うこと")

        let cut = frame(preampDb: -6)
        XCTAssertGreaterThanOrEqual(cut.rect.minY, cut.baselineY, "マイナス側は基準線より下 (大きい y) を覆うこと")
    }

    // 0dB での隠れ方 (空範囲の扱い) を EQ 側と揃えることの固定。
    func testPreampGainRangeLayerHiddenStateAtZeroDbMatchesEqBandGainRangeLayer() {
        let band = 4
        let vm = makeVM()
        vm.resetGain(band: band)
        vm.overridePreamp(db: 0)
        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")
        XCTAssertEqual(vm.handleDisplayGains[band], 0, "前提: EQ 側の表示値も 0dB であること")
        XCTAssertEqual(vm.handleDisplayPreamp, 0, "前提: プリアンプの表示値も 0dB であること")

        let hostView = makeLaidOutHostView(vm)
        let chrome = hostView.chromeLayers
        XCTAssertTrue(chrome.gainRangeLayers[band].isHidden, "前提: 出荷時サイズでの境界一致により EQ 側も隠れること")
        for preampLayer in chrome.preampGainRangeLayers {
            XCTAssertEqual(preampLayer.isHidden, chrome.gainRangeLayers[band].isHidden)
        }
    }

    func testPreampGainRangeLayersHiddenWhenLevelMeterHidden() {
        let vm = makeVM()
        vm.showLevelMeter = false
        vm.overridePreamp(db: 4)
        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")

        let hostView = makeLaidOutHostView(vm)
        for layer in hostView.chromeLayers.preampGainRangeLayers {
            XCTAssertTrue(layer.isHidden)
        }
    }

    // フェードの途中を映すのは子レイヤー自身のアルファで、コンテナは担わない。
    func testHandleGroupLayersCarryTheHandleAlphaWhilePartiallyFadedIn() {
        let vm = makeVM()
        vm.updateDrag(band: 0, db: 4)
        vm.endDrag()
        vm.noteCanvasPointerDown()
        let t0 = Date(timeIntervalSinceReferenceDate: 200)
        vm.tick(now: t0)
        vm.tick(now: t0.addingTimeInterval(0.016))
        XCTAssertGreaterThan(vm.handleAlpha, 0, "前提: フェードインの途中であること")
        XCTAssertLessThan(vm.handleAlpha, 1)

        let hostView = makeLaidOutHostView(vm)
        let chrome = hostView.chromeLayers
        XCTAssertFalse(chrome.gainRangeLayers[0].isHidden, "前提: 0dB ではない帯が映っていること")
        XCTAssertEqual(chrome.gainRangeLayers[0].opacity, Float(vm.handleAlpha))
        for band in 0..<EQSpec.bandCount {
            XCTAssertEqual(chrome.handleLineLayers[band].opacity, Float(vm.handleAlpha), "band=\(band)")
        }
    }

    // プリアンプ表示は本体のハンドル群と同じアルファを使う (独自のフェード値を持たない)。
    func testPreampOverlayTracksTheHandleAlphaWhilePartiallyFadedIn() {
        let vm = makeVM()
        vm.overridePreamp(db: 4)
        vm.noteCanvasPointerDown()
        let t0 = Date(timeIntervalSinceReferenceDate: 200)
        vm.tick(now: t0)
        vm.tick(now: t0.addingTimeInterval(0.016))
        XCTAssertGreaterThan(vm.handleAlpha, 0, "前提: フェードインの途中であること")
        XCTAssertLessThan(vm.handleAlpha, 1)

        let hostView = makeLaidOutHostView(vm)
        let chrome = hostView.chromeLayers
        XCTAssertEqual(chrome.preampHandleLineLayer.opacity, Float(vm.handleAlpha))
        for layer in chrome.preampGainRangeLayers {
            XCTAssertEqual(layer.opacity, Float(vm.handleAlpha))
        }
    }

    func testPreampGainRangeLayersHorizontalRangeMatchesMeterBarAbsolutePosition() {
        let vm = makeVM()
        vm.overridePreamp(db: 4)
        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが完全に見えていること")

        let hostView = makeLaidOutHostView(vm)
        let chrome = hostView.chromeLayers
        for i in 0..<2 {
            let expectedMinX = hostView.meterContainer.frame.minX + hostView.meterColumns[i].dimLayer.frame.minX
            let expectedWidth = hostView.meterColumns[i].dimLayer.frame.width
            XCTAssertFalse(chrome.preampGainRangeLayers[i].isHidden, "channel=\(i)")
            XCTAssertEqual(chrome.preampGainRangeLayers[i].frame.minX, expectedMinX, accuracy: 1e-9, "channel=\(i)")
            XCTAssertEqual(chrome.preampGainRangeLayers[i].frame.width, expectedWidth, accuracy: 1e-9, "channel=\(i)")
        }
    }

    func testDragFillHiddenWithoutDragAndMatchesBandRangeWhileDragging() {
        XCTAssertTrue(makeLaidOutHostView(makeVM()).chromeLayers.dragFillLayer.isHidden, "ドラッグ中でなければ隠れる")

        let band = 6
        let vm = makeVM()
        vm.updateDrag(band: band, db: 7)
        let hostView = makeLaidOutHostView(vm)
        let totalSize = hostView.bounds.size
        let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
        let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let grid = chromeGrid(for: geo)
        let baselineY = geo.dbToY(0)
        let gy = geo.dbToY(vm.gains[band])
        guard let range = grid.rowIndexRange(intersectingTop: min(baselineY, gy), bottom: max(baselineY, gy)) else {
            return XCTFail("前提: 当たる段があること")
        }
        let expectedTop = grid.rowY(range.upperBound).top
        let expectedBottom = grid.rowY(range.lowerBound).bottom
        let bar = geo.barRect(band)

        let fill = hostView.chromeLayers.dragFillLayer
        XCTAssertFalse(fill.isHidden, "ドラッグ中は見える")
        for layer in hostView.chromeLayers.preampDragFillLayers {
            XCTAssertTrue(layer.isHidden, "メーター側の塗りは出さない")
        }
        XCTAssertEqual(fill.frame.minX, bar.minX, accuracy: 1e-9)
        XCTAssertEqual(fill.frame.width, bar.width, accuracy: 1e-9)
        XCTAssertEqual(fill.frame.minY, expectedTop, accuracy: 1e-9)
        XCTAssertEqual(fill.frame.height, expectedBottom - expectedTop, accuracy: 1e-9)
    }

    func testPreampDragFillHiddenWithoutDragAndMatchesBothMeterBarsWhileDragging() {
        for layer in makeLaidOutHostView(makeVM()).chromeLayers.preampDragFillLayers {
            XCTAssertTrue(layer.isHidden, "ドラッグ中でなければ隠れる")
        }

        let vm = makeVM()
        vm.updatePreampDrag(db: -5)
        let hostView = makeLaidOutHostView(vm)
        let totalSize = hostView.bounds.size
        let eqWidth = EQLayout.eqContentWidth(totalWidth: totalSize.width, showLevelMeter: vm.showLevelMeter)
        let geo = EQPlotGeometry(size: CGSize(width: eqWidth, height: totalSize.height), floorDb: vm.floorDb, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let grid = chromeGrid(for: geo)
        let baselineY = geo.dbToY(0)
        let py = geo.dbToY(vm.preampDb)
        guard let range = grid.rowIndexRange(intersectingTop: min(baselineY, py), bottom: max(baselineY, py)) else {
            return XCTFail("前提: 当たる段があること")
        }
        let expectedTop = grid.rowY(range.upperBound).top
        let expectedBottom = grid.rowY(range.lowerBound).bottom
        let chrome = hostView.chromeLayers

        for i in 0..<chrome.preampDragFillLayers.count {
            let fill = chrome.preampDragFillLayers[i]
            let expectedMinX = hostView.meterContainer.frame.minX + hostView.meterColumns[i].dimLayer.frame.minX
            XCTAssertFalse(fill.isHidden, "channel=\(i) はドラッグ中に見える")
            XCTAssertEqual(fill.frame.minX, expectedMinX, accuracy: 1e-9, "channel=\(i)")
            XCTAssertEqual(fill.frame.width, hostView.meterColumns[i].dimLayer.frame.width, accuracy: 1e-9, "channel=\(i)")
            XCTAssertEqual(fill.frame.minY, expectedTop, accuracy: 1e-9, "channel=\(i)")
            XCTAssertEqual(fill.frame.height, expectedBottom - expectedTop, accuracy: 1e-9, "channel=\(i)")
            XCTAssertNotNil(fill.contents, "EQ バーと同じ帯画像が貼られていること")
        }
        XCTAssertTrue(chrome.dragFillLayer.isHidden, "EQ 側の塗りは出さない")
    }

    func testDragFillsHiddenWhileProcessingIsNotInEffect() {
        let vm = makeVM()
        vm.updatePreampDrag(db: -5)
        let hostView = makeLaidOutHostView(vm)
        let chrome = hostView.chromeLayers
        for layer in chrome.preampDragFillLayers {
            XCTAssertFalse(layer.isHidden, "前提: 加工が効いていれば見える")
        }
        XCTAssertFalse(chrome.dragBadgeLayer.isHidden, "前提: バッジも見えている")

        vm.bypass = true
        hostView.viewModelSettingsChanged()

        for layer in chrome.preampDragFillLayers {
            XCTAssertTrue(layer.isHidden, "メーター側の塗りが残らない")
        }
        XCTAssertTrue(chrome.dragFillLayer.isHidden, "EQ 側の塗りが残らない")
        XCTAssertTrue(chrome.dragBadgeLayer.isHidden, "バッジが残らない")
    }

    func testDragBadgeContentsStayStableAcrossSameIntegerDbAndChangeWhenDbChanges() {
        let band = 3
        let vm = makeVM()
        vm.updateDrag(band: band, db: 5)
        let hostView = makeLaidOutHostView(vm)
        let badgeLayer = hostView.chromeLayers.dragBadgeLayer
        guard let firstContents = badgeLayer.contents else { return XCTFail("バッジが焼けていない") }

        vm.updateDrag(band: band, db: 5.3) // 四捨五入すると同じ 5 のまま
        hostView.viewModelSettingsChanged()
        XCTAssertTrue(
            (badgeLayer.contents as! CGImage) === (firstContents as! CGImage),
            "同じ整数 dB のままなら contents は同一インスタンスのままであること"
        )

        vm.updateDrag(band: band, db: 9)
        hostView.viewModelSettingsChanged()
        XCTAssertFalse(
            (badgeLayer.contents as! CGImage) === (firstContents as! CGImage),
            "dB が変わったフレームで contents が差し替わること"
        )
    }

    func testViewModelSettingsChangedReflectsChromeStateWhileTimerIsStopped() {
        let vm = makeVM()
        let hostView = makeLaidOutHostView(vm)
        XCTAssertTrue(hostView.chromeLayers.backChromeContainer.isHidden, "前提: 待機中は白オーバーレイが隠れている")

        vm.handlesRevealed = true
        for k in 0...200 { vm.tick(now: Date(timeIntervalSinceReferenceDate: Double(k) * 0.016)) }
        XCTAssertEqual(vm.handleAlpha, 1, "前提: tick により handleAlpha が動いていること")
        // tick 自体はレイヤへ反映しない。
        XCTAssertTrue(hostView.chromeLayers.handleLinesContainer.isHidden, "反映前はまだ隠れたままであること")

        hostView.viewModelSettingsChanged()
        XCTAssertFalse(hostView.chromeLayers.handleLinesContainer.isHidden, "viewModelSettingsChanged が現在値を反映すること")
    }

    // Timer 稼働中は毎フレームの駆動だけで chrome が追随すること (明示呼び出し無しで反映される)。
    func testChromeStaysInSyncViaTheRunningTimerAlone() {
        let vm = makeVM()
        vm.handlesRevealed = true
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }

        pumpRunLoopUntil({ !hostView.chromeLayers.handleLinesContainer.isHidden })
        XCTAssertFalse(hostView.chromeLayers.handleLinesContainer.isHidden, "Timer 駆動だけでハンドル線が見えるようになること")
    }

    /// ウィンドウを表示してタイマを起動し、以降は自前の駆動だけが反映経路になる状態を作る。
    private func makeTimerDrivenHostView(_ vm: EQViewModel) -> (VisualizerHostView, NSWindow) {
        let hostView = VisualizerHostView(viewModel: vm, compact: false)
        hostView.frame = CGRect(origin: .zero, size: CGSize(width: EQLayout.windowDefaultSize.width, height: shippedHostHeight))
        hostView.pinPointerInsideVisualizeArea()
        // 原点とホストのオフセットがどちらも 0 だと screen ↔ window ↔ view の変換が恒等になり、
        // 取り違えても検証が通ってしまう。
        let windowSize = CGSize(width: hostView.frame.width, height: hostView.frame.height + EQLayout.topBarHeight)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.setFrameOrigin(NSPoint(x: 120, y: 80))
        let container = NSView(frame: CGRect(origin: .zero, size: windowSize))
        hostView.frame = CGRect(
            x: 0, y: EQLayout.topBarHeight, width: hostView.frame.width, height: hostView.frame.height
        )
        container.addSubview(hostView)
        window.contentView = container
        hostView.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        vm.visualizerActive = true
        hostView.viewModelSettingsChanged()
        return (hostView, window)
    }

    // 変換の向きを誤ってもテストが通らないよう、期待値はウィンドウ矩形の算術だけから作る。
    func testPointerOutsideTheWindowHidesTheHandlesAndInsideKeepsThem() {
        let vm = makeVM()
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        let frame = window.frame

        vm.noteCanvasPointerDown()
        hostView.pinPointer(toScreenPoint: NSPoint(x: frame.minX + 10, y: frame.maxY - 10))
        pumpRunLoopUntil({ false }, timeout: 0.2)
        XCTAssertTrue(vm.handlesRevealed, "描画領域の中のポインタでは表示を保つこと")

        // 上部バーぶんの帯はホストの外。横方向だけでなく縦方向の取り違えも検出させる。
        hostView.pinPointer(toScreenPoint: NSPoint(x: frame.minX + 10, y: frame.minY + 10))
        pumpRunLoopUntil({ !vm.handlesRevealed })
        XCTAssertFalse(vm.handlesRevealed, "描画領域より下のポインタでは表示を落とすこと")

        vm.noteCanvasPointerDown()
        hostView.pinPointer(toScreenPoint: NSPoint(x: frame.minX - 200, y: frame.maxY - 10))
        pumpRunLoopUntil({ !vm.handlesRevealed })
        XCTAssertFalse(vm.handlesRevealed, "ウィンドウ外のポインタでは表示を落とすこと")
    }

    // ボタンを押している間は、はみ出しても落とさない (ドラッグ中に消えないこと)。
    func testPointerOutsideWhileTheButtonIsDownKeepsTheHandles() {
        let vm = makeVM()
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        let frame = window.frame

        vm.noteCanvasPointerDown()
        hostView.pinPointer(toScreenPoint: NSPoint(x: frame.minX - 200, y: frame.minY + 10), buttonDown: true)
        pumpRunLoopUntil({ false }, timeout: 0.3)
        XCTAssertTrue(vm.handlesRevealed)
    }

    func testTimerFallsToIdleCadenceWhileNoAudioArrivesAndRestoresOnSignal() {
        let (vm, engine) = makeVMWithEngine()
        let fullFps = EQLayout.Tuning.visualizerFpsChoices.max()!
        vm.visualizerFps = fullFps
        XCTAssertGreaterThan(fullFps, EQLayout.Tuning.idleFps, "前提: 設定値が落とす先より大きいこと")

        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        XCTAssertEqual(hostView.visualizerTimerFps, fullFps, "前提: 設定値の刻みで動き出すこと")

        let starving = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { engine.runtimeMetrics.recordRead(requestedFrames: 512, deliveredFrames: 0) }
        }
        RunLoop.main.add(starving, forMode: .common)
        pumpRunLoopUntil({ hostView.visualizerTimerFps == EQLayout.Tuning.idleFps }, timeout: 10)
        XCTAssertEqual(hostView.visualizerTimerFps, EQLayout.Tuning.idleFps, "音が届かず絵も動かない間は刻みを落とすこと")

        hostView.viewModelSettingsChanged()
        XCTAssertEqual(hostView.visualizerTimerFps, fullFps, "設定の変更を受けた回は刻みが戻ること")

        pumpRunLoopUntil({ hostView.visualizerTimerFps == EQLayout.Tuning.idleFps }, timeout: 10)
        starving.invalidate()
        pumpRunLoopUntil({ hostView.visualizerTimerFps == fullFps }, timeout: 10)
        XCTAssertEqual(hostView.visualizerTimerFps, fullFps, "音が届いた時点で刻みが戻ること")
    }

    func testTimerKeepsFullCadenceWhileTheMeterStillMovesWithoutAudio() {
        let (vm, engine) = makeVMWithEngine()
        let fullFps = EQLayout.Tuning.visualizerFpsChoices.max()!
        vm.visualizerFps = fullFps

        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }

        let starving = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { engine.runtimeMetrics.recordRead(requestedFrames: 512, deliveredFrames: 0) }
        }
        RunLoop.main.add(starving, forMode: .common)
        defer { starving.invalidate() }

        // 音は届かないが表示値は動き続ける状態を作る (減衰やフェードが進んでいる間に相当)。
        var level = -80.0
        let moving = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                level += 0.25
                engine.levelMeter.setSnapshotForTesting(LevelMeter.Snapshot(
                    levels: Array(repeating: level, count: EQSpec.bandCount),
                    peaks: Array(repeating: level, count: EQSpec.bandCount),
                    stereo: LevelMeter.Snapshot.Stereo(leftDb: level, rightDb: level, leftPeakDb: level, rightPeakDb: level)
                ))
            }
        }
        RunLoop.main.add(moving, forMode: .common)
        defer { moving.invalidate() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            XCTAssertEqual(hostView.visualizerTimerFps, fullFps, "絵が動いている間は刻みを落とさないこと")
        }
    }

    func testTimerDrivenFrameReflectsANewMeterSnapshot() {
        let band = 4
        let (vm, engine) = makeVMWithEngine()
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        let litLayer = hostView.eqColumns[band].litLayer
        XCTAssertEqual(litLayer.frame.height, 0, "前提: 観測が届く前は点灯していないこと")

        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[band] = -10
        // 明示的な tick は挟まない (稼働中のタイマ自身が解析器から引き出すことを見たいテストのため)。
        engine.levelMeter.setSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot))

        pumpRunLoopUntil({ litLayer.frame.height > 0 })
        XCTAssertGreaterThan(litLayer.frame.height, 0, "押し出された値がタイマ駆動だけで反映されること")
    }

    // レベルが動いていると変化に相乗りして反映されてしまうため、静止させて開始・終了だけを見る。
    func testTimerDrivenFrameReflectsDragStartAndEndWhileLevelsStayStill() {
        let band = 6
        let vm = makeVM()
        // フェードが始まらないよう、出きるまでの待ちが短い段でハンドルを出しっぱなしにする。
        vm.handleFadeLevel = EQLayout.Tuning.handleFade.values.count
        vm.handlesRevealed = true
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        let dragFill = hostView.chromeLayers.dragFillLayer
        pumpRunLoopUntil({ vm.handleAlpha == 1 })
        XCTAssertEqual(vm.handleAlpha, 1, "前提: ハンドルが出きっていてフェードが止まっていること")
        XCTAssertTrue(dragFill.isHidden, "前提: ドラッグしていない間はドラッグ帯が隠れていること")

        vm.updateDrag(band: band, db: 8)
        pumpRunLoopUntil({ !dragFill.isHidden })
        XCTAssertFalse(dragFill.isHidden, "ドラッグの開始がタイマ駆動だけで反映されること")

        let firstRect = dragFill.frame
        vm.updateDrag(band: band, db: 2)
        pumpRunLoopUntil({ dragFill.frame != firstRect })
        XCTAssertNotEqual(dragFill.frame, firstRect, "ドラッグ中のゲインの変化がタイマ駆動だけで反映されること")

        vm.endDrag()
        pumpRunLoopUntil({ dragFill.isHidden })
        XCTAssertTrue(dragFill.isHidden, "ドラッグの終了がタイマ駆動だけで反映されること")
    }

    // 上の 3 件が「省いても取りこぼさない」側を見るのに対し、こちらは「実際に省いている」側を見る。
    func testTimerDrivenFrameSkipsReflectionWhileNothingChanges() {
        let band = 5
        let (vm, engine) = makeVMWithEngine()
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[band] = -10

        // visualizerActive の true 化をまたぐと注入した値が消えるため、タイマ駆動を起こしてから注入する。
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        engine.levelMeter.setSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot))
        let litLayer = hostView.eqColumns[band].litLayer
        pumpRunLoopUntil({ litLayer.frame.height > 0 })
        XCTAssertGreaterThan(litLayer.frame.height, 0, "前提: 押し出された値が反映されていること")

        // ここから先は押し出しも操作も無く、ハンドルも出ていないため映る値は動かない。
        litLayer.frame = .zero
        let framesBefore = vm.tickInvocationCount
        let framesToWatch = 3
        pumpRunLoopUntil({ vm.tickInvocationCount > framesBefore + framesToWatch })
        XCTAssertGreaterThan(
            vm.tickInvocationCount, framesBefore + framesToWatch,
            "前提: 見たいフレーム数ぶんタイマが回り続けていること"
        )
        XCTAssertEqual(litLayer.frame, .zero, "映る値が動いていないフレームでは代入しないこと")
    }

    func testTimerDrivenFrameReflectsPublishedChangeWhileLevelsStayStill() {
        let band = 2
        let (vm, engine) = makeVMWithEngine()
        var levels = Array(repeating: LevelMeter.silentLevelDb, count: EQSpec.bandCount)
        levels[band] = -10

        // visualizerActive の true 化をまたぐと注入した値が消えるため、タイマ駆動を起こしてから注入する。
        let (hostView, window) = makeTimerDrivenHostView(vm)
        defer { window.orderOut(nil) }
        engine.levelMeter.setSnapshotForTesting(LevelMeter.Snapshot(levels: levels, peaks: levels, stereo: silentStereoSnapshot))
        let capLayer = hostView.eqColumns[band].capLayer
        pumpRunLoopUntil({ !capLayer.isHidden })
        XCTAssertFalse(capLayer.isHidden, "前提: ピークホールドが有効な間はキャップが出ていること")

        vm.peakHoldEnabled = false
        hostView.viewModelSettingsChanged()

        pumpRunLoopUntil({ capLayer.isHidden })
        XCTAssertTrue(capLayer.isHidden, "ピークホールドの変更がタイマ駆動のフレームへ反映されること")
    }

}

