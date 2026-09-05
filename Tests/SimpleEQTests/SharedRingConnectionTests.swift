import XCTest
import SimpleEQRingC
@testable import SimpleEQ

/// 実際のドライバ・CoreAudio を使わず、共有メモリファイルを模したフィクスチャをディスク上に作成して実クラスのまま検証する。
final class SharedRingConnectionTests: XCTestCase {
    private static let magicOffset = 0
    private static let layoutVersionOffset = 4
    private static let driverVersionMajorOffset = 8
    private static let driverVersionMinorOffset = 10
    private static let headerBytesOffset = 12
    private static let ringFramesOffset = 16
    private static let channelsOffset = 20
    private static let sampleRateOffset = 24
    private static let ioCycleFramesOffset = 32
    private static let writeCounterOffset = 40
    private static let epochOffset = 48
    private static let writerIOIsRunningOffset = 52
    private static let tsSeqOffset = 56
    private static let tsWriteCounterOffset = 64
    private static let tsHostTimeOffset = 72
    private static let presentationStallCountOffset = 80
    private static let presentationDeltaUnexpectedCountOffset = 88
    private static let writeDeadlineMissedCountOffset = 96
    private static let silenceFilledGapCountOffset = 104

    private static let structSize = Int(simpleeq_ring_header_size())

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs.removeAll()
        super.tearDown()
    }

    // MARK: - フィクスチャ構築

    /// 「ドライバが書いたはずの共有メモリファイル」を模したフィクスチャを作成する。
    private func makeFixture(
        magic: UInt32 = simpleeq_ring_expected_magic(),
        layoutVersion: UInt32 = simpleeq_ring_expected_layout_version(),
        driverVersionMajor: UInt16 = simpleeq_driver_version_major(),
        driverVersionMinor: UInt16 = simpleeq_driver_version_minor(),
        headerBytes: UInt32? = nil,
        ringFrames: UInt32 = 64,
        channels: UInt32 = 1,
        headerSampleRate: Double = AudioConfig.appliedSampleRate,
        ioCycleFrames: UInt32 = 0,
        writeCounter: UInt64 = 0,
        epoch: UInt32 = 0,
        writerIOIsRunning: UInt32 = 0,
        tsSeq: UInt32 = 0,
        tsWriteCounter: UInt64 = 0,
        tsHostTime: UInt64 = 0,
        presentationStallCount: UInt64 = 0,
        presentationDeltaUnexpectedCount: UInt64 = 0,
        writeDeadlineMissedCount: UInt64 = 0,
        silenceFilledGapCount: UInt64 = 0,
        fileSizeOverride: Int? = nil,
        ringValues: [Float] = []
    ) -> URL {
        let effectiveHeaderBytes = headerBytes ?? UInt32(Self.structSize)
        let ringDataOffset = Int(effectiveHeaderBytes)
        let requiredSize = ringDataOffset + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
        let totalSize = fileSizeOverride ?? requiredSize
        var data = Data(count: totalSize)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            raw.storeBytes(of: magic, toByteOffset: Self.magicOffset, as: UInt32.self)
            raw.storeBytes(of: layoutVersion, toByteOffset: Self.layoutVersionOffset, as: UInt32.self)
            raw.storeBytes(of: driverVersionMajor, toByteOffset: Self.driverVersionMajorOffset, as: UInt16.self)
            raw.storeBytes(of: driverVersionMinor, toByteOffset: Self.driverVersionMinorOffset, as: UInt16.self)
            raw.storeBytes(of: effectiveHeaderBytes, toByteOffset: Self.headerBytesOffset, as: UInt32.self)
            raw.storeBytes(of: ringFrames, toByteOffset: Self.ringFramesOffset, as: UInt32.self)
            raw.storeBytes(of: channels, toByteOffset: Self.channelsOffset, as: UInt32.self)
            raw.storeBytes(of: headerSampleRate, toByteOffset: Self.sampleRateOffset, as: Double.self)
            raw.storeBytes(of: ioCycleFrames, toByteOffset: Self.ioCycleFramesOffset, as: UInt32.self)
            raw.storeBytes(of: writeCounter, toByteOffset: Self.writeCounterOffset, as: UInt64.self)
            raw.storeBytes(of: epoch, toByteOffset: Self.epochOffset, as: UInt32.self)
            raw.storeBytes(of: writerIOIsRunning, toByteOffset: Self.writerIOIsRunningOffset, as: UInt32.self)
            raw.storeBytes(of: tsSeq, toByteOffset: Self.tsSeqOffset, as: UInt32.self)
            raw.storeBytes(of: tsWriteCounter, toByteOffset: Self.tsWriteCounterOffset, as: UInt64.self)
            raw.storeBytes(of: tsHostTime, toByteOffset: Self.tsHostTimeOffset, as: UInt64.self)
            raw.storeBytes(of: presentationStallCount, toByteOffset: Self.presentationStallCountOffset, as: UInt64.self)
            raw.storeBytes(
                of: presentationDeltaUnexpectedCount, toByteOffset: Self.presentationDeltaUnexpectedCountOffset, as: UInt64.self
            )
            raw.storeBytes(of: writeDeadlineMissedCount, toByteOffset: Self.writeDeadlineMissedCountOffset, as: UInt64.self)
            raw.storeBytes(of: silenceFilledGapCount, toByteOffset: Self.silenceFilledGapCountOffset, as: UInt64.self)
            for (i, v) in ringValues.enumerated() {
                raw.storeBytes(of: v, toByteOffset: ringDataOffset + i * MemoryLayout<Float>.size, as: Float.self)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedRingConnectionTests-\(UUID().uuidString).shm")
        try! data.write(to: url)
        tempURLs.append(url)
        return url
    }

    /// フィクスチャの writeCounter だけを書き換える (「ドライバがさらに書き進めた」を模す)。
    private func setWriteCounter(_ url: URL, _ counter: UInt64) {
        writeField(url, offset: Self.writeCounterOffset, value: counter)
    }

    /// フィクスチャの epoch だけを書き換える (「ドライバの IO が再起動した」を模す)。
    private func setEpoch(_ url: URL, _ epoch: UInt32) {
        writeField(url, offset: Self.epochOffset, value: epoch)
    }

    /// フィクスチャのリング本体へ書き込む (「ドライバが新しい音声を書いた」を模す)。
    private func writeRingFrames(_ url: URL, ringFrames: Int, startFrame: Int, values: [Float]) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try! handle.close() }
        for (i, v) in values.enumerated() {
            let index = (startFrame + i) % ringFrames
            handle.seek(toFileOffset: UInt64(Self.structSize + index * MemoryLayout<Float>.size))
            withUnsafeBytes(of: v) { handle.write(Data($0)) }
        }
    }

    private func writeField<T>(_ url: URL, offset: Int, value: T) {
        let handle = try! FileHandle(forWritingTo: url)
        defer { try! handle.close() }
        var v = value
        handle.seek(toFileOffset: UInt64(offset))
        withUnsafeBytes(of: &v) { handle.write(Data($0)) }
    }

    // MARK: - 継ぎ目の包絡の飽和 (下ごしらえ)

    /// クロスフェード長を見るテストとは別で、包絡の長さの参照はこの 1 か所に閉じる。
    private static var envelopeSaturationFrames: Int {
        OccupancyPolicy.silenceSeamFadeFrames(sampleRate: AudioConfig.appliedSampleRate)
    }

    private static func saturationCalls(requestFrames: Int) -> Int {
        (envelopeSaturationFrames + requestFrames - 1) / requestFrames
    }

    private static func saturationFrames(requestFrames: Int) -> Int {
        saturationCalls(requestFrames: requestFrames) * requestFrames
    }

    /// 要求フレーム数は検証本数と揃えること (混ぜると目標バッファ量自体が動く)。
    private func saturateEnvelope(
        _ reader: SharedRingReader, requestFrames: Int,
        file: StaticString = #filePath, line: UInt = #line,
        beforeEachRead: (_ consumedFrames: Int) -> Void = { _ in }
    ) {
        var buffer = [Float](repeating: -1, count: requestFrames)
        var consumed = 0
        for _ in 0..<Self.saturationCalls(requestFrames: requestFrames) {
            beforeEachRead(consumed)
            let got = buffer.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: requestFrames) }
            XCTAssertEqual(got, requestFrames, "前提: 飽和までの各回で要求ぶんが読めること", file: file, line: line)
            consumed += got
        }
    }

    // MARK: - OpenFailure (3 ケース)

    func testOpenFailsWithFileNotFoundWhenPathMissing() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).shm").path
        switch SharedRingReader.open(path: missingPath) {
        case .failure(.fileNotFound): break
        default: XCTFail("fileNotFound を期待")
        }
    }

    func testOpenFailsWithHeaderInvalidWhenMagicMismatches() {
        let url = makeFixture(magic: 0xDEAD_BEEF)
        switch SharedRingReader.open(path: url.path) {
        case .failure(.headerInvalid): break
        default: XCTFail("headerInvalid を期待")
        }
    }

    func testOpenFailsWithVersionMismatchWhenLayoutVersionDiffers() {
        let expected = simpleeq_ring_expected_layout_version()
        let url = makeFixture(layoutVersion: expected + 1)
        switch SharedRingReader.open(path: url.path) {
        case .failure(.versionMismatch(let found, let exp)):
            XCTAssertEqual(found, expected + 1)
            XCTAssertEqual(exp, expected)
        default: XCTFail("versionMismatch を期待")
        }
    }

    // MARK: - バージョン

    // ドライバが書いたバージョンは、そのままの値で読み手とプローブへ届く (アプリ側で組み立てない)。
    func testDriverVersionArrivesAsWrittenByTheDriver() {
        let url = makeFixture(driverVersionMajor: 7, driverVersionMinor: 3)
        let result = SharedRingReader.open(path: url.path)
        guard let reader = try? result.get() else { return XCTFail("開けることを期待") }
        XCTAssertEqual(reader.driverReportedVersion, DriverVersion(major: 7, minor: 3))
        XCTAssertEqual(reader.driverReportedLayoutVersion, simpleeq_ring_expected_layout_version())

        let probe = DriverProbe(openResult: result)
        XCTAssertEqual(probe.availability, .ok)
        XCTAssertEqual(probe.driverVersion, DriverVersion(major: 7, minor: 3))
        XCTAssertEqual(probe.layoutVersion, simpleeq_ring_expected_layout_version())
    }

    // レイアウトバージョンが一致しないときは、アプリが期待する値ではなくドライバが書いた値を返す
    // (再インストールの要否を伝える相手はこちら)。ドライババージョンはその状態では読まない。
    func testProbeReportsTheLayoutVersionTheDriverWroteWhenItDiffers() {
        let expected = simpleeq_ring_expected_layout_version()
        let url = makeFixture(layoutVersion: expected + 1, driverVersionMajor: 7, driverVersionMinor: 3)
        let probe = DriverProbe(openResult: SharedRingReader.open(path: url.path))
        XCTAssertEqual(probe.availability, .versionMismatch)
        XCTAssertEqual(probe.layoutVersion, expected + 1)
        XCTAssertNil(probe.driverVersion, "レイアウトが違う間はドライババージョンを読まない")
    }

    // ドライバが見当たらない場合はバージョンも読めない。
    func testProbeReportsNoVersionsWhenTheDriverIsAbsent() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).shm").path
        let probe = DriverProbe(openResult: SharedRingReader.open(path: missingPath))
        XCTAssertEqual(probe.availability, .notFound)
        XCTAssertNil(probe.driverVersion)
        XCTAssertNil(probe.layoutVersion)
    }

    // 読める値が 1 つも無いときだけ、表示はバージョンの欄そのものを出さない。
    func testVersionsAreReportedAsAbsentOnlyWhenNeitherCanBeRead() {
        let expected = simpleeq_ring_expected_layout_version()
        XCTAssertTrue(
            DriverProbe(openResult: SharedRingReader.open(path: makeFixture().path)).hasReadableVersions,
            "両方読めるとき"
        )
        XCTAssertTrue(
            DriverProbe(openResult: SharedRingReader.open(path: makeFixture(layoutVersion: expected + 1).path))
                .hasReadableVersions,
            "レイアウトが違ってもドライバが書いた値は読める"
        )
        XCTAssertFalse(DriverProbe.versionsUnreadable(.notFound).hasReadableVersions, "ドライバが居ないとき")
        XCTAssertFalse(DriverProbe.versionsUnreadable(.checking).hasReadableVersions, "確認中")
    }

    // 共有メモリファイルが残ったままドライバが入れ替わる経路があり、ヘッダの値が変わるたびに反映される。
    func testDriverVersionsFollowTheHeaderAfterItIsRewritten() {
        let url = makeFixture(driverVersionMajor: 7, driverVersionMinor: 3)
        let metrics = AudioRuntimeMetrics()
        guard let reader = try? SharedRingReader.open(path: url.path).get() else {
            return XCTFail("開けることを期待")
        }
        reader.adopt(metrics: metrics)
        reader.refreshDriverObservations()
        XCTAssertEqual(metrics.driverVersion, DriverVersion(major: 7, minor: 3))

        // 書き手がヘッダを書き直した状態を作る (読み手は同じマッピングを保ったまま)。
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.seek(toOffset: UInt64(Self.driverVersionMajorOffset))
        handle.write(Data([9, 0, 5, 0]))
        try! handle.close()

        reader.refreshDriverObservations()
        XCTAssertEqual(metrics.driverVersion, DriverVersion(major: 9, minor: 5), "読み直した値が載る")
    }

    func testOpenSucceedsWithValidHeader() {
        let url = makeFixture()
        switch SharedRingReader.open(path: url.path) {
        case .success: break
        case .failure(let f): XCTFail("成功を期待したが失敗: \(f)")
        }
    }

    // MARK: - 2 段 mmap: 実ファイル長の検証

    // 申告長が実ファイル長を上回るフィクスチャは不正なヘッダとして拒否される。
    func testOpenFailsWithHeaderInvalidWhenDeclaredSizeExceedsActualFileSize() {
        let ringFrames: UInt32 = 1024
        let channels: UInt32 = 2
        let requiredSize = Self.structSize + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
        let url = makeFixture(ringFrames: ringFrames, channels: channels, fileSizeOverride: requiredSize - 1)
        switch SharedRingReader.open(path: url.path) {
        case .failure(.headerInvalid): break
        default: XCTFail("headerInvalid を期待 (申告長が実ファイル長を上回る)")
        }
    }

    func testOpenSucceedsWhenActualFileSizeExactlyMatchesDeclaredSize() {
        let ringFrames: UInt32 = 1024
        let channels: UInt32 = 2
        let requiredSize = Self.structSize + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size
        let url = makeFixture(ringFrames: ringFrames, channels: channels, fileSizeOverride: requiredSize)
        switch SharedRingReader.open(path: url.path) {
        case .success: break
        case .failure(let f): XCTFail("成功を期待したが失敗: \(f)")
        }
    }

    // MARK: - DriverAvailability への変換

    func testDriverAvailabilityMapsOpenResultToUserFacingStates() {
        let okResult = SharedRingReader.open(path: makeFixture().path)
        XCTAssertEqual(DriverAvailability(openResult: okResult), .ok)

        let missing: Result<SharedRingReader, SharedRingReader.OpenFailure> = .failure(.fileNotFound)
        XCTAssertEqual(DriverAvailability(openResult: missing), .notFound)

        let invalid: Result<SharedRingReader, SharedRingReader.OpenFailure> = .failure(.headerInvalid)
        XCTAssertEqual(DriverAvailability(openResult: invalid), .notFound)

        let mismatch: Result<SharedRingReader, SharedRingReader.OpenFailure> =
            .failure(.versionMismatch(found: 999, expected: 1))
        XCTAssertEqual(DriverAvailability(openResult: mismatch), .versionMismatch)
    }

    // MARK: - 占有量計算

    func testReadReturnsAvailableFramesBasedOnWriteCounterDelta() {
        // 位置検証は先に包絡を飽和させてから行う (ランプ区間と分離するため)。
        let verifyFrames = 50
        let saturationFrames = Self.saturationFrames(requestFrames: verifyFrames)
        let totalFrames = saturationFrames + verifyFrames * 2
        let ringFrames: UInt32 = UInt32(totalFrames) * 2
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(totalFrames),
            ringValues: (0..<totalFrames).map { Float($0) }
        )
        // バッファ量制御は専用テストで検証するため、ここでは無効化して占有量計算だけを見る。
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        saturateEnvelope(reader, requestFrames: verifyFrames)

        var dst = [Float](repeating: -1, count: verifyFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: verifyFrames) }

        XCTAssertEqual(got, verifyFrames)
        XCTAssertEqual(dst, (saturationFrames..<(saturationFrames + verifyFrames)).map { Float($0) })

        var dst2 = [Float](repeating: -1, count: verifyFrames * 2)
        let got2 = dst2.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: verifyFrames * 2) }
        XCTAssertEqual(got2, verifyFrames, "書き込まれている残りぶんしか読めない")
        XCTAssertEqual(
            Array(dst2[0..<verifyFrames]),
            ((saturationFrames + verifyFrames)..<(saturationFrames + verifyFrames * 2)).map { Float($0) }
        )
    }

    // MARK: - トリミング量計算・初回同期 (接続直後の不連続としての即時同期)

    func testInitialSyncTrimsBacklogWithoutFadeAndCountsSeparatelyFromResync() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = maxOccupancy + target   // 上限を確実に超える量
        let saturationFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let freshFrames = target + saturationFrames + clientRequestFrames
        let ringFrames: UInt32 = UInt32(backlog + freshFrames)
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(backlog),
            ringValues: (0..<backlog).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        // 最初の read は「鳴っていた音の続き」が無いためフェードなしで書き手位置まで捨てる。
        XCTAssertEqual(got, 0, "接続前のデータは 1 フレームも返さない")
        XCTAssertEqual(dst, [Float](repeating: 0, count: clientRequestFrames), "プライミング中は無音")

        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 1)
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncDiscardedFrameCount, UInt64(backlog))
        XCTAssertEqual(reader.metrics.resyncEventCount, 0, "初回同期は通常の再同期の計上に混ざらない")

        writeRingFrames(
            url, ringFrames: Int(ringFrames), startFrame: backlog,
            values: (0..<writerBlockFrames).map { Float(2_000_000 + $0) }
        )
        setWriteCounter(url, UInt64(backlog + writerBlockFrames))

        let gotWhilePriming = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertLessThan(writerBlockFrames, target, "前提: この書き込み量では目標バッファ量に届かない")
        XCTAssertEqual(gotWhilePriming, 0, "目標バッファ量に満たない間は無音を返す (部分読みにしない)")
        XCTAssertEqual(reader.metrics.partialReadCount, 0, "プライミング中は供給不足として数えない")

        let freshValues = (0..<freshFrames).map { Float(1_000_000 + $0) }
        writeRingFrames(url, ringFrames: Int(ringFrames), startFrame: backlog, values: freshValues)
        setWriteCounter(url, UInt64(backlog + target))

        let gotAfterPriming = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(gotAfterPriming, clientRequestFrames, "目標バッファ量に達したので要求ぶん全て返る")

        // 位置の検証は包絡を飽和させてから行う。
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(backlog + target + consumed + clientRequestFrames))
        }

        let verified = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(verified, clientRequestFrames)
        // 消費済みは「プライミング完了後の 1 回 + 飽和ぶん」。その続きが返ることを見る。
        let verifiedStart = clientRequestFrames + saturationFrames
        XCTAssertEqual(
            dst, Array(freshValues[verifiedStart..<(verifiedStart + clientRequestFrames)]),
            "返るのは接続位置以降に書かれたデータだけ (接続前のデータは混ざらない)"
        )
    }


    func testInitialSyncDiscardedFrameCountIsCappedAtRingCapacity() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        let ringFrames: UInt32 = 4096
        let hugeBacklog = Int(ringFrames) * 100 // ドライバの長時間稼働ぶんの帳尻合わせを模す
        let url = makeFixture(ringFrames: ringFrames, writeCounter: UInt64(hugeBacklog))
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 1)
        XCTAssertGreaterThan(UInt64(hugeBacklog - target), UInt64(ringFrames), "前提: カウンタ上の差分がリング容量を超えていること")
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncDiscardedFrameCount, UInt64(ringFrames), "報告される破棄量はリング容量を超えない")
    }

    // MARK: - 不連続の再同期のフェード (段差をクリックにしない)

    func testImmediateResyncFadesAmplitudeAcrossTheSeamInsteadOfJumpingAbruptly() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let fadeFrames = OccupancyPolicy.seamFadeFrames(sampleRate: AudioConfig.appliedSampleRate)
        let warmupFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let backlog = warmupFrames + maxOccupancy + target
        let newCursorStart = backlog - target

        // 旧カーソル側・新カーソル側で振幅を大きく変え (-1 と +1)、フェードが段差を埋めることを見る。
        var ringValues = [Float](repeating: -1, count: backlog)
        for i in newCursorStart..<backlog { ringValues[i] = 1 }
        // ringFrames は backlog を大きく上回る値にし、旧カーソル位置と混ぜられる段差にする。
        let ringFrames = UInt32(backlog * 4)
        let url = makeFixture(ringFrames: ringFrames, writeCounter: UInt64(clientRequestFrames), ringValues: ringValues)
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false, initialWriterBlockFrames: writerBlockFrames).get()

        // 初回同期ではない状態を作り、あわせて継ぎ目の包絡を飽和させる。
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(consumed + clientRequestFrames))
        }

        // 不連続は書き手の IO 再起動 (epoch の変化) で駆動する。
        setWriteCounter(url, UInt64(backlog))
        setEpoch(url, 1)
        var dst = [Float](repeating: -99, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)

        XCTAssertEqual(dst[0], -1, "フェード先頭は旧カーソル側と連続する")
        XCTAssertEqual(dst[fadeFrames - 1], 1, "フェード末尾は新カーソル側と一致する")
        XCTAssertEqual(dst[fadeFrames], 1, "フェード後は通常どおり新カーソル側の値")

        // フェード区間は一定の傾き (段差 2.0 をフェード長へ均した値) で単調に立ち上がる。
        let expectedStep = Float(2) / Float(fadeFrames - 1)
        for i in 1..<fadeFrames {
            XCTAssertEqual(dst[i] - dst[i - 1], expectedStep, accuracy: 1e-4, "フェード区間は一定の傾きで立ち上がる (i=\(i))")
        }
        XCTAssertEqual(reader.metrics.resyncEventCount, 1, "初回同期ではない不連続は通常の再同期として数える")
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 0)
        XCTAssertEqual(
            reader.metrics.occupancyResetDueToUnmixableSeamCount, 0,
            "混ぜる相手がある段差は目標バッファ量へ着地し、リセットへは倒れない"
        )
    }

    // MARK: - epoch による明示的リセット

    // 書き手の IO 再起動は epoch の変化として観測され、明示的な通知が無くても即時再同期される。
    func testEpochChangeAloneTriggersImmediateResyncWithoutExplicitNotification() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = maxOccupancy + target
        let ringFrames = UInt32(backlog * 4)
        let url = makeFixture(ringFrames: ringFrames, writeCounter: 0, epoch: 1, ringValues: [Float](repeating: 0, count: backlog))
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        // ここで epoch=1 を初回観測として記録する。
        var warmup = [Float](repeating: -99, count: clientRequestFrames)
        _ = warmup.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        // ドライバの IO 再起動を模す: writeCounter を進め、epoch だけを変える。
        setWriteCounter(url, UInt64(backlog))
        setEpoch(url, 2)
        var dst = [Float](repeating: -99, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(got, clientRequestFrames)
        XCTAssertEqual(reader.metrics.resyncEventCount, 1, "epoch の変化だけで不連続として即時再同期される")
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 0)
    }

    // 初回接続時に観測した epoch は「変化」の起点として記録されるだけで、それ自体は不連続を起こさない。
    func testEpochObservedAtFirstConnectionDoesNotByItselfCauseDiscontinuity() {
        let testFrames = 50
        let saturationFrames = Self.saturationFrames(requestFrames: testFrames)
        let totalFrames = saturationFrames + testFrames
        let ringFrames = UInt32(totalFrames) * 2
        let url = makeFixture(ringFrames: ringFrames, writeCounter: UInt64(totalFrames), epoch: 7, ringValues: (0..<totalFrames).map { Float($0) })
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        saturateEnvelope(reader, requestFrames: testFrames)

        var dst = [Float](repeating: -1, count: testFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: testFrames) }
        XCTAssertEqual(got, testFrames)
        XCTAssertEqual(
            dst, (saturationFrames..<(saturationFrames + testFrames)).map { Float($0) },
            "epoch の初回観測値そのものは通常の読み出しに影響しない"
        )
    }

    // MARK: - 混ぜる相手が無い段差 (バッファ量の作り直しへ倒す)

    /// 混ぜる相手が定義できない段差は、目標バッファ量への切り詰めではなくバッファ量の作り直し (リセット) になる。
    private func assertUnmixableSeamResetsOccupancy(
        ringFrames: UInt32, availableAtSeam: Int, writerBlockFrames: Int, clientRequestFrames: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        XCTAssertGreaterThan(availableAtSeam, maxOccupancy, "前提: 上限を超えていること", file: file, line: line)
        XCTAssertGreaterThan(
            availableAtSeam + writerBlockFrames, Int(ringFrames),
            "前提: 次の 1 バーストが旧カーソル側へ届きうる帯であること", file: file, line: line
        )

        // リング内容は物理スロットの位置がそのまま値になるようにし、期待値を読み出し位置から導出する。
        let url = makeFixture(
            ringFrames: ringFrames, writeCounter: UInt64(clientRequestFrames),
            ringValues: (0..<Int(ringFrames)).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(
            path: url.path, primingEnabled: false, initialWriterBlockFrames: writerBlockFrames
        ).get()

        // 初回同期ではない状態を作り、あわせて継ぎ目の包絡を飽和させる。
        saturateEnvelope(reader, requestFrames: clientRequestFrames, file: file, line: line) { consumed in
            setWriteCounter(url, UInt64(consumed + clientRequestFrames))
        }
        let cursorAtSeam = Self.saturationFrames(requestFrames: clientRequestFrames)

        // 段差: 上限超過かつ不連続 (書き手の IO 再起動 = epoch の変化) の状況を作る。
        setWriteCounter(url, UInt64(cursorAtSeam + availableAtSeam))
        setEpoch(url, 1)
        var dst = [Float](repeating: -99, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(got, 0, "混ぜられない段差は書き手位置まで全部捨て、その回は無音を返す", file: file, line: line)
        XCTAssertEqual(reader.metrics.occupancyResetDueToUnmixableSeamCount, 1, file: file, line: line)
        XCTAssertEqual(reader.metrics.resyncEventCount, 0, "目標バッファ量への着地 (通常の再同期) は行わない", file: file, line: line)
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 0, file: file, line: line)
        XCTAssertEqual(
            reader.metrics.reprimeDueToWriterStallCount, 0,
            "自分が 0 にしたバッファ量を、同じ呼び出しの涸れ検知が読み返して再プライミングとして計上しない",
            file: file, line: line
        )
        XCTAssertEqual(
            reader.metrics.occupancyResetDiscardedFrameCountTotal, UInt64(min(availableAtSeam, Int(ringFrames))),
            "報告される破棄量はリングに実在しうる量を超えない", file: file, line: line
        )
        XCTAssertEqual(
            reader.metrics.lastOccupancyResetAvailableFrames, min(availableAtSeam, Int(ringFrames)),
            "破棄する直前のバッファ量も、リングに実在しうる量を超えない値として残る", file: file, line: line
        )

        let cursorAfterReset = cursorAtSeam + availableAtSeam
        saturateEnvelope(reader, requestFrames: clientRequestFrames, file: file, line: line) { consumed in
            setWriteCounter(url, UInt64(cursorAfterReset + consumed + clientRequestFrames))
        }
        let verifiedStart = cursorAfterReset + Self.saturationFrames(requestFrames: clientRequestFrames)
        setWriteCounter(url, UInt64(verifiedStart + clientRequestFrames))
        let verified = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        XCTAssertEqual(verified, clientRequestFrames, file: file, line: line)
        let expected = (0..<clientRequestFrames).map { Float((verifiedStart + $0) % Int(ringFrames)) }
        XCTAssertEqual(dst, expected, "読み直しは書き手位置から続く (全捨ての後は残留が無い)", file: file, line: line)
    }

    // バッファ量がリング容量を超えた回: 旧カーソル位置はすでに上書き済みで、混ぜる相手が存在しない。
    func testUnmixableSeamResetsOccupancyWhenAvailableExceedsRingCapacity() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let availableAtSeam = maxOccupancy + target
        assertUnmixableSeamResetsOccupancy(
            ringFrames: UInt32(availableAtSeam / 2), availableAtSeam: availableAtSeam,
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames
        )
    }

    // 容量との差が書き込み粒度に満たない帯も、容量超過の回と同じ結末になる。
    func testUnmixableSeamResetsOccupancyWhenMarginIsBelowOneWriteBurst() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let availableAtSeam = maxOccupancy + target
        assertUnmixableSeamResetsOccupancy(
            ringFrames: UInt32(availableAtSeam + writerBlockFrames - 1), availableAtSeam: availableAtSeam,
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames
        )
    }

    // MARK: - バッファ量の作り直し (リセット)

    private struct ResetFixture {
        let url: URL
        let reader: SharedRingReader
        let writerBlockFrames: Int
        let clientRequestFrames: Int
        let target: Int
        let maxOccupancy: Int
    }

    /// プライミング完了直後 (目標バッファ量ちょうど) の状態を作る。リセットの契機はこの状態を起点に試す。
    private func makeResetFixture(
        writerBlockFrames: Int = 256, clientRequestFrames: Int = 256,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ResetFixture {
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let ringValueCount = target * 16
        let url = makeFixture(
            ringFrames: UInt32(ringValueCount * 2), writeCounter: UInt64(target),
            ringValues: (0..<ringValueCount).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames, "前提: 目標バッファ量に達して消費が始まっていること", file: file, line: line)

        return ResetFixture(
            url: url, reader: reader, writerBlockFrames: writerBlockFrames,
            clientRequestFrames: clientRequestFrames, target: target, maxOccupancy: maxOccupancy
        )
    }

    func testOccupancyResetDiscardsEverythingAndRebuildsExactlyToTargetOccupancy() {
        let f = makeResetFixture()
        var dst = [Float](repeating: -1, count: f.clientRequestFrames)
        func read() -> Int {
            dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: f.clientRequestFrames) }
        }

        // 出力段が静かだった記録を積んでおく (リセットが数え直すことを見るため)。
        f.reader.observeOutputLevel(peak: 0, effectiveOutputGain: 1, frames: f.clientRequestFrames)
        XCTAssertGreaterThan(f.reader.silentOutputFrameCount, 0, "前提: 静けさの継続が積まれていること")

        // 出力 AUHAL の停止をまたいだ再開を模す。バッファ量は上限以下のままにする。
        let backlogAtReset = f.target
        XCTAssertLessThanOrEqual(backlogAtReset, f.maxOccupancy, "前提: 上限超過を伴わないバッファ量であること")
        setWriteCounter(f.url, UInt64(f.clientRequestFrames + backlogAtReset))
        f.reader.requestOccupancyReset()

        XCTAssertEqual(read(), 0, "書き手位置まで全部捨て、その回は無音を返す")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToOutputRestartCount, 1)
        XCTAssertEqual(f.reader.metrics.occupancyResetDiscardedFrameCountTotal, UInt64(backlogAtReset))
        XCTAssertEqual(
            f.reader.silentOutputFrameCount, 0,
            "読み手自身が無音を返す区間は出力段の静けさではないため、リセットのたびに数え直す"
        )

        f.reader.metrics.reset()   // 窓統計をプライミングの区間だけに限る
        let cursorAfterReset = f.clientRequestFrames + backlogAtReset
        XCTAssertEqual(f.target % f.writerBlockFrames, 0, "前提: 目標バッファ量は書き込み粒度の倍数であること")
        for block in 1...(f.target / f.writerBlockFrames) {
            setWriteCounter(f.url, UInt64(cursorAfterReset + block * f.writerBlockFrames))
            let supplied = block * f.writerBlockFrames
            if supplied < f.target {
                XCTAssertEqual(read(), 0, "目標バッファ量に満たない間は消費しない (供給 \(supplied))")
            } else {
                XCTAssertEqual(read(), f.clientRequestFrames, "目標バッファ量に達した回から消費が始まる")
            }
        }
        let stats = try! XCTUnwrap(f.reader.metrics.availableWindowStats)
        XCTAssertEqual(stats.maxFrames, f.target, "プライミングの完了点は目標バッファ量ちょうど (オーバーシュートしない)")
        XCTAssertEqual(
            f.reader.metrics.primingTrimEventCount, 0,
            "バッファ量 0 から刻みどおりに積んだ回は超過が出ないため切り詰めも起きない"
        )
    }

    /// プライミングが完了するまで書き込みを届け続け、完了した回の直前のバッファ量を返す。
    @discardableResult
    private func supplyUntilPrimingCompletes(
        _ f: ResetFixture, cursor: Int, initialWriteCounter: Int, writeBurstFrames: Int, requestFrames: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> (availableBeforeLanding: Int, consumed: Int) {
        var dst = [Float](repeating: -1, count: requestFrames)
        var writeCounter = initialWriteCounter
        for _ in 0..<Self.primingSupplyAttemptLimit {
            writeCounter += writeBurstFrames
            setWriteCounter(f.url, UInt64(writeCounter))
            let availableBeforeLanding = writeCounter - cursor
            let got = dst.withUnsafeMutableBufferPointer {
                f.reader.read(into: $0.baseAddress!, frames: requestFrames)
            }
            if got > 0 { return (availableBeforeLanding, got) }
        }
        XCTFail("プライミングが完了しなかった", file: file, line: line)
        return (0, 0)
    }

    /// 完了しない場合は前提が崩れている (無限ループにせず失敗させる)。
    private static let primingSupplyAttemptLimit = 64

    // プライミングの出発点がバッファ量 0 でない回 (目標バッファ量の拡大によるプライミング)。着地は切り詰めで目標へ揃う。
    func testPrimingLandsOnTargetWhenItDoesNotStartFromAnEmptyRing() {
        // 出発点が書き込み単位の刻みに乗らないようにする。
        let f = makeResetFixture(writerBlockFrames: 256, clientRequestFrames: 200)
        let grownRequestFrames = 600
        let grownTarget = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: f.writerBlockFrames, clientRequestFrames: grownRequestFrames,
            sampleRate: AudioConfig.appliedSampleRate
        )
        XCTAssertGreaterThan(grownTarget, f.target, "前提: 要求フレーム数の拡大で目標バッファ量が広がること")

        var dst = [Float](repeating: -1, count: grownRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer {
            f.reader.read(into: $0.baseAddress!, frames: grownRequestFrames)
        }
        XCTAssertEqual(got, 0, "前提: 広がった目標にバッファ量が届かずプライミングへ入ること")
        XCTAssertEqual(f.reader.metrics.reprimeDueToTargetGrowthCount, 1)

        let cursor = f.clientRequestFrames
        let landing = supplyUntilPrimingCompletes(
            f, cursor: cursor, initialWriteCounter: f.target,
            writeBurstFrames: f.writerBlockFrames, requestFrames: grownRequestFrames
        )
        let overshoot = landing.availableBeforeLanding - grownTarget
        XCTAssertGreaterThan(overshoot, 0, "前提: 刻みに乗らない出発点から積むと目標を超えて完了すること")
        XCTAssertEqual(f.reader.metrics.primingTrimEventCount, 1, "着地を目標へ揃える切り詰めが起きる")
        XCTAssertEqual(f.reader.metrics.primingTrimDiscardedFrameCount, UInt64(overshoot))
        assertOccupancyLandedOnTarget(
            f, target: grownTarget, consumedAtLanding: landing.consumed, requestFrames: grownRequestFrames
        )
    }

    /// 着地が目標バッファ量ちょうどであることを、次の読み出しが記録するバッファ量から確かめる。
    private func assertOccupancyLandedOnTarget(
        _ f: ResetFixture, target: Int, consumedAtLanding: Int, requestFrames: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        f.reader.metrics.reset()
        var dst = [Float](repeating: -1, count: requestFrames)
        _ = dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: requestFrames) }
        XCTAssertEqual(
            f.reader.metrics.availableWindowStats?.maxFrames, target - consumedAtLanding,
            "着地は目標バッファ量ちょうど (超過が帯の高さとして残らない)", file: file, line: line
        )
    }

    // 書き込みが目標バッファ量の導出に使った単位より大きい単位で届く回も、着地は目標ちょうどへ揃う。
    func testPrimingLandsOnTargetWhenWritesArriveInLargerUnitsThanTheEstimate() {
        let f = makeResetFixture()
        let writeBurstFrames = f.writerBlockFrames * 4

        // 出力 AUHAL の停止をまたいだ再開を模してプライミングへ入る (バッファ量 0 から始まる側)。
        setWriteCounter(f.url, UInt64(f.clientRequestFrames + f.target))
        f.reader.requestOccupancyReset()
        var dst = [Float](repeating: -1, count: f.clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer {
            f.reader.read(into: $0.baseAddress!, frames: f.clientRequestFrames)
        }
        XCTAssertEqual(got, 0, "前提: リセットの回は無音を返しプライミングへ入ること")

        let cursor = f.clientRequestFrames + f.target
        let landing = supplyUntilPrimingCompletes(
            f, cursor: cursor, initialWriteCounter: cursor,
            writeBurstFrames: writeBurstFrames, requestFrames: f.clientRequestFrames
        )
        let overshoot = landing.availableBeforeLanding - f.target
        XCTAssertGreaterThan(overshoot, 0, "前提: 推定より大きい単位で届くと目標を超えて完了すること")
        XCTAssertEqual(f.reader.metrics.primingTrimEventCount, 1)
        XCTAssertEqual(f.reader.metrics.primingTrimDiscardedFrameCount, UInt64(overshoot))
        assertOccupancyLandedOnTarget(
            f, target: f.target, consumedAtLanding: landing.consumed, requestFrames: f.clientRequestFrames
        )
    }

    // 要求フレーム数が変わる読み手では、健全な状態でもバッファ量の山が目標を超える。遊びを超えたところから発火する。
    func testSilenceResetToleratesTheOccupancyRippleOfAReaderWithVaryingRequestSizes() {
        let f = makeResetFixture(writerBlockFrames: 256, clientRequestFrames: 200)
        var dst = [Float](repeating: -1, count: f.writerBlockFrames * 2)
        func read(_ frames: Int) -> Int {
            dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: frames) }
        }
        // 出力段が無音のまま継続時間ぶん経過したことにする。
        f.reader.observeOutputLevel(
            peak: 0, effectiveOutputGain: 1, frames: OccupancyPolicy.silenceHoldFrames(sampleRate: AudioConfig.appliedSampleRate)
        )

        // 遊びの内側 (目標 + 書き込み単位ちょうど) の山を、要求フレーム数を変えながら読む。
        var cursor = f.clientRequestFrames
        setWriteCounter(f.url, UInt64(cursor + f.target + f.writerBlockFrames))
        for requestFrames in [120, 180, 150] {
            XCTAssertEqual(read(requestFrames), requestFrames, "遊びの内側では通常どおり消費する")
            cursor += requestFrames
            setWriteCounter(f.url, UInt64(cursor + f.target + f.writerBlockFrames))
        }
        XCTAssertEqual(
            f.reader.metrics.occupancyResetDueToSilenceCount, 0,
            "要求フレーム数の変動で生じる山では発火しない"
        )

        // 遊びを超えた回: 発火する。
        setWriteCounter(f.url, UInt64(cursor + f.target + f.writerBlockFrames + 1))
        XCTAssertEqual(read(150), 0, "遊びを超えたずれは無音の好機に捨てる")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToSilenceCount, 1)
    }

    // 涸れの再プライミング区間も、読み手が無音を返す点はリセット直後と変わらない。
    func testDrainedReprimingDoesNotCountAsOutputSilence() {
        let f = makeResetFixture()
        var dst = [Float](repeating: -1, count: f.clientRequestFrames)
        func read() -> Int {
            dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: f.clientRequestFrames) }
        }

        // 涸れさせる (書き手を進めないまま読み切る)。以後の読み出しはプライミング待ちで 0 を返す。
        while read() > 0 {}
        XCTAssertEqual(read(), 0, "前提: 涸れて消費が止まっていること")

        // 読み手が 0 を返す限り、継続時間を超えるだけ積んでも数え直される。
        let holdFrames = OccupancyPolicy.silenceHoldFrames(sampleRate: AudioConfig.appliedSampleRate)
        var accumulated = 0
        while accumulated <= holdFrames {
            f.reader.observeOutputLevel(peak: 0, effectiveOutputGain: 1, frames: f.clientRequestFrames)
            accumulated += f.clientRequestFrames
            XCTAssertGreaterThan(f.reader.silentOutputFrameCount, 0, "前提: 積む側が働いていること")
            XCTAssertEqual(read(), 0, "前提: 涸れたまま消費が始まらないこと")
            XCTAssertEqual(
                f.reader.silentOutputFrameCount, 0,
                "読み手が実データを返せない回は出力段の静けさとして数えない"
            )
        }
    }

    // リセットが作ったバッファ量 0 を、同じ呼び出しの涸れ検知が書き手停止起因の再プライミングとして数えない。
    func testOccupancyResetIsNotCountedAsAReprimeCausedByAWriterStall() {
        let f = makeResetFixture()
        var dst = [Float](repeating: -1, count: f.clientRequestFrames)

        setWriteCounter(f.url, UInt64(f.clientRequestFrames + f.target))
        f.reader.requestOccupancyReset()
        let got = dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: f.clientRequestFrames) }

        XCTAssertEqual(got, 0)
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToOutputRestartCount, 1)
        XCTAssertEqual(
            f.reader.metrics.reprimeDueToWriterStallCount, 0,
            "リセットは書き手停止起因の再プライミングとして計上しない"
        )
        XCTAssertEqual(f.reader.metrics.reprimeDueToTargetGrowthCount, 0)
    }

    // 無音の契機は AND (静けさの継続 × バッファ量の目標超過)。
    func testSilenceTriggeredResetRequiresBothTheSilenceHoldAndTheOccupancyDrift() {
        let f = makeResetFixture()
        var dst = [Float](repeating: -1, count: f.clientRequestFrames)
        func read() -> Int {
            dst.withUnsafeMutableBufferPointer { f.reader.read(into: $0.baseAddress!, frames: f.clientRequestFrames) }
        }

        // 出力段が無音のまま継続時間ぶん経過したことにする (以後、静けさの継続は読み出しでは減らない)。
        f.reader.observeOutputLevel(
            peak: 0, effectiveOutputGain: 1, frames: OccupancyPolicy.silenceHoldFrames(sampleRate: AudioConfig.appliedSampleRate)
        )

        // バッファ量が目標以下の回: 無音が続いていても発火しない。
        XCTAssertEqual(read(), f.clientRequestFrames, "ずれていない回は通常どおり消費する")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToSilenceCount, 0, "ずれていなければ捨てる仕事が無い")

        // 遊びの内側 (目標を超えるが書き手ブロック長ぶんは超えない) の回: 発火しない。
        let consumed = f.clientRequestFrames * 2
        setWriteCounter(f.url, UInt64(consumed + f.target + f.writerBlockFrames))
        XCTAssertEqual(read(), f.clientRequestFrames, "遊びの内側の超過では発火しない")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToSilenceCount, 0)

        // バッファ量が遊びを超えた回: 発火する (上限超過は要求しない)。
        let consumedAfterDrift = consumed + f.clientRequestFrames
        let driftedOccupancy = f.target + f.writerBlockFrames + 1
        XCTAssertLessThanOrEqual(driftedOccupancy, f.maxOccupancy, "前提: 上限超過を伴わないバッファ量であること")
        setWriteCounter(f.url, UInt64(consumedAfterDrift + driftedOccupancy))

        XCTAssertEqual(read(), 0, "無音とずれが揃った回は全捨てして無音を返す")
        XCTAssertEqual(f.reader.metrics.occupancyResetDueToSilenceCount, 1)
        XCTAssertEqual(f.reader.metrics.occupancyResetDiscardedFrameCountTotal, UInt64(driftedOccupancy))
        XCTAssertEqual(f.reader.metrics.resyncEventCount, 0, "上限超過の経路 (再同期) は通っていない")
        XCTAssertEqual(
            f.reader.metrics.reprimeDueToWriterStallCount, 0,
            "無音の契機も書き手停止起因の再プライミングとして計上しない"
        )
        XCTAssertEqual(f.reader.silentOutputFrameCount, 0, "発火した回に静けさの継続を数え直す")
    }

    // リセットは N_c (クライアントの実要求フレーム数) の観測窓を再出発させるが、N_p (書き手のブロック長) は据え置く。
    func testOccupancyResetRestartsTheClientRequestWindowWhileKeepingTheWriterBlockEstimate() {
        let writerBlockFrames = 128   // ブートストラップ値と異なる値を注入し、据え置きを観測できるようにする
        let baseRequestFrames = 64
        let burstRequestFrames = 512
        let targetAtBase = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: baseRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let targetAtBurst = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: burstRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        XCTAssertGreaterThan(targetAtBurst, targetAtBase, "前提: 要求量の違いが目標バッファ量の違いになること")

        // 目標バッファ量の導出だけを見るため、プライミング/上限超過の判定は無効化する (供給も要らない)。
        let url = makeFixture(ringFrames: 4096, writeCounter: 0)
        let reader = try! SharedRingReader.open(
            path: url.path, primingEnabled: false, initialWriterBlockFrames: writerBlockFrames
        ).get()

        var dst = [Float](repeating: -1, count: burstRequestFrames)
        func read(_ frames: Int) {
            _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: frames) }
        }

        read(baseRequestFrames)
        XCTAssertEqual(reader.metrics.targetOccupancyFrames, targetAtBase)

        // 窓内で大きい要求が 1 回来ると、目標バッファ量は窓の終わりまでその値へラチェットする。
        read(burstRequestFrames)
        XCTAssertEqual(reader.metrics.targetOccupancyFrames, targetAtBurst)

        reader.requestOccupancyReset()
        read(baseRequestFrames)
        XCTAssertEqual(
            reader.metrics.targetOccupancyFrames, targetAtBurst,
            "リセットの回そのものは、窓に残った観測から導出された目標バッファ量を使う"
        )

        read(baseRequestFrames)
        XCTAssertEqual(
            reader.metrics.targetOccupancyFrames, targetAtBase,
            "リセットが窓を再出発させるため、次の回は今の要求量から導出される"
        )
        XCTAssertEqual(
            reader.metrics.effectiveWriterBlockFrames, writerBlockFrames,
            "N_p の推定はリセットをまたいで据え置く"
        )
    }

    // MARK: - バーストバッファ量の許容 (再同期・トリミングいずれも非発動)

    func testReadKeepsBurstBacklogWithinMaxOccupancyWithoutTrimming() {
        // 上限バッファ量以下のバッファ量は正常であり、消費が始まった後は実音声を捨てない。
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = maxOccupancy
        // バッファ量を上限ちょうどに保ったまま包絡を飽和させ、その読み出し位置で「破棄していない」ことを見る。
        let saturationFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let ringValueCount = backlog + saturationFrames + clientRequestFrames
        let ringFrames: UInt32 = UInt32(ringValueCount * 2)
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(backlog),
            ringValues: (0..<ringValueCount).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        // 読み出しに合わせて同じだけ供給し、毎回のバッファ量を上限ちょうどに保つ。
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            if consumed > 0 { setWriteCounter(url, UInt64(backlog + consumed)) }
        }
        setWriteCounter(url, UInt64(backlog + saturationFrames))

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        // 消費が始まる前の切り詰めで、着地は目標バッファ量に揃う。
        let consumptionStart = backlog - target
        let verifiedStart = consumptionStart + saturationFrames
        XCTAssertEqual(got, clientRequestFrames)
        XCTAssertEqual(
            dst, (verifiedStart..<(verifiedStart + clientRequestFrames)).map { Float($0) },
            "バッファ量が上限以下なら、着地の位置から先は順に読める (破棄しない)"
        )
        XCTAssertEqual(reader.metrics.primingTrimEventCount, 1, "着地を目標へ揃える切り詰めは消費開始前の 1 回")
        XCTAssertEqual(reader.metrics.primingTrimDiscardedFrameCount, UInt64(consumptionStart))
        XCTAssertEqual(reader.metrics.resyncEventCount, 0)
        XCTAssertEqual(reader.metrics.driftTrimEventCount, 0)
        XCTAssertEqual(reader.metrics.occupancyResetDueToInitialSyncCount, 0)
        XCTAssertEqual(reader.metrics.occupancyResetDueToUnmixableSeamCount, 0)
        XCTAssertEqual(reader.metrics.occupancyResetDueToSilenceCount, 0, "出力段の水準を渡していない間は無音とみなさない")
    }

    // MARK: - プライミング (供給再開時のバッファ量確保)

    func testReadPrimesUntilTargetOccupancyBeforeConsumingAndRePrimesAfterDryUp() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate)
        // 包絡の飽和はプライミング完了後の実データ区間で回す。
        let saturationFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let phaseFrames = target + saturationFrames + clientRequestFrames
        let ringValueCount = phaseFrames * 2
        let ringFrames = UInt32(ringValueCount * 2)
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(target - 1),
            ringValues: (0..<ringValueCount).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        // クライアントの実要求フレーム数 (N_c) は毎回 clientRequestFrames で揃える (混ぜると目標バッファ量が動く)。
        var dst = [Float](repeating: -1, count: clientRequestFrames)

        var got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, 0)
        XCTAssertEqual(dst, [Float](repeating: 0, count: clientRequestFrames), "プライミング中は無音を返す")

        setWriteCounter(url, UInt64(target))
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(target + consumed + clientRequestFrames))
        }
        let firstPhaseVerifiedStart = clientRequestFrames + saturationFrames
        setWriteCounter(url, UInt64(firstPhaseVerifiedStart + clientRequestFrames))
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)
        XCTAssertEqual(
            dst, (firstPhaseVerifiedStart..<(firstPhaseVerifiedStart + clientRequestFrames)).map { Float($0) },
            "プライミング中に読み捨てず、先頭から順に消費する"
        )

        // 供給が途絶えて涸れたら (バッファ量 0)、次の供給再開でも再びプライミングする。
        let dryUpCursor = firstPhaseVerifiedStart + clientRequestFrames
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, 0, "涸れた時点でプライミング状態へ戻る")

        setWriteCounter(url, UInt64(dryUpCursor + clientRequestFrames))
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, 0, "再開後も target に達するまで消費しない")

        setWriteCounter(url, UInt64(dryUpCursor + target))
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(dryUpCursor + target + consumed + clientRequestFrames))
        }
        let secondPhaseVerifiedStart = dryUpCursor + clientRequestFrames + saturationFrames
        setWriteCounter(url, UInt64(secondPhaseVerifiedStart + clientRequestFrames))
        got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)
        XCTAssertEqual(
            dst, (secondPhaseVerifiedStart..<(secondPhaseVerifiedStart + clientRequestFrames)).map { Float($0) },
            "涸れる前の続きから消費を再開する"
        )
    }

    // MARK: - N_p (書き手のブロック長) の観測ステートマシン

    // 実際に read() を呼び、書き込みの増分列から確定値が窓の境界で確定し、窓が変われば追従して更新されることを検証する。
    func testWriterBlockFrameEstimateConfirmsAfterObservationWindowThenUpdatesOnChange() {
        let bootstrap = 512
        let firstBlockDelta = 128
        let secondBlockDelta = 64
        let observationWindowCalls = 64 // 実装側の観測窓と揃える
        let ringFrames: UInt32 = 16384
        let url = makeFixture(ringFrames: ringFrames, writeCounter: 0)
        let reader = try! SharedRingReader.open(
            path: url.path, primingEnabled: false, initialWriterBlockFrames: bootstrap
        ).get()

        var dst = [Float](repeating: -1, count: 8)
        var writeCounter: UInt64 = 0
        func advanceAndRead(by delta: Int) {
            writeCounter += UInt64(delta)
            setWriteCounter(url, writeCounter)
            _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 8) }
        }

        // 初回呼び出しは比較対象の直前値が無いため delta を観測できない (ベースライン記録のみ)。
        _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 8) }
        XCTAssertEqual(reader.metrics.effectiveWriterBlockFrames, bootstrap, "窓確定前はブートストラップ値のまま")

        // 残り (observationWindowCalls - 2) 回、一定の増分を与える (合計でまだ窓は満たさない)。
        for _ in 0..<(observationWindowCalls - 2) {
            advanceAndRead(by: firstBlockDelta)
            XCTAssertEqual(reader.metrics.effectiveWriterBlockFrames, bootstrap, "窓が満たされるまで確定値は変わらない")
        }
        // これでちょうど observationWindowCalls 回目の read() となり、窓が確定する。
        advanceAndRead(by: firstBlockDelta)
        XCTAssertEqual(reader.metrics.effectiveWriterBlockFrames, firstBlockDelta, "窓ぶんの一定増分が確定値として反映される")

        // 次の窓では異なる増分を与え、確定値が追従して更新されることを確認する (固定されない)。
        for _ in 0..<observationWindowCalls {
            advanceAndRead(by: secondBlockDelta)
        }
        XCTAssertEqual(reader.metrics.effectiveWriterBlockFrames, secondBlockDelta, "窓が変われば確定値も追従して更新される")
    }

    // MARK: - N_c (クライアントの実要求フレーム数) の観測窓

    // 窓内では大きい要求へ即座に追従し (ラチェット)、窓境界を跨ぐと過渡的な増加が薄まることを検証する。
    func testClientRequestFrameEstimateRatchetsWithinWindowThenDilutesAtObservationWindowBoundary() {
        let writerBlockFrames = 256
        let baseClientRequestFrames = 64
        let burstClientRequestFrames = 300
        let observationWindowCalls = 64 // 実装側の観測窓と揃える

        let targetAtBase = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: baseClientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let targetAtBurst = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: burstClientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = (targetAtBase + targetAtBurst) / 2
        XCTAssertGreaterThanOrEqual(backlog - baseClientRequestFrames, targetAtBase)
        XCTAssertLessThan(backlog - baseClientRequestFrames, targetAtBurst)

        let ringFrames: UInt32 = 4096
        let url = makeFixture(ringFrames: ringFrames, writeCounter: UInt64(backlog))
        let reader = try! SharedRingReader.open(
            path: url.path, initialWriterBlockFrames: writerBlockFrames
        ).get()

        var dst = [Float](repeating: -1, count: burstClientRequestFrames)
        func read(_ frames: Int) -> Int {
            dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: frames) }
        }

        XCTAssertEqual(read(baseClientRequestFrames), baseClientRequestFrames)
        XCTAssertEqual(reader.metrics.reprimeDueToTargetGrowthCount, 0)

        XCTAssertEqual(read(burstClientRequestFrames), 0, "窓内で拡大した目標バッファ量にバッファ量が届かず無音化する")
        XCTAssertEqual(reader.metrics.reprimeDueToTargetGrowthCount, 1, "拡大した目標バッファ量への追従が即座に起こる")

        for _ in 0..<(observationWindowCalls - 2) {
            XCTAssertEqual(read(baseClientRequestFrames), 0, "窓内はラチェットが維持され続ける")
        }
        XCTAssertEqual(reader.metrics.reprimeDueToTargetGrowthCount, 1, "窓内では新たな拡大は起きない")

        setWriteCounter(url, UInt64(backlog + writerBlockFrames))

        XCTAssertEqual(
            read(baseClientRequestFrames), baseClientRequestFrames,
            "窓境界を跨ぐと過渡的な拡大が薄まり消費が再開する"
        )
        XCTAssertEqual(reader.metrics.reprimeDueToTargetGrowthCount, 1, "目標バッファ量の縮小は再プライミングを起こさない")
    }

    // MARK: - カウンタ後退 (resync)

    func testReadResyncsWithoutErrorWhenWriteCounterRegresses() {
        let catchUpFrames = 256
        let regressedCounter = 50
        let saturationFrames = Self.saturationFrames(requestFrames: catchUpFrames)
        let ringValueCount = regressedCounter + saturationFrames + catchUpFrames
        let ringFrames = UInt32(ringValueCount * 2)
        let initialWriteCounter = 300
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(initialWriteCounter),
            ringValues: (0..<ringValueCount).map { Float($0) }
        )
        // カウンタ後退そのものの挙動だけを見るため、プライミング/上限超過の判定は無効化する。
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        var dst = [Float](repeating: -1, count: 200)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 200) }
        XCTAssertEqual(got, 200)

        // coreaudiod 再起動でドライバが再初期化され、writeCounter が 0 近くへ巻き戻ったことを模す。
        setWriteCounter(url, UInt64(regressedCounter))
        // フェード長ぶん読み切ってから末尾が完全な無音であることを見る。
        let fadeFrames = Self.envelopeSaturationFrames
        var afterReset = [Float](repeating: -1, count: fadeFrames + 10)
        let gotAfterReset = afterReset.withUnsafeMutableBufferPointer {
            reader.read(into: $0.baseAddress!, frames: fadeFrames + 10)
        }
        XCTAssertEqual(gotAfterReset, 0, "後退直後は新カウンタへ同期するだけでエラーにはならず、供給が無いため消費は 0")
        XCTAssertEqual(
            Array(afterReset[fadeFrames...]), [Float](repeating: 0, count: 10),
            "減衰がフェード長ぶんで完了し、以後は完全な無音で埋める"
        )

        setWriteCounter(url, UInt64(regressedCounter + saturationFrames))
        saturateEnvelope(reader, requestFrames: catchUpFrames)

        let catchUpStart = regressedCounter + saturationFrames
        setWriteCounter(url, UInt64(catchUpStart + catchUpFrames))
        var afterCatchUp = [Float](repeating: -1, count: catchUpFrames)
        let gotAfterCatchUp = afterCatchUp.withUnsafeMutableBufferPointer {
            reader.read(into: $0.baseAddress!, frames: catchUpFrames)
        }
        XCTAssertEqual(gotAfterCatchUp, catchUpFrames)
        XCTAssertEqual(
            afterCatchUp,
            (catchUpStart..<(catchUpStart + catchUpFrames)).map { Float($0) },
            "追従先の位置そのものが新カウンタ起点で連続していること"
        )
    }

    // MARK: - checkWriterStalled (書き手停止検知)

    // 稼働かつ経過超過のみが停止、非稼働は停止としない。

    func testCheckWriterStalledIsFalseWhenWriterIsNotRunningEvenWithLargeElapsedTime() {
        let url = makeFixture(ioCycleFrames: 256, writerIOIsRunning: 0, tsSeq: 0, tsHostTime: 0)
        let reader = try! SharedRingReader.open(path: url.path).get()
        XCTAssertFalse(reader.checkWriterStalled(now: UInt64.max), "非稼働中は経過時間に関わらず停止とみなさない (正常な無音)")
    }

    func testCheckWriterStalledIsFalseWhenElapsedIsWithinThreshold() {
        let url = makeFixture(ioCycleFrames: 256, writerIOIsRunning: 1, tsSeq: 0, tsHostTime: 1000)
        let reader = try! SharedRingReader.open(path: url.path).get()
        XCTAssertFalse(reader.checkWriterStalled(now: 1000), "直近の書き込みからの経過が閾値以下なら停止とみなさない")
    }

    func testCheckWriterStalledIsTrueWhenRunningAndElapsedExceedsThreshold() {
        let url = makeFixture(ioCycleFrames: 256, writerIOIsRunning: 1, tsSeq: 0, tsHostTime: 0)
        let reader = try! SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(reader.checkWriterStalled(now: UInt64.max), "稼働中かつ経過が閾値を超えていれば停止とみなす")
    }

    func testCheckWriterStalledCanRecoverAfterBeingStalled() {
        let url = makeFixture(ioCycleFrames: 256, writerIOIsRunning: 1, tsSeq: 0, tsHostTime: 0)
        let reader = try! SharedRingReader.open(path: url.path).get()
        XCTAssertTrue(reader.checkWriterStalled(now: UInt64.max), "前提: 経過が大きい間は停止と判定される")

        // 書き込みが再開し、時刻スナップショットが新しくなったことを模す (直近の呼び出しと同じ now)。
        setWriteCounter(url, 1) // ドライバの状況を変える意図の書き込みで、判定には使われない
        writeField(url, offset: Self.tsSeqOffset, value: UInt32(2))
        writeField(url, offset: Self.tsWriteCounterOffset, value: UInt64(1))
        writeField(url, offset: Self.tsHostTimeOffset, value: UInt64.max)
        XCTAssertFalse(reader.checkWriterStalled(now: UInt64.max), "書き込みが再開すれば復帰したとみなす")
    }

    // MARK: - 継ぎ目の包絡 (実データとゼロ埋めの継ぎ目)

    // 涸れの継ぎ目 (落ちる側): 直前の出力値から 0 へフェード長ぶんの傾きで下降する。
    func testEnvelopeFadesOutTowardSilenceWhenSupplyDriesUpAfterSteadyPlayback() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        // 無音との継ぎ目は落ちる側・戻る側とも同じ長さで動く。
        let fadeFrames = Self.envelopeSaturationFrames
        let constantValue: Float = 3
        let supplyFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        XCTAssertGreaterThan(supplyFrames, target, "前提: プライミングを終えたうえで飽和まで読み切れる供給量であること")

        let ringFrames = UInt32(supplyFrames * 2)
        let url = makeFixture(
            ringFrames: ringFrames, writeCounter: UInt64(target),
            ringValues: [Float](repeating: constantValue, count: supplyFrames)
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        // 供給ぶんを一度に要求しない (目標バッファ量が跳ね上がりプライミングが解けなくなる)。
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(min(target + consumed, supplyFrames)))
        }

        // 落ちる側のフェードは 1 回の呼び出しに収まらないため、複数回読んで連結する。
        let tailFrames = fadeFrames + clientRequestFrames
        var dst: [Float] = []
        var chunk = [Float](repeating: -1, count: clientRequestFrames)
        while dst.count < tailFrames {
            let got = chunk.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
            XCTAssertEqual(got, 0, "涸れているため無音を返す")
            dst.append(contentsOf: chunk)
        }

        XCTAssertEqual(dst[0], constantValue, accuracy: 1e-4, "直前の出力値から下降が始まる")
        for i in 1..<fadeFrames {
            XCTAssertLessThanOrEqual(dst[i], dst[i - 1] + 1e-4, "単調に下降すること (i=\(i))")
        }
        XCTAssertEqual(dst[fadeFrames], 0, accuracy: 1e-4, "フェード長ぶんで 0 に達すること")
        for i in fadeFrames..<tailFrames {
            XCTAssertEqual(dst[i], 0, "フェード長を過ぎたら完全な無音であること")
        }
    }

    // 復帰の継ぎ目 (戻る側): 先頭フレームは 0 から始まり、フェード長ぶんで原音に一致する。
    func testEnvelopeFadesInFromSilenceOnFirstRealDataAfterConnecting() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let fadeFrames = Self.envelopeSaturationFrames
        let constantValue: Float = 7
        // 立ち上がりは 1 回の呼び出しに収まらないため、複数回の読み出しにまたがって連結して見る。
        let supplyFrames = Self.saturationFrames(requestFrames: clientRequestFrames) + clientRequestFrames

        let ringFrames = UInt32(supplyFrames * 2)
        let url = makeFixture(
            ringFrames: ringFrames, writeCounter: UInt64(target),
            ringValues: [Float](repeating: constantValue, count: supplyFrames)
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        var rising: [Float] = []
        var chunk = [Float](repeating: -1, count: clientRequestFrames)
        while rising.count < fadeFrames + clientRequestFrames {
            setWriteCounter(url, UInt64(min(target + rising.count, supplyFrames)))
            let got = chunk.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
            XCTAssertEqual(got, clientRequestFrames, "前提: 立ち上がりの間は供給が続くこと")
            rising.append(contentsOf: chunk)
        }

        XCTAssertEqual(rising[0], 0, "先頭フレームは 0 から始まる")
        for i in 1..<fadeFrames {
            XCTAssertGreaterThanOrEqual(rising[i], rising[i - 1] - 1e-4, "単調に上昇すること (i=\(i))")
        }
        XCTAssertEqual(rising[fadeFrames], constantValue, accuracy: 1e-4, "フェード長で原音に一致すること")
        for i in fadeFrames..<rising.count {
            XCTAssertEqual(rising[i], constantValue, accuracy: 1e-4, "フェード長を過ぎたら原音のまま")
        }
    }

    // 歩幅そのもの: 戻る側・落ちる側とも同じ長さで動く。
    func testEnvelopeStepMatchesTheLowestBandPeriodInBothDirections() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let constantValue: Float = 1
        let expectedStep = constantValue / Float(Self.envelopeSaturationFrames)
        let supplyFrames = clientRequestFrames + Self.saturationFrames(requestFrames: clientRequestFrames)

        let url = makeFixture(
            ringFrames: UInt32(supplyFrames * 2), writeCounter: UInt64(target),
            ringValues: [Float](repeating: constantValue, count: supplyFrames)
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        // 戻る側: 接続後に最初に出す実データはゲイン 0 から 1 歩ずつ上がる。
        var rising = [Float](repeating: -1, count: clientRequestFrames)
        let risingGot = rising.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(risingGot, clientRequestFrames)
        XCTAssertEqual(rising[0], 0, "先頭フレームはゲイン 0")
        XCTAssertEqual(rising[1] - rising[0], expectedStep, accuracy: 1e-6, "歩幅は最低バンドの 1 周期に由来する")
        XCTAssertEqual(rising[2] - rising[1], expectedStep, accuracy: 1e-6, "歩幅は一定")

        // 落ちる側: 飽和させてから涸れさせると、同じ歩幅で下降する。
        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(min(target + clientRequestFrames + consumed, supplyFrames)))
        }
        var falling = [Float](repeating: -1, count: clientRequestFrames)
        let fallingGot = falling.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(fallingGot, 0, "前提: 涸れていること")
        XCTAssertEqual(falling[0], constantValue, accuracy: 1e-6, "直前の出力値から下降が始まる")
        XCTAssertEqual(
            falling[0] - falling[1], rising[1] - rising[0], accuracy: 1e-6,
            "落ちる側と戻る側は同じ歩幅 (同じ長さで動く)"
        )
    }

    // 定常再生: 包絡が飽和した (ゲイン 1) 状態が続く間、出力はリングの値と厳密に一致する。
    func testEnvelopeDoesNotAlterOutputOnceSaturatedDuringSteadyPlayback() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let maxOccupancy = OccupancyPolicy.maxOccupancyFrames(
            targetOccupancyFrames: target, writerBlockFrames: writerBlockFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let backlog = maxOccupancy
        let saturationFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let ringValueCount = backlog + saturationFrames + clientRequestFrames
        let ringFrames = UInt32(ringValueCount * 2)
        let url = makeFixture(ringFrames: ringFrames, writeCounter: UInt64(backlog), ringValues: (0..<ringValueCount).map { Float($0) })
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            if consumed > 0 { setWriteCounter(url, UInt64(backlog + consumed)) }
        }
        setWriteCounter(url, UInt64(backlog + saturationFrames))

        let verifiedStart = (backlog - target) + saturationFrames
        var dst = [Float](repeating: -1, count: clientRequestFrames)
        let got = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertEqual(got, clientRequestFrames)
        XCTAssertEqual(dst, (verifiedStart..<(verifiedStart + clientRequestFrames)).map { Float($0) })
    }

    // 交錯: 下降の途中で供給が戻った場合、転換点を跨いでも隣接フレーム差が歩幅を超えない。
    func testEnvelopeReversesWithoutJumpingWhenSupplyReturnsMidDecay() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let constantValue: Float = 5
        let target = OccupancyPolicy.targetOccupancyFrames(
            writerBlockFrames: writerBlockFrames, clientRequestFrames: clientRequestFrames, sampleRate: AudioConfig.appliedSampleRate
        )
        let fadeFrames = Self.envelopeSaturationFrames
        let remainderAfterWarmup = 5
        let decayFrames = 10
        let resumeRequestFrames = 20
        XCTAssertLessThan(decayFrames, fadeFrames, "前提: 供給がフェード長に達する前に戻ること")

        let saturationFrames = Self.saturationFrames(requestFrames: clientRequestFrames)
        let warmupSupply = saturationFrames + remainderAfterWarmup
        let totalRingValues = warmupSupply + resumeRequestFrames
        let ringFrames = UInt32(totalRingValues * 2)
        let url = makeFixture(
            ringFrames: ringFrames, writeCounter: UInt64(target),
            ringValues: [Float](repeating: constantValue, count: totalRingValues)
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        saturateEnvelope(reader, requestFrames: clientRequestFrames) { consumed in
            setWriteCounter(url, UInt64(min(target + consumed, warmupSupply)))
        }

        // 残りぶんは実データ、続く decayFrames ぶんはゼロ埋めの尾 (下降の途中)。
        let secondRequest = remainderAfterWarmup + decayFrames
        var mid = [Float](repeating: -1, count: secondRequest)
        let midGot = mid.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: secondRequest) }
        XCTAssertEqual(midGot, remainderAfterWarmup, "供給ぶんだけ配信し、残りは無音で埋める")

        // 供給が戻る (下降がフェード長に達する前)。全量実データで返るぶんを供給する。
        setWriteCounter(url, UInt64(totalRingValues))
        var resumed = [Float](repeating: -1, count: resumeRequestFrames)
        let resumedGot = resumed.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: resumeRequestFrames) }
        XCTAssertEqual(resumedGot, resumeRequestFrames)

        let combined = Array(mid[remainderAfterWarmup...]) + resumed
        let stepBound = constantValue / Float(fadeFrames) + 1e-4
        for i in 1..<combined.count {
            XCTAssertLessThanOrEqual(abs(combined[i] - combined[i - 1]), stepBound, "隣接フレーム差が歩幅を超えないこと (i=\(i))")
        }
    }

    // MARK: - 観測転記 (実効ブロック長・目標/上限バッファ量・リング容量は変化時のみ書く)

    func testAdoptForwardsCurrentStateValuesToNewMetricsOnNextReadEvenWhenUnchanged() {
        let writerBlockFrames = 256
        let clientRequestFrames = 256
        let ringFrames: UInt32 = 8192
        let url = makeFixture(
            ringFrames: ringFrames,
            writeCounter: UInt64(writerBlockFrames * 8),
            ringValues: (0..<(writerBlockFrames * 8)).map { Float($0) }
        )
        let reader = try! SharedRingReader.open(path: url.path, initialWriterBlockFrames: writerBlockFrames).get()

        var dst = [Float](repeating: -1, count: clientRequestFrames)
        _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }

        let newMetrics = AudioRuntimeMetrics()
        reader.adopt(metrics: newMetrics)
        XCTAssertEqual(newMetrics.ringCapacityFrames, Int(ringFrames), "リング容量は adopt 時点で1回だけ記録される")
        XCTAssertEqual(newMetrics.effectiveWriterBlockFrames, 0, "adopt 直後、次の read を経る前はまだ書かれていない")
        XCTAssertEqual(newMetrics.targetOccupancyFrames, 0, "同上")

        _ = dst.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: clientRequestFrames) }
        XCTAssertGreaterThan(newMetrics.effectiveWriterBlockFrames, 0, "adopt 後の次回 read で新 metrics へ実効ブロック長が届くこと")
        XCTAssertGreaterThan(newMetrics.targetOccupancyFrames, 0, "adopt 後の次回 read で新 metrics へ目標バッファ量が届くこと")
        XCTAssertGreaterThan(newMetrics.maxOccupancyFrames, 0, "adopt 後の次回 read で新 metrics へ上限バッファ量が届くこと")
    }

    // MARK: - ドライバの書き込み位置決定の観測量 (共有ヘッダ→shim→読み手→metrics の転記)

    // フィクスチャへ相異なる既知の値を書き、それぞれ対応する値として metrics に現れることを見る。
    func testDriverWritePositionObservationsAreForwardedFromHeaderToMetrics() {
        let url = makeFixture(
            ioCycleFrames: 940,
            epoch: 3,
            writerIOIsRunning: 1,
            presentationStallCount: 11,
            presentationDeltaUnexpectedCount: 33,
            writeDeadlineMissedCount: 44,
            silenceFilledGapCount: 55
        )
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        reader.refreshDriverObservations()

        XCTAssertEqual(reader.metrics.presentationStallCount, 11)
        XCTAssertEqual(reader.metrics.presentationDeltaUnexpectedCount, 33)
        XCTAssertEqual(reader.metrics.writeDeadlineMissedCount, 44)
        XCTAssertEqual(reader.metrics.silenceFilledGapCount, 55)
        XCTAssertEqual(reader.metrics.writerEpoch, 3)
        XCTAssertTrue(reader.metrics.writerIOIsRunning)
        XCTAssertEqual(reader.metrics.writerIOCycleFrames, 940)
    }

    // 稼働の申告は真偽として転記される (0 は停止)。
    func testWriterIOIsRunningIsForwardedAsFalseWhenHeaderSaysStopped() {
        let url = makeFixture(writerIOIsRunning: 0)
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        reader.refreshDriverObservations()

        XCTAssertFalse(reader.metrics.writerIOIsRunning)
    }

    // 転記は「写し取り」であり加算ではない。同じ値を重ねて読ませても増えない。
    func testDriverWritePositionObservationsAreOverwrittenNotAccumulatedAcrossReads() {
        let url = makeFixture(presentationStallCount: 5, writeDeadlineMissedCount: 7)
        let reader = try! SharedRingReader.open(path: url.path, primingEnabled: false).get()

        reader.refreshDriverObservations()
        reader.refreshDriverObservations()
        reader.refreshDriverObservations()

        XCTAssertEqual(reader.metrics.presentationStallCount, 5, "同じ値を繰り返し読んでも積み上がらない")
        XCTAssertEqual(reader.metrics.writeDeadlineMissedCount, 7, "同じ値を繰り返し読んでも積み上がらない")
    }
}
