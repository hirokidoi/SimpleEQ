import Foundation
import SimpleEQAtomicC

/// SPSC (単一生産者/単一消費者) ロックフリー リングバッファ。インターリーブ Float32。
/// acquire/release を統一的に使う (relaxed への最適化より正当性の単純さを優先する)。
final class RingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    let channels: Int
    private let data: UnsafeMutablePointer<Float>
    private let writeFrameStorage: UnsafeMutableRawPointer
    private let readFrameStorage: UnsafeMutableRawPointer

    private var writeFrame: Int {
        get { Int(simpleeq_atomic_load_acquire(writeFrameStorage)) }
        set { simpleeq_atomic_store_release(writeFrameStorage, UInt64(newValue)) }
    }
    private var readFrame: Int {
        get { Int(simpleeq_atomic_load_acquire(readFrameStorage)) }
        set { simpleeq_atomic_store_release(readFrameStorage, UInt64(newValue)) }
    }

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        data = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
        data.initialize(repeating: 0, count: capacityFrames * channels)

        let size = simpleeq_atomic_storage_size()
        let alignment = simpleeq_atomic_storage_alignment()
        writeFrameStorage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment)
        readFrameStorage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment)
        simpleeq_atomic_init(writeFrameStorage, 0)
        simpleeq_atomic_init(readFrameStorage, 0)
    }

    deinit {
        data.deallocate()
        writeFrameStorage.deallocate()
        readFrameStorage.deallocate()
    }

    var availableRead: Int {
        (writeFrame - readFrame + capacityFrames) % capacityFrames
    }
    var availableWrite: Int { capacityFrames - 1 - availableRead }

    func write(_ src: UnsafePointer<Float>, frames: Int) {
        let n = min(frames, availableWrite)
        var w = writeFrame
        for f in 0..<n {
            let base = w * channels
            let sbase = f * channels
            for c in 0..<channels { data[base + c] = src[sbase + c] }
            w = (w + 1) % capacityFrames
        }
        writeFrame = w
    }

    /// 不足分は無音で埋める。実読み出しフレーム数を返す。
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let n = min(frames, availableRead)
        var r = readFrame
        for f in 0..<n {
            let dbase = f * channels
            let base = r * channels
            for c in 0..<channels { dst[dbase + c] = data[base + c] }
            r = (r + 1) % capacityFrames
        }
        readFrame = r
        if n < frames {
            for f in n..<frames {
                let dbase = f * channels
                for c in 0..<channels { dst[dbase + c] = 0 }
            }
        }
        return n
    }
}
