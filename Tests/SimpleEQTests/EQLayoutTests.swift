import XCTest
@testable import SimpleEQ

final class EQLayoutTests: XCTestCase {
    private let scale = EQLayout.Tuning.LevelScale(values: [10, 20, 30], defaultLevel: 2)
    private var levels: [Double] { scale.values }

    // コンパクトの行の右端は、スクロールバーの内側に入らない位置まで下がっていること。
    // 実装式を書き写すと式を変えたときに期待値も一緒に動くため、満たすべき条件の側から書く。
    func testCompactRowLeavesRoomForTheScroller() {
        XCTAssertGreaterThan(EQLayout.Mixer.scrollerGutter, 0, "OS がスクロールバーの実寸を返すこと")
        XCTAssertGreaterThan(
            EQLayout.Mixer.compactRowTrailingPadding, EQLayout.Mixer.scrollerGutter,
            "スクロールバーの幅より広く空け、行の右端がバーの下に入らないこと"
        )
        XCTAssertGreaterThan(
            EQLayout.Mixer.compactRowTrailingPadding, EQLayout.Mixer.rowHorizontalPadding,
            "通常の行の余白より広いこと"
        )
    }

    // fixture の段数を実際の項目とわざと違える (同じ数だと特定の数をベタ書きした実装でも通ってしまうため)。
    func testFixtureLevelCountDiffersFromShippedScales() {
        for shipped in [EQLayout.Tuning.attack, EQLayout.Tuning.release, EQLayout.Tuning.handleFade, EQLayout.Tuning.handlePreview] {
            XCTAssertNotEqual(scale.values.count, shipped.values.count)
        }
    }

    func testValueMapsLevelToArrayIndex() {
        for level in 1...levels.count {
            XCTAssertEqual(scale.value(at: level), levels[level - 1])
        }
    }

    func testValueClampsBelowRange() {
        XCTAssertEqual(scale.value(at: 0), levels[0])
        XCTAssertEqual(scale.value(at: -3), levels[0])
    }

    func testValueClampsAboveRange() {
        XCTAssertEqual(scale.value(at: levels.count + 1), levels[levels.count - 1])
        XCTAssertEqual(scale.value(at: 99), levels[levels.count - 1])
    }

    func testAxisDbTicksRoundTowardZeroToNearestFive() {
        XCTAssertEqual(EQLayout.axisDbTicks(floorDb: -70, steps: 3), [0, -20, -45, -70])
    }

    func testAxisDbTicksRoundingExamples() {
        XCTAssertEqual(EQLayout.axisDbTicks(floorDb: -4, steps: 1), [0, 0])
        XCTAssertEqual(EQLayout.axisDbTicks(floorDb: -9, steps: 1), [0, -5])
        XCTAssertEqual(EQLayout.axisDbTicks(floorDb: -24, steps: 1), [0, -20])
        XCTAssertEqual(EQLayout.axisDbTicks(floorDb: -37, steps: 1), [0, -35])
    }

    // 全角は幅 2、半角は幅 1 として上限まで先頭から切り詰める。
    func testClampToPresetTitleMaxWidthLeavesShortStringUntouched() {
        XCTAssertEqual(EQLayout.clampToPresetTitleMaxWidth("Hello"), "Hello")
    }

    func testClampToPresetTitleMaxWidthMixedWidthTruncatesAtBoundary() {
        let halfWidth = String(repeating: "A", count: 10)
        let fullWidth = String(repeating: "あ", count: 18)
        let result = EQLayout.clampToPresetTitleMaxWidth(halfWidth + fullWidth)
        XCTAssertEqual(result, halfWidth + String(repeating: "あ", count: 15))
    }

    // 数値のベタ書きへの逆戻りを検知するための固定値検証。
    func testTuningStepConstantsMatchExpectedValues() {
        XCTAssertEqual(EQLayout.Tuning.floorDbStep, 2)
    }

    func testVisualizerFpsChoicesAreSortedUniqueAndIncludeTheDefault() {
        XCTAssertTrue(EQLayout.Tuning.visualizerFpsChoices.contains(EQLayout.Tuning.visualizerFpsDefault))
        XCTAssertEqual(EQLayout.Tuning.visualizerFpsChoices, EQLayout.Tuning.visualizerFpsChoices.sorted())
        XCTAssertEqual(Set(EQLayout.Tuning.visualizerFpsChoices).count, EQLayout.Tuning.visualizerFpsChoices.count)
    }

    // レンジを持つ既定値は、そのレンジ内に収まっていること。
    func testSliderTuningDefaultsAreWithinTheirRanges() {
        let items: [(name: String, value: Double, range: ClosedRange<Double>)] = [
            ("floorDb", EQLayout.Tuning.floorDbDefault, EQLayout.Tuning.floorDbRange),
            ("peakHoldSeconds", EQLayout.Tuning.peakHoldSecondsDefault, EQLayout.Tuning.peakHoldSecondsRange),
            ("peakDecayDbPerSec", EQLayout.Tuning.peakDecayDbPerSecDefault, EQLayout.Tuning.peakDecayDbPerSecRange),
            ("peakCapBrightenAmount", EQLayout.Tuning.peakCapBrightenAmountDefault, EQLayout.Tuning.peakCapBrightenAmountRange),
            ("ledDimAmount", EQLayout.Tuning.ledDimAmountDefault, EQLayout.Tuning.ledDimAmountRange),
        ]
        for item in items {
            XCTAssertTrue(item.range.contains(item.value), "\(item.name) の既定値 \(item.value) がレンジ \(item.range) の外にある")
        }
    }

    // 既定の段は、段の並びの範囲内に収まっていること。
    func testLevelTuningDefaultsAreWithinTheirLevelCounts() {
        let items: [(name: String, scale: EQLayout.Tuning.LevelScale)] = [
            ("attack", EQLayout.Tuning.attack),
            ("release", EQLayout.Tuning.release),
            ("handleFade", EQLayout.Tuning.handleFade),
            ("handlePreview", EQLayout.Tuning.handlePreview),
        ]
        for item in items {
            XCTAssertTrue(
                (1...item.scale.values.count).contains(item.scale.defaultLevel),
                "\(item.name) の既定の段 \(item.scale.defaultLevel) が段の数 \(item.scale.values.count) の外にある"
            )
        }
    }

    func testHandleVisibilityThresholdIsPositiveSoFadeCanReachZero() {
        XCTAssertGreaterThan(EQLayout.handleVisibilityThreshold, 0)
    }

    // settle 閾値は出荷時サイズで 1 画素未満に相当する。
    func testHandleDisplayGainSettleThresholdIsSubPixelAtShippedSize() {
        let canvasHeight = EQLayout.windowDefaultSize.height - EQLayout.topBarHeight - EQLayout.freqRowHeight
        let plotHeight = EQLayout.contentVerticalInset(canvasHeight: canvasHeight).height
        let pointsPerDb = plotHeight / (EQSpec.DB_MAX - EQSpec.DB_MIN)
        XCTAssertGreaterThan(EQLayout.handleDisplaySettleThresholdDb, 0)
        XCTAssertLessThan(EQLayout.handleDisplaySettleThresholdDb * pointsPerDb, 1)
    }

    func testEqContentWidthSubtractsLevelMeterColumnWidthOnlyWhenShown() {
        let total: CGFloat = 1000
        XCTAssertEqual(EQLayout.eqContentWidth(totalWidth: total, showLevelMeter: false), total)
        XCTAssertEqual(EQLayout.eqContentWidth(totalWidth: total, showLevelMeter: true), total - EQLayout.levelMeterColumnWidth)
    }
}

final class GainAxisTests: XCTestCase {
    private let scalesUnderTest: [CGFloat] = [1, 2, 1.5, 3]

    func testDbToYAndYToDbRoundTripRoundsToOneDbSteps() {
        for scale in scalesUnderTest {
            let axis = EQLayout.GainAxis(canvasHeight: 400, pixelGrid: EQLayout.PixelGrid(scale: scale))
            for db in stride(from: EQSpec.DB_MIN, through: EQSpec.DB_MAX, by: 1) {
                let y = axis.dbToY(db)
                XCTAssertEqual(axis.yToDb(y), db, "scale=\(scale) db=\(db)")
            }
        }
    }

    func testYToDbClampsOutOfRangeYToTheEdgeDb() {
        let axis = EQLayout.GainAxis(canvasHeight: 400, pixelGrid: EQLayout.PixelGrid(scale: 2))
        XCTAssertEqual(axis.yToDb(axis.top - 1000), EQSpec.DB_MAX)
        XCTAssertEqual(axis.yToDb(axis.top + axis.height + 1000), EQSpec.DB_MIN)
    }

    // DB_MIN/DB_MAX が対称であることの帰結。
    func testZeroDbLandsAtTheVerticalCenter() {
        let axis = EQLayout.GainAxis(canvasHeight: 400, pixelGrid: EQLayout.PixelGrid(scale: 2))
        XCTAssertEqual(axis.dbToY(0), axis.top + axis.height / 2, accuracy: 1e-9)
    }

    // EQ の 0dB 基準線とプリアンプ線が同じ高さに並ぶことの機械的担保。
    func testMatchesTheAxisDerivedFromEQPlotGeometryAtTheSameCanvasHeightAndScale() {
        for scale in scalesUnderTest {
            let pixelGrid = EQLayout.PixelGrid(scale: scale)
            let size = CGSize(width: 1000, height: 400)
            let geo = EQPlotGeometry(size: size, floorDb: EQLayout.Tuning.floorDbDefault, pixelGrid: pixelGrid)
            let standalone = EQLayout.GainAxis(canvasHeight: size.height, pixelGrid: pixelGrid)
            XCTAssertEqual(geo.gainAxis.top, standalone.top, "scale=\(scale)")
            XCTAssertEqual(geo.gainAxis.height, standalone.height, "scale=\(scale)")
            for db in stride(from: EQSpec.DB_MIN, through: EQSpec.DB_MAX, by: 3) {
                XCTAssertEqual(geo.dbToY(db), standalone.dbToY(db), "scale=\(scale) db=\(db)")
            }
        }
    }
}

final class PixelGridTests: XCTestCase {
    // 整数倍の拡大率では論理座標の整数が常に画素境界でもあるため、フォールバックしても境界を外さない。
    func testFallsBackToOneForNonPositiveOrNonFiniteScale() {
        XCTAssertEqual(EQLayout.PixelGrid(scale: 0).scale, 1)
        XCTAssertEqual(EQLayout.PixelGrid(scale: -2).scale, 1)
        XCTAssertEqual(EQLayout.PixelGrid(scale: .nan).scale, 1)
        XCTAssertEqual(EQLayout.PixelGrid(scale: .infinity).scale, 1)
    }

    func testValidScaleIsKeptAsIs() {
        XCTAssertEqual(EQLayout.PixelGrid(scale: 2).scale, 2)
        XCTAssertEqual(EQLayout.PixelGrid(scale: 1.5).scale, 1.5)
    }

    // 整数倍だけでは丸めが恒等でも通ってしまうため、非整数倍も含めて掃引する。
    func testSnappedValuesLandOnPixelMultiples() {
        for scale: CGFloat in [1, 2, 1.5, 3] {
            let grid = EQLayout.PixelGrid(scale: scale)
            var raw: CGFloat = -5
            while raw <= 37 {
                let scaled = grid.snap(raw) * scale
                XCTAssertEqual(scaled, scaled.rounded(), accuracy: 1e-9, "scale=\(scale) raw=\(raw)")
                raw += 0.37
            }
        }
    }
}

/// 段の点灯・キャップ判定を、実装から独立な参照実装と突き合わせて確認する。
final class SegmentGridTests: XCTestCase {
    /// 出荷時ウィンドウの EQ / レベルメーター描画領域の高さ (両者とも同じ値を共有する)。
    private static var shippedContentHeight: CGFloat {
        let canvasHeight = EQLayout.windowDefaultSize.height - EQLayout.topBarHeight - EQLayout.freqRowHeight
        return EQLayout.contentVerticalInset(canvasHeight: canvasHeight).height
    }

    func testCapRowIndexResolvesAtFullScale() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        XCTAssertGreaterThan(grid.rowCount, 0, "前提: 段があること")

        XCTAssertEqual(
            grid.capRowIndex(peakTop: 0), grid.rowCount - 1,
            "0dBFS のピークは最上段のキャップになること"
        )
    }

    func testRowCountMatchesBothIndependentFormulasAtShippedHeight() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))

        var eqBodyCount = 0
        var y = height - EQLayout.segmentHeight
        while y >= 0 {
            eqBodyCount += 1
            y -= EQLayout.segmentStep
        }

        let meterCount = max(1, Int((height / EQLayout.segmentStep).rounded(.down)))

        XCTAssertEqual(grid.rowCount, eqBodyCount)
        XCTAssertEqual(grid.rowCount, meterCount)
    }

    // MARK: - EQ 本体の分類 (lit/dim/peak) の同値検証

    /// 段ごとの分類の参照実装。
    private func referenceEQBodyClassification(
        fillTop: CGFloat, peakTop: CGFloat, peakHoldEnabled: Bool, inEffect: Bool,
        rect: CGRect, segmentHeight: CGFloat, segmentStep: CGFloat
    ) -> [String] {
        var result: [String] = []
        var y = rect.maxY - segmentHeight
        while y >= rect.minY {
            let segmentBottom = y + segmentHeight
            let isTopmost = y - segmentStep < rect.minY
            let straddles = segmentBottom >= peakTop && segmentBottom - segmentStep < peakTop
            let isPeakCap = peakHoldEnabled && (straddles || (isTopmost && peakTop <= segmentBottom - segmentStep))
            if isPeakCap && inEffect {
                result.append("peak")
            } else if segmentBottom >= fillTop || isPeakCap {
                result.append("lit")
            } else {
                result.append("dim")
            }
            y -= segmentStep
        }
        return result
    }

    /// 同じロジックで分類を組み立てる。
    private func gridEQBodyClassification(
        fillTop: CGFloat, peakTop: CGFloat, peakHoldEnabled: Bool, inEffect: Bool, grid: EQLayout.SegmentGrid
    ) -> [String] {
        let litCount = grid.litRowCountByFillTop(fillTop)
        let capIndex = peakHoldEnabled ? grid.capRowIndex(peakTop: peakTop) : nil
        var result: [String] = []
        for i in 0..<grid.rowCount {
            let isPeakCap = capIndex == i
            if isPeakCap && inEffect {
                result.append("peak")
            } else if i < litCount || isPeakCap {
                result.append("lit")
            } else {
                result.append("dim")
            }
        }
        return result
    }

    // キャップと点灯上端が同じ段になるケースも掃引に含めて確認する。
    func testEQBodyClassificationMatchesReferenceAcrossLevelSweep() {
        let floorDb = EQLayout.Tuning.floorDbDefault
        let size = CGSize(width: 1000, height: Self.shippedContentHeight)
        let geo = EQPlotGeometry(size: size, floorDb: floorDb, pixelGrid: EQLayout.PixelGrid(scale: 2))
        let rect = geo.plotRect
        let grid = EQLayout.SegmentGrid(height: rect.height, bottomY: rect.maxY, pixelGrid: geo.pixelGrid)

        func fillTop(forLevel level: Double) -> CGFloat {
            let frac = (level - floorDb) / (0 - floorDb)
            return rect.maxY - CGFloat(frac) * rect.height
        }

        let levels = stride(from: floorDb - 5, through: 0, by: 0.5).map { $0 }
        for level in levels {
            for peakLevel in levels {
                for peakHoldEnabled in [true, false] {
                    for inEffect in [true, false] {
                        let top = fillTop(forLevel: level)
                        let peakTop = fillTop(forLevel: peakLevel)
                        let reference = referenceEQBodyClassification(
                            fillTop: top, peakTop: peakTop, peakHoldEnabled: peakHoldEnabled, inEffect: inEffect,
                            rect: rect, segmentHeight: grid.rowHeight, segmentStep: grid.rowStep
                        )
                        let actual = gridEQBodyClassification(
                            fillTop: top, peakTop: peakTop, peakHoldEnabled: peakHoldEnabled, inEffect: inEffect, grid: grid
                        )
                        XCTAssertEqual(
                            actual, reference,
                            "level=\(level) peakLevel=\(peakLevel) peakHoldEnabled=\(peakHoldEnabled) inEffect=\(inEffect)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - レベルメーターの分類 (lit/dim/peak/clip) の同値検証

    /// 段ごとの分類の参照実装。
    private func referenceMeterClassification(
        litCount: Int, peakRatio: Double, peakHoldEnabled: Bool, inEffect: Bool, clips: Bool, rowCount: Int
    ) -> [String] {
        let capIndex: Int? = {
            guard peakHoldEnabled, peakRatio > 0 else { return nil }
            let peakLitCount = Int((peakRatio * Double(rowCount)).rounded())
            return min(rowCount - 1, max(0, peakLitCount - 1))
        }()
        var result: [String] = []
        for i in 0..<rowCount {
            if clips && i == rowCount - 1 {
                result.append("clip")
            } else if i == capIndex && inEffect {
                result.append("peak")
            } else if i < litCount || i == capIndex {
                result.append("lit")
            } else {
                result.append("dim")
            }
        }
        return result
    }

    /// 同じロジックで分類を組み立てる。レイヤへの反映は対象外。
    private func gridMeterClassification(
        ratio: Double, peakRatio: Double, peakHoldEnabled: Bool, inEffect: Bool, clips: Bool, grid: EQLayout.SegmentGrid
    ) -> [String] {
        let litCount = grid.litRowCountByRatio(ratio)
        let capIndex = peakHoldEnabled ? grid.capRowIndexByRatio(peakRatio) : nil
        var result: [String] = []
        for i in 0..<grid.rowCount {
            if clips && i == grid.rowCount - 1 {
                result.append("clip")
            } else if i == capIndex && inEffect {
                result.append("peak")
            } else if i < litCount || i == capIndex {
                result.append("lit")
            } else {
                result.append("dim")
            }
        }
        return result
    }

    func testMeterClassificationMatchesReferenceAcrossRatioSweep() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 2))
        let ratios = stride(from: 0.0, through: 1.0, by: 0.02).map { $0 }

        for ratio in ratios {
            for peakRatio in ratios {
                for peakHoldEnabled in [true, false] {
                    for inEffect in [true, false] {
                        for clips in [true, false] {
                            let litCount = Int((ratio * Double(grid.rowCount)).rounded())
                            let reference = referenceMeterClassification(
                                litCount: litCount, peakRatio: peakRatio, peakHoldEnabled: peakHoldEnabled,
                                inEffect: inEffect, clips: clips, rowCount: grid.rowCount
                            )
                            let actual = gridMeterClassification(
                                ratio: ratio, peakRatio: peakRatio, peakHoldEnabled: peakHoldEnabled, inEffect: inEffect,
                                clips: clips, grid: grid
                            )
                            XCTAssertEqual(
                                actual, reference,
                                "ratio=\(ratio) peakRatio=\(peakRatio) peakHoldEnabled=\(peakHoldEnabled) "
                                    + "inEffect=\(inEffect) clips=\(clips)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 段の矩形・点灯高さの幾何アサーション

    func testRowRectsAreUniformHeightNonOverlappingAndAscending() {
        for scale: CGFloat in [1, 2, 1.5, 3] {
            let pixelGrid = EQLayout.PixelGrid(scale: scale)
            let height = Self.shippedContentHeight
            let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: pixelGrid)
            var previousTop: CGFloat?
            for i in 0..<grid.rowCount {
                let rect = grid.rowRect(i, x: 0, width: 10)
                XCTAssertEqual(rect.height, grid.rowHeight, "scale=\(scale) i=\(i)")
                let scaledTop = rect.minY * scale
                XCTAssertEqual(scaledTop, scaledTop.rounded(), accuracy: 1e-9, "scale=\(scale) i=\(i)")
                if let previousTop {
                    XCTAssertLessThan(rect.maxY, previousTop, "scale=\(scale) i=\(i) が下の段と重ならないこと")
                }
                previousTop = rect.minY
            }
        }
    }

    func testLitHeightIsZeroForZeroRowsAndStepMultipleOtherwise() {
        let grid = EQLayout.SegmentGrid(height: Self.shippedContentHeight, bottomY: Self.shippedContentHeight, pixelGrid: EQLayout.PixelGrid(scale: 2))
        XCTAssertEqual(grid.litHeight(forRowCount: 0), 0)
        for n in 1...grid.rowCount {
            XCTAssertEqual(grid.litHeight(forRowCount: n), CGFloat(n) * grid.rowStep)
        }
    }

    func testCapRowIndexIsNilWhenPeakIsAtOrBelowFloor() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        XCTAssertNil(grid.capRowIndex(peakTop: height + 1))
        XCTAssertNil(grid.capRowIndexByRatio(0))
    }

    func testCapTakesPriorityOverLitWhenBothLandOnTheSameRow() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let sameTop = grid.rowY(3).bottom
        let litCount = grid.litRowCountByFillTop(sameTop)
        let capIndex = grid.capRowIndex(peakTop: sameTop)
        XCTAssertEqual(capIndex, litCount - 1, "点灯上端とキャップが同じ段に来ること")
        let classification = gridEQBodyClassification(
            fillTop: sameTop, peakTop: sameTop, peakHoldEnabled: true, inEffect: true, grid: grid
        )
        XCTAssertEqual(classification[capIndex!], "peak")
    }

    // MARK: - rowIndexRange (重なる段の連続 index 範囲)

    private func referenceRowIndexRange(_ grid: EQLayout.SegmentGrid, top: CGFloat, bottom: CGFloat) -> ClosedRange<Int>? {
        var hits: [Int] = []
        for i in 0..<grid.rowCount {
            let row = grid.rowY(i)
            if row.bottom > top && row.top < bottom { hits.append(i) }
        }
        guard let lo = hits.first, let hi = hits.last else { return nil }
        return lo...hi
    }

    func testRowIndexRangeMatchesReferenceAndIsContiguousAcrossSweep() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 2))
        let ys = stride(from: -10.0, through: Double(height) + 10, by: 3.7).map { CGFloat($0) }

        for top in ys {
            for bottom in ys where bottom >= top {
                let reference = referenceRowIndexRange(grid, top: top, bottom: bottom)
                let actual = grid.rowIndexRange(intersectingTop: top, bottom: bottom)
                XCTAssertEqual(actual, reference, "top=\(top) bottom=\(bottom)")
                if let actual {
                    XCTAssertEqual(
                        Array(actual.lowerBound...actual.upperBound), Array(actual),
                        "top=\(top) bottom=\(bottom) の範囲が連続な index 列であること"
                    )
                }
            }
        }
    }

    func testRowIndexRangeIsNilWhenNoRowIntersects() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        XCTAssertNil(grid.rowIndexRange(intersectingTop: -1000, bottom: -500))
        XCTAssertNil(grid.rowIndexRange(intersectingTop: height + 500, bottom: height + 1000))
    }

    func testRowIndexRangeWithZeroHeightRangeHitsOneRowInsideAndNoneOnTheRowBoundary() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let midIndex = grid.rowCount / 2
        let midRow = grid.rowY(midIndex)

        let inside = (midRow.top + midRow.bottom) / 2
        XCTAssertEqual(grid.rowIndexRange(intersectingTop: inside, bottom: inside), midIndex...midIndex, "段の内側なら 1 段だけ当たる")

        let onBoundary = midRow.bottom
        XCTAssertNil(grid.rowIndexRange(intersectingTop: onBoundary, bottom: onBoundary), "段の境目はどちらの半開区間にも属さない")
    }

    func testRowIndexRangeAtGridEdges() {
        let height = Self.shippedContentHeight
        let grid = EQLayout.SegmentGrid(height: height, bottomY: height, pixelGrid: EQLayout.PixelGrid(scale: 1))
        let top = grid.rowY(grid.rowCount - 1).top
        let bottom = grid.rowY(0).bottom

        XCTAssertEqual(grid.rowIndexRange(intersectingTop: top, bottom: bottom), 0...(grid.rowCount - 1), "全段に重なること")
        XCTAssertEqual(grid.rowIndexRange(intersectingTop: bottom - 1, bottom: bottom), 0...0, "最下段だけに重なること")
        XCTAssertEqual(grid.rowIndexRange(intersectingTop: top, bottom: top + 1), (grid.rowCount - 1)...(grid.rowCount - 1), "最上段だけに重なること")
        XCTAssertNil(grid.rowIndexRange(intersectingTop: bottom, bottom: bottom + 100), "最下段より下は当たらない")
        XCTAssertNil(grid.rowIndexRange(intersectingTop: top - 100, bottom: top), "最上段より上は当たらない")
    }
}
