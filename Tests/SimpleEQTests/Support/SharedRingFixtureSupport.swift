import Foundation
import SimpleEQRingC
@testable import SimpleEQ

/// 所有権のフィールドは構造体末尾にあり、前段が増えるたびに動くためシムに位置を訊く。
let ownershipOwnerProcessIDOffset = Int(simpleeq_ownership_owner_process_id_offset())
let ownershipLeaseDeadlineOffset = Int(simpleeq_ownership_lease_deadline_host_time_offset())
let ownershipRequestProcessIDOffset = Int(simpleeq_ownership_request_process_id_offset())
let ownershipRequestLeaseDeadlineOffset = Int(simpleeq_ownership_request_lease_deadline_host_time_offset())

/// 所有権だけを載せた最小のヘッダファイルを作る。呼び出し元が削除すること。
/// リングの中身は持たない (所有権の判定はリングを読まない)。
func makeOwnershipHeaderFixture(
    ownerProcessID: UInt32, leaseRemainingSeconds: Double,
    requestProcessID: UInt32 = 0, requestLeaseRemainingSeconds: Double = 0
) -> URL {
    let size = Int(simpleeq_ring_header_size())
    let ringFrames: UInt32 = 64
    let channels: UInt32 = 1
    var data = Data(count: size + Int(ringFrames) * Int(channels) * MemoryLayout<Float>.size)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        raw.storeBytes(of: simpleeq_ring_expected_magic(), toByteOffset: 0, as: UInt32.self)
        raw.storeBytes(of: simpleeq_ring_expected_layout_version(), toByteOffset: 4, as: UInt32.self)
        raw.storeBytes(of: UInt32(size), toByteOffset: 12, as: UInt32.self)
        raw.storeBytes(of: ringFrames, toByteOffset: 16, as: UInt32.self)
        raw.storeBytes(of: channels, toByteOffset: 20, as: UInt32.self)
        raw.storeBytes(of: AudioConfig.baseSampleRate, toByteOffset: 24, as: Double.self)
        raw.storeBytes(of: ownerProcessID, toByteOffset: ownershipOwnerProcessIDOffset, as: UInt32.self)
        raw.storeBytes(
            of: leaseDeadlineHostTime(afterSeconds: leaseRemainingSeconds),
            toByteOffset: ownershipLeaseDeadlineOffset, as: UInt64.self
        )
        raw.storeBytes(of: requestProcessID, toByteOffset: ownershipRequestProcessIDOffset, as: UInt32.self)
        raw.storeBytes(
            of: leaseDeadlineHostTime(afterSeconds: requestLeaseRemainingSeconds),
            toByteOffset: ownershipRequestLeaseDeadlineOffset, as: UInt64.self
        )
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimpleEQOwnershipFixture-\(UUID().uuidString).bin")
    try! data.write(to: url)
    return url
}

/// 0 は「リースを持っていない」を表す取り決めの値なので、満了した席は負の残量として渡して作る。
private func leaseDeadlineHostTime(afterSeconds seconds: Double) -> UInt64 {
    guard seconds != 0 else { return 0 }
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let ticksPerSecond = Double(info.denom) / Double(info.numer) * 1_000_000_000
    let ticks = UInt64(abs(seconds) * ticksPerSecond)
    let now = mach_absolute_time()
    return seconds > 0 ? now + ticks : now - min(ticks, now)
}
