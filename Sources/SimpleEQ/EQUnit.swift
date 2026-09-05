import AudioToolbox
import CoreAudio

struct EQStreamFormat {
    let channels: UInt32
    let sampleRate: Double
}

/// AUNBandEQ (Apple の N バンド EQ AudioUnit) を直列チェーンしてグラフィック EQ を実現する。
/// 1 ユニットのバンド数は kAUNBandEQProperty_MaxNumberOfBands が上限のため、超える構成はユニットを分割して直列につなぐ
/// (パラメトリックピーキングは直列でも各帯域が独立に効くため、単一 EQ と等価な合成応答が得られる)。
final class EQUnit {
    /// units[0] が入力 (ring) 側から pull され、units[last] が render 対象。
    private var units: [AudioUnit] = []
    let bandCount: Int

    /// 各ユニットが担当するバンド数 (チェーン順)。合計は bandCount。
    private let unitBandCounts: [Int]
    /// グローバルバンド index → 所属ユニットの先頭グローバル index (prefix sum)。
    private let bandOffsets: [Int]

    init?() {
        bandCount = EQSpec.bandCount
        // OS/機種で上限が変わりうるため定数化せず実測値から導出する。
        guard let maxPerUnit = EQUnit.queryMaxBands(), maxPerUnit > 0 else { return nil }
        let counts = EQUnit.distributeBands(total: bandCount, maxPerUnit: Int(maxPerUnit))
        guard !counts.isEmpty else { return nil }
        unitBandCounts = counts
        bandOffsets = EQUnit.bandOffsets(forCounts: counts)
    }

    func setup(
        format: EQStreamFormat, maxFrames: UInt32,
        renderCallback: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer
    ) -> Bool {
        for _ in unitBandCounts {
            guard let u = EQUnit.makeUnit() else { print("[ERROR] EQUnit create"); return false }
            units.append(u)
        }

        for (idx, u) in units.enumerated() {
            var n = UInt32(unitBandCounts[idx])
            let st = AudioUnitSetProperty(
                u, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0,
                &n, UInt32(MemoryLayout<UInt32>.size)
            )
            guard st == noErr else { print("[ERROR] EQUnit set band count[\(idx)]=\(n): \(st)"); return false }
        }

        guard setStreamFormats(format) else {
            print("[ERROR] EQUnit stream format rejected (non-interleaved)")
            return false
        }

        for u in units {
            var frames = maxFrames
            AudioUnitSetProperty(
                u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &frames, UInt32(MemoryLayout<UInt32>.size)
            )
        }

        var cb = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: refCon)
        var st = AudioUnitSetProperty(
            units[0], kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard st == noErr else { print("[ERROR] EQUnit set render callback: \(st)"); return false }

        // units[k-1].output(0) → units[k].input(0)
        for k in 1..<units.count {
            var conn = AudioUnitConnection(
                sourceAudioUnit: units[k - 1], sourceOutputNumber: 0, destInputNumber: 0
            )
            st = AudioUnitSetProperty(
                units[k], kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0,
                &conn, UInt32(MemoryLayout<AudioUnitConnection>.size)
            )
            guard st == noErr else { print("[ERROR] EQUnit connect \(k - 1)->\(k): \(st)"); return false }
        }

        // source → sink 順 (接続先が source のフォーマットを解決できるようにする)。
        for (idx, u) in units.enumerated() {
            st = AudioUnitInitialize(u)
            guard st == noErr else { print("[ERROR] EQUnit initialize[\(idx)]: \(st)"); return false }
        }

        // AUNBandEQ の各バンドは既定でバイパスのため、有効化しないとゲインが反映されない。
        // 帯域幅 (Q) は製品要件に指定が無いため AU 既定値のまま変更しない。
        for band in 0..<bandCount {
            let (unitIndex, local) = unitAndLocal(band)
            let bypassBandParam = kAUNBandEQParam_BypassBand + AudioUnitParameterID(local)
            let filterTypeParam = kAUNBandEQParam_FilterType + AudioUnitParameterID(local)
            let freqParam = kAUNBandEQParam_Frequency + AudioUnitParameterID(local)
            AudioUnitSetParameter(
                units[unitIndex], bypassBandParam, kAudioUnitScope_Global, 0,
                0, 0   // 0 = バンド有効 (1 = バイパス)
            )
            AudioUnitSetParameter(
                units[unitIndex], filterTypeParam, kAudioUnitScope_Global, 0,
                AudioUnitParameterValue(kAUNBandEQFilterType_Parametric), 0
            )
            AudioUnitSetParameter(
                units[unitIndex], freqParam, kAudioUnitScope_Global, 0,
                AudioUnitParameterValue(EQSpec.FREQS[band]), 0
            )
        }

        return true
    }

    /// 全ユニットの input/output scope へストリームフォーマットを設定する。1 つでも拒否されたら false。
    private func setStreamFormats(_ format: EQStreamFormat) -> Bool {
        var asbd = AudioConfig.makePlanarASBD(channels: format.channels, sampleRate: format.sampleRate)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for u in units {
            let stIn = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, size)
            let stOut = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, size)
            if stIn != noErr || stOut != noErr { return false }
        }
        return true
    }

    private func unitAndLocal(_ band: Int) -> (unit: Int, local: Int) {
        EQUnit.unitAndLocal(band: band, offsets: bandOffsets)
    }

    /// AudioUnitSetParameter によるゲイン変更は AU 内部でスムージング/ランプされるため、
    /// 呼び出し側で独自の補間を行う必要はない (ドラッグ中も逐次呼び出してよい)。
    func setGain(band: Int, db: Double) {
        guard band >= 0 && band < bandCount, !units.isEmpty else { return }
        let (unitIndex, local) = unitAndLocal(band)
        let gainParam = kAUNBandEQParam_Gain + AudioUnitParameterID(local)
        AudioUnitSetParameter(
            units[unitIndex], gainParam, kAudioUnitScope_Global, 0,
            AudioUnitParameterValue(EQSpec.clampDb(db)), 0
        )
    }

    func reset() {
        for u in units { AudioUnitReset(u, kAudioUnitScope_Global, 0) }
    }

    func setAllGains(_ dbs: [Double]) {
        for i in 0..<min(bandCount, dbs.count) { setGain(band: i, db: dbs[i]) }
    }

    /// チェーン内の全ユニットへ一括適用する (realtime のレンダ経路自体は分岐させない)。
    func setBypass(_ bypass: Bool) {
        var v: UInt32 = bypass ? 1 : 0
        for u in units {
            AudioUnitSetProperty(
                u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0,
                &v, UInt32(MemoryLayout<UInt32>.size)
            )
        }
    }

    /// 最終ユニットへ render を依頼すると、チェーン接続をたどって先頭ユニットの input render callback まで自動で pull される。
    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let last = units.last else { return kAudioUnitErr_Uninitialized }
        return AudioUnitRender(last, flags, timestamp, 0, frames, ioData)
    }

    func dispose() {
        for u in units {
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        units.removeAll()
    }

    // MARK: - ユニット生成・上限問い合わせ・バンド分割

    private static func makeUnit() -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_NBandEQ,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(comp, &newUnit) == noErr, let u = newUnit else { return nil }
        return u
    }

    private static func queryMaxBands() -> UInt32? {
        guard let u = makeUnit() else { return nil }
        defer { AudioComponentInstanceDispose(u) }
        var maxBands: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioUnitGetProperty(u, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &maxBands, &sz)
        guard st == noErr, maxBands > 0 else { return nil }
        return maxBands
    }

    static func distributeBands(total: Int, maxPerUnit: Int) -> [Int] {
        guard total > 0, maxPerUnit > 0 else { return [] }
        let numUnits = (total + maxPerUnit - 1) / maxPerUnit
        let base = total / numUnits
        let rem = total % numUnits
        return (0..<numUnits).map { base + ($0 < rem ? 1 : 0) }
    }

    static func bandOffsets(forCounts counts: [Int]) -> [Int] {
        var offsets: [Int] = []
        var acc = 0
        for c in counts { offsets.append(acc); acc += c }
        return offsets
    }

    static func unitAndLocal(band: Int, offsets: [Int]) -> (unit: Int, local: Int) {
        var u = offsets.count - 1
        while u > 0 && band < offsets[u] { u -= 1 }
        return (u, band - offsets[u])
    }
}
