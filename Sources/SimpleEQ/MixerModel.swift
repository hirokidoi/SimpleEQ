import AppKit
import Foundation

/// 鳴っていないチャンネルの表示名とアイコンの引き先。行はユーザーが消すまで残るため、
/// アプリが起動していない間も名前が要る。
@MainActor
enum MixerAppDirectory {
    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func identity(forChannelKey key: String) -> MixerAppIdentity? {
        if let bundleID = MixerSpec.bundleID(inKey: key) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            let name = (Bundle(url: url)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return MixerAppIdentity(displayName: name, iconFilePath: url.path)
        }
        guard let name = MixerSpec.processName(inKey: key) else { return nil }
        return MixerAppIdentity(displayName: name, subtitle: "バンドルがありません")
    }
}

/// ミキサーの UI 世界の状態。チャンネル一覧・並び・編集モード・永続化を持つ。
@MainActor
final class MixerModel: ObservableObject {

    struct Channel: Identifiable, Equatable {
        let key: String
        var gain: Double
        var muted: Bool
        var identity: MixerAppIdentity?

        var id: String { key }
        var isDefault: Bool { gain == MixerGainScale.unityGain && !muted }
        /// ドライバへ届ける実効ゲイン。ミュートは線形 0。
        var effectiveGain: Double { muted ? MixerGainScale.silentGain : gain }
    }

    struct Candidate: Identifiable, Equatable {
        let key: String
        let identity: MixerAppIdentity
        let playing: Bool

        var id: String { key }
    }

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var candidates: [Candidate] = []
    @Published var editing = false

    /// メーターが読む、チャンネルキーごとのクライアント識別値。動くのは席が増減したときだけ。
    @Published private(set) var clientIDsByChannelKey: [String: [UInt32]] = [:]

    let levelStore: MixerLevelStore

    private let settings: SettingsStore
    private let coordinator: MixerCoordinator?
    /// 候補プールの母集合 (調停役が持つ辞書の写し)。
    private var resolvedIdentities: [String: MixerAppIdentity] = [:]
    private var playingKeys: Set<String> = []
    /// 鳴っていないチャンネルの素性。行の集合が変わったときだけ引く。
    private var directoryIdentities: [String: MixerAppIdentity?] = [:]
    private var iconCache: [String: NSImage] = [:]
    /// ドラッグ中の値。確定するまで channels へは書かない。
    private var draggingGains: [String: Double] = [:]

    var canAddChannel: Bool { channels.count < MixerSpec.maxChannelCount }

    init(settings: SettingsStore, coordinator: MixerCoordinator?, levelStore: MixerLevelStore) {
        self.settings = settings
        self.coordinator = coordinator
        self.levelStore = levelStore
        loadChannels()
        // 保存されたミュートは起動直後から効いていなければならない。
        pushToCoordinator()
    }

    // MARK: - 調停役からの押し出し

    /// ドラッグ中も届くため、値が動いた回だけ代入する。
    func apply(_ update: MixerCoordinatorUpdate) {
        resolvedIdentities = update.identities
        playingKeys = update.playingKeys
        if clientIDsByChannelKey != update.clientIDsByChannelKey {
            clientIDsByChannelKey = update.clientIDsByChannelKey
        }
        refreshIdentities()
        rebuildCandidates()
    }

    /// パネルを開いたときの起動契機。周期と同じ 1 パスを呼ぶだけで、専用の経路を作らない。
    func panelDidAppear() {
        coordinator?.runPass()
    }

    /// 閉じた時点を編集モードの終わりにする。
    func panelDidClose() {
        editing = false
    }

    // MARK: - チャンネルの操作

    func add(key: String) {
        guard canAddChannel, !channels.contains(where: { $0.key == key }) else { return }
        channels.append(Channel(key: key, gain: MixerGainScale.unityGain, muted: false, identity: identity(for: key)))
        persistAndPush()
    }

    func remove(key: String) {
        channels.removeAll { $0.key == key }
        draggingGains.removeValue(forKey: key)
        persistAndPush()
    }

    func move(fromKey: String, toKey: String) {
        guard fromKey != toKey,
              let from = channels.firstIndex(where: { $0.key == fromKey }),
              let to = channels.firstIndex(where: { $0.key == toKey }) else { return }
        let moved = channels.remove(at: from)
        channels.insert(moved, at: to)
        persistAndPush()
    }

    func toggleMute(key: String) {
        guard let index = channels.firstIndex(where: { $0.key == key }) else { return }
        channels[index].muted.toggle()
        persistAndPush()
    }

    func resetToDefault(key: String) {
        guard let index = channels.firstIndex(where: { $0.key == key }) else { return }
        channels[index].gain = MixerGainScale.unityGain
        channels[index].muted = false
        draggingGains.removeValue(forKey: key)
        persistAndPush()
    }

    /// 確定するまで channels へは書かず、音への反映だけ先に行う。
    func updateGainDuringDrag(_ gain: Double, for key: String) {
        draggingGains[key] = gain
        pushToCoordinator()
    }

    func commitGain(for key: String) {
        guard let gain = draggingGains.removeValue(forKey: key),
              let index = channels.firstIndex(where: { $0.key == key }) else { return }
        channels[index].gain = gain
        persistAndPush()
    }

    func gain(for key: String) -> Double {
        draggingGains[key] ?? channels.first { $0.key == key }?.gain ?? MixerGainScale.unityGain
    }

    /// まだ設定していない状態へ戻すことで、起動時と同じ経路を走らせる。
    func resetToInitialState() {
        settings.mixerChannels = nil
        draggingGains.removeAll()
        loadChannels()
        pushToCoordinator()
    }

    // MARK: - 表示素性

    func icon(for identity: MixerAppIdentity?) -> NSImage? {
        guard let path = identity?.iconFilePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    // MARK: - 内部

    private func loadChannels() {
        let entries = settings.mixerChannels ?? seedEntries()
        channels = entries.map {
            Channel(key: $0.key, gain: $0.gain, muted: $0.muted, identity: identity(for: $0.key))
        }
        rebuildCandidates()
    }

    private func seedEntries() -> [SettingsStore.MixerChannelEntry] {
        MixerSpec.initialSeedChannelKeys(isInstalled: MixerAppDirectory.isInstalled).map {
            SettingsStore.MixerChannelEntry(key: $0, gain: MixerGainScale.unityGain, muted: false)
        }
    }

    private func identity(for key: String) -> MixerAppIdentity? {
        if let resolved = resolvedIdentities[key] { return resolved }
        if let cached = directoryIdentities[key] { return cached }
        let looked = MixerAppDirectory.identity(forChannelKey: key)
        directoryIdentities[key] = looked
        return looked
    }

    private func refreshIdentities() {
        for index in channels.indices {
            let resolved = identity(for: channels[index].key)
            if channels[index].identity != resolved { channels[index].identity = resolved }
        }
    }

    private func rebuildCandidates() {
        let taken = Set(channels.map(\.key))
        let rebuilt = resolvedIdentities
            .filter { !taken.contains($0.key) }
            .map { Candidate(key: $0.key, identity: $0.value, playing: playingKeys.contains($0.key)) }
            .sorted { $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending }
        if candidates != rebuilt { candidates = rebuilt }
    }

    private func persistAndPush() {
        settings.mixerChannels = channels.map {
            SettingsStore.MixerChannelEntry(key: $0.key, gain: $0.gain, muted: $0.muted)
        }
        rebuildCandidates()
        pushToCoordinator()
    }

    private func pushToCoordinator() {
        coordinator?.updateChannels(channels.map {
            MixerChannelSnapshot(
                key: $0.key,
                gain: $0.muted ? MixerGainScale.silentGain : (draggingGains[$0.key] ?? $0.gain)
            )
        })
    }
}
