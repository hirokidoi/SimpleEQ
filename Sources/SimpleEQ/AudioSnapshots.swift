/// 稼働中に採用されている出力先の解決情報 (デバイス + 表示名)。表示名の解決はオーディオ世界の
/// キュー上でしか行えないため、UI 世界側で改めて解決し直さずに済むようこの通知に同梱する。
struct ActiveOutputDeviceInfo: Equatable {
    let device: ResolvedOutputDevice
    /// CoreAudio から名前が取得できなかった場合のみ nil。
    let name: String?
}
