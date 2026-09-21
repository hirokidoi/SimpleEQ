import Foundation

/// システムスリープ中に進まない時計 (秒)。
/// 壁時計だと、スリープを挟んだ経過が実際に待った時間とかけ離れる。
func uptimeSeconds() -> TimeInterval {
    TimeInterval(DispatchTime.now().uptimeNanoseconds) / TimeInterval(NSEC_PER_SEC)
}
