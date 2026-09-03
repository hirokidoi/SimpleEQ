import Dispatch
import Foundation

/// 調停役が UI 世界から受け取るチャンネルの写し。
struct MixerChannelSnapshot: Equatable, Sendable {
    let key: String
    /// ミュートを織り込んだ実効ゲイン (0…1)。
    let gain: Double
}

/// 調停役が UI 世界へ押し出す結果 (低頻度)。
struct MixerCoordinatorUpdate: Sendable {
    /// 候補プールの母集合 (セッション中に一度でも音を出したもの)。
    let identities: [String: MixerAppIdentity]
    /// メーターが読む、チャンネルキーごとのクライアント識別値。
    let clientIDsByChannelKey: [String: [UInt32]]
}

/// 押し込みの要否とゲイン表の組み立て。CoreAudio に触れない純粋関数。
enum MixerPushPolicy {
    /// 中立の要素は表に載せない。載せないことで「中立の間は押し込みが起きない」が
    /// 表の同値判定だけで決まる。
    /// 同じ鍵を 2 つ以上のアプリが持つときはどのゲインとも言えないため、その鍵は載せない
    /// (行にしていないアプリも数える)。
    static func gainTable(
        matchKeysByChannelKey: [String: Set<String>],
        gainByChannelKey: [String: Double]
    ) -> [String: Double] {
        var ownerCount: [String: Int] = [:]
        for matchKeys in matchKeysByChannelKey.values {
            for matchKey in matchKeys { ownerCount[matchKey, default: 0] += 1 }
        }
        var table: [String: Double] = [:]
        for (channelKey, matchKeys) in matchKeysByChannelKey {
            guard let gain = gainByChannelKey[channelKey], gain != MixerGainScale.unityGain else { continue }
            let clamped = min(MixerGainScale.unityGain, max(0, gain))
            for matchKey in matchKeys where ownerCount[matchKey] == 1 { table[matchKey] = clamped }
        }
        return table
    }

    /// 行の名前空間に属するバンドル ID から作った鍵だけを覚える。アプリを起動し直しても同じ鍵に
    /// なるため、席を取った瞬間からゲインが当たる。
    /// 共有フレームワーク (複数のアプリが同じバンドル ID の子プロセスから音を出す) の鍵は覚えない。
    /// 覚えると、そのアプリを終了したあとも別のアプリに当たり続ける。
    /// pid から作った鍵も覚えない (起動のたびに変わる)。
    static func matchKeys(
        remembered: [String: Set<String>],
        roster: [MixerRosterEntry],
        channelKeyForProcess: (UInt32) -> String?
    ) -> (table: [String: Set<String>], remembered: [String: Set<String>]) {
        var table = remembered
        var toRemember = remembered
        for entry in roster {
            guard let channelKey = channelKeyForProcess(entry.processID),
                  let matchKey = MixerSpec.matchKey(bundleID: entry.bundleID, processID: entry.processID)
            else { continue }
            table[channelKey, default: []].insert(matchKey)
            if isOwned(bundleID: entry.bundleID, byChannelKey: channelKey) {
                toRemember[channelKey, default: []].insert(matchKey)
            }
        }
        return (table, toRemember)
    }

    /// 行のバンドル ID そのものか、その下に連なる名前か。
    static func isOwned(bundleID: String, byChannelKey channelKey: String) -> Bool {
        guard !bundleID.isEmpty, let owner = MixerSpec.bundleID(inKey: channelKey) else { return false }
        return bundleID == owner || bundleID.hasPrefix(owner + ".")
    }

    static func shouldPush(
        table: [String: Double], lastPushed: [String: Double]?,
        lastPushAt: TimeInterval?, now: TimeInterval, renewInterval: TimeInterval
    ) -> Bool {
        guard let lastPushed else { return !table.isEmpty }
        if table != lastPushed { return true }
        guard !table.isEmpty, let lastPushAt else { return false }
        return now - lastPushAt >= renewInterval
    }
}

/// ミキサーの調停役。名簿の追従・アプリの特定・ゲイン表の押し込みを、自前の直列キュー 1 本で回す。
/// 面の出し入れに関係なく生きる (ゲインは面が出ていなくても効いていなければならない)。
final class MixerCoordinator: @unchecked Sendable {

    /// 周期も更新間隔もリース長から導く (両者が一致していなければならない値のため)。
    static var passInterval: TimeInterval { DriverConfig.mixerControlLeaseSeconds / 3 }

    var didUpdate: (@Sendable (MixerCoordinatorUpdate) -> Void)?

    private let queue: DispatchQueue
    private let audioWorld: AudioWorld
    private let bridge: MixerAudioBridge
    private let levelStore: MixerLevelStore
    private let resolver: MixerAppResolver
    private let selfChannelKey: String?
    private let now: @Sendable () -> TimeInterval

    // 以下はすべて queue 上だけが読み書きする。
    private var channels: [MixerChannelSnapshot] = []
    private var roster: [MixerRosterEntry] = []
    private var resolutions: [pid_t: MixerAppResolution] = [:]
    private var identities: [String: MixerAppIdentity] = [:]
    /// チャンネルが持つ突き合わせキー。行を消すまで覚えておく。
    private var matchKeysByChannelKey: [String: Set<String>] = [:]
    private var lastRosterRevision: UInt64?
    private var lastPushedTable: [String: Double]?
    private var lastPushAt: TimeInterval?
    private var lastObservation: MixerCoordinationObservation?

    init(
        audioWorld: AudioWorld,
        bridge: MixerAudioBridge,
        levelStore: MixerLevelStore,
        resolver: MixerAppResolver = MixerAppResolver(environment: .live()),
        selfChannelKey: String? = Bundle.main.bundleIdentifier.map(MixerSpec.bundleKey),
        queue: DispatchQueue = DispatchQueue(label: "com.simpleeq.mixer", qos: .utility),
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.audioWorld = audioWorld
        self.bridge = bridge
        self.levelStore = levelStore
        self.resolver = resolver
        self.selfChannelKey = selfChannelKey
        self.queue = queue
        self.now = now
    }

    func runPass() {
        queue.async { [self] in
            let revision = levelStore.rosterRevision
            guard lastRosterRevision != revision else { return reconcile() }
            lastRosterRevision = revision
            requestRoster()
        }
    }

    func updateChannels(_ channels: [MixerChannelSnapshot]) {
        queue.async { [self] in
            self.channels = channels
            reconcile()
        }
    }

    private func requestRoster() {
        audioWorld.submit(coalescingKey: AudioRequestKey.mixerRoster) { [weak self] token in
            guard let self else { return }
            let roster = bridge.readMixerRoster(token)
            queue.async { [self] in
                self.roster = roster
                resolveNewProcesses()
                reconcile()
            }
        }
    }

    /// 候補プールに入るのは活動中だったスロットのうち特定できたものだけで、セッションの間は消さない。
    private func resolveNewProcesses() {
        for entry in roster {
            let pid = pid_t(bitPattern: entry.processID)
            let resolution = resolutions[pid] ?? resolver.resolve(pid: pid)
            resolutions[pid] = resolution
            guard entry.active, let key = channelKey(forProcess: entry.processID),
                  let identity = resolution.identity else { continue }
            identities[key] = identity
        }
    }

    /// 自分自身は行にしない。SimpleEQ が出す音は全アプリの音そのもので、他の行と並べても
    /// 意味を持たない。
    private func channelKey(forProcess processID: UInt32) -> String? {
        guard let key = resolutions[pid_t(bitPattern: processID)]?.channelKey,
              key != selfChannelKey else { return nil }
        return key
    }

    private func reconcile() {
        var gainByChannelKey: [String: Double] = [:]
        for channel in channels { gainByChannelKey[channel.key] = channel.gain }

        let keys = MixerPushPolicy.matchKeys(
            remembered: matchKeysByChannelKey,
            roster: roster,
            channelKeyForProcess: { [self] in channelKey(forProcess: $0) }
        )
        // 行が消えたら、その行が抱えていた鍵も忘れる。
        matchKeysByChannelKey = keys.remembered.filter { gainByChannelKey[$0.key] != nil }

        let table = MixerPushPolicy.gainTable(
            matchKeysByChannelKey: keys.table,
            gainByChannelKey: gainByChannelKey
        )
        let currentTime = now()
        let pushes = MixerPushPolicy.shouldPush(
            table: table, lastPushed: lastPushedTable, lastPushAt: lastPushAt,
            now: currentTime, renewInterval: Self.passInterval
        )
        let observation = makeObservation(gainByChannelKey: gainByChannelKey)

        if pushes || observation != lastObservation {
            lastObservation = observation
            audioWorld.submit(coalescingKey: AudioRequestKey.mixerGainTable) { [bridge] token in
                bridge.recordMixerCoordination(observation)
                guard pushes else { return }
                bridge.writeMixerGainTable(table, token)
            }
        }
        if pushes {
            lastPushedTable = table
            lastPushAt = currentTime
        }

        publish()
    }

    private func makeObservation(gainByChannelKey: [String: Double]) -> MixerCoordinationObservation {
        var observation = MixerCoordinationObservation()
        observation.channelCount = channels.count
        observation.nonNeutralChannelCount = gainByChannelKey.values.filter { $0 != MixerGainScale.unityGain }.count
        observation.privateAPIAvailable = resolver.privateAPIAvailable
        for entry in roster {
            switch resolutions[pid_t(bitPattern: entry.processID)]?.kind ?? .unresolved {
            case .privateAPI: observation.resolvedByPrivateAPICount += 1
            case .parentFallback: observation.resolvedByParentCount += 1
            case .processItself: observation.resolvedAsProcessCount += 1
            case .unresolved: observation.unresolvedCount += 1
            }
        }
        return observation
    }

    private func publish() {
        var clientIDsByChannelKey: [String: [UInt32]] = [:]
        for entry in roster {
            guard let key = channelKey(forProcess: entry.processID) else { continue }
            clientIDsByChannelKey[key, default: []].append(entry.clientID)
        }
        didUpdate?(MixerCoordinatorUpdate(
            identities: identities, clientIDsByChannelKey: clientIDsByChannelKey
        ))
    }
}

/// 調停役がオーディオ世界へ出す依頼の口。
protocol MixerAudioBridge: AnyObject, Sendable {
    func readMixerRoster(_ token: AudioWorldToken) -> [MixerRosterEntry]
    @discardableResult
    func writeMixerGainTable(_ table: [String: Double], _ token: AudioWorldToken) -> Bool
    func recordMixerCoordination(_ observation: MixerCoordinationObservation)
}
