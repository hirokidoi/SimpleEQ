import Foundation

/// ドライバのクライアント表の 1 席。
struct MixerRosterEntry: Equatable, Sendable {
    let clientID: UInt32
    let processID: UInt32
    /// 空文字はドライバへ NULL で届いた場合と、上限に収まらなかった場合。
    let bundleID: String
    let active: Bool
}

/// 共有ヘッダから読む、ドライバ側の事実。
struct MixerDriverObservation: Equatable, Sendable {
    var slotsInUse = 0
    var slotCount = 0
    /// nil はリースを持っていない状態。
    var leaseRemainingSeconds: Double?
    var slotOverflowCount: UInt64 = 0
    var neutralizedCount: UInt64 = 0
    var gainEntryDroppedCount: UInt64 = 0
}

/// 調停役が 1 パスごとに記録する、アプリ側の事実。
struct MixerCoordinationObservation: Equatable, Sendable {
    var channelCount = 0
    var nonNeutralChannelCount = 0
    var resolvedByPrivateAPICount = 0
    var resolvedByParentCount = 0
    var resolvedAsProcessCount = 0
    var unresolvedCount = 0
    /// 非公開 API のシンボルを引けたか。壊れ方が静かなため、そのものを診断へ出す。
    var privateAPIAvailable = false
}
