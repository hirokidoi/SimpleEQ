import Darwin
import Dispatch
import Foundation
import Synchronization

/// オーディオ世界 (単一の直列キューで動く、音に関わる資源と状態のすべてを持つ世界) への唯一の入口。
///
/// 生成できるのは組み立て役だけで、この型は static な共有インスタンスを持たない。
/// 並行に触れる可変状態は畳み込みの保管庫だけで、os_unfair_lock が守る (下記)。
final class AudioWorld: @unchecked Sendable {
    /// submit(coalescingKey:_:)/submitUncoalesced(_:) を経由しない直接ディスパッチは、HAL リスナー
    /// 登録先・合流窓の遅延実行 (asyncAfter) の 2 用途に限る (これらは OS 側から直接ディスパッチ
    /// されるため、通行証は assumingOnQueue() で得る)。
    let queue: DispatchQueue

    /// 未処理の依頼を同じ key の最新の 1 件へ置き換えるための保管庫。os_unfair_lock で保護する
    /// (realtime 経路ではないため軽量ロックで足りる)。
    private var coalescingLock = os_unfair_lock_s()
    private var pendingByKey: [AnyHashable: @Sendable (AudioWorldToken) -> Void] = [:]
    private var generationByKey: [AnyHashable: UInt64] = [:]

    /// テストは suspend()/resume() で駆動を止めた自前のキューを渡すことで、畳み込みが成立する窓を
    /// 決定的に再現できる。
    init(queue: DispatchQueue = DispatchQueue(label: "com.simpleeq.audioworld", qos: .userInitiated)) {
        self.queue = queue
    }

    /// 同じ key を持つ未処理の依頼が既にあれば、まだ実行が始まっていない限り最新の work で
    /// 置き換える (畳む)。意味があるのは最新の 1 件だけの依頼に使う。
    func submit(coalescingKey key: some Hashable & Sendable, _ work: @escaping @Sendable (AudioWorldToken) -> Void) {
        os_unfair_lock_lock(&coalescingLock)
        let generation = (generationByKey[key] ?? 0) &+ 1
        generationByKey[key] = generation
        pendingByKey[key] = work
        os_unfair_lock_unlock(&coalescingLock)

        queue.async { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.coalescingLock)
            let isLatest = self.generationByKey[key] == generation
            let job = isLatest ? self.pendingByKey.removeValue(forKey: key) : nil
            if isLatest { self.generationByKey.removeValue(forKey: key) }
            os_unfair_lock_unlock(&self.coalescingLock)
            job?(AudioWorldToken())
        }
    }

    /// submit(coalescingKey:_:) と異なり畳み込みの対象にせず、呼び出しごとに個別にキューへ積む。
    func submitUncoalesced(_ work: @escaping @Sendable (AudioWorldToken) -> Void) {
        queue.async { work(AudioWorldToken()) }
    }

    /// 終了シーケンス専用。他のすべての経路は完了を待たない。timeout はログアウト/システム終了
    /// 経路の OS 側の待ち時間上限に収まるよう、呼び出し元が有界な値を渡すこと。上限に達したら
    /// 待ちを諦める (work 自体はキュー上で走り続ける)。
    @discardableResult
    func submitUncoalescedAndWait<Value: Sendable>(
        timeout: TimeInterval, _ work: @escaping @Sendable (AudioWorldToken) -> Value
    ) -> Value? {
        // セマフォの待ちが作る happens-before は型からは見えないため、値の受け渡しは
        // 見える形の同期で行う。
        let produced = Mutex<Value?>(nil)
        let done = DispatchSemaphore(value: 0)
        queue.async {
            let value = work(AudioWorldToken())
            produced.withLock { $0 = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return produced.withLock { $0 }
    }

    /// `queue` を実行キューとして明示的に登録した CoreAudio/DispatchSourceTimer のコールバック内
    /// から呼ぶ (submit 系を経由せず OS 側から直接このキューへディスパッチされる経路専用)。
    /// dispatchPrecondition が実行時に検証する。
    func assumingOnQueue() -> AudioWorldToken {
        dispatchPrecondition(condition: .onQueue(queue))
        return AudioWorldToken()
    }
}

/// オーディオ世界の直列キュー上でのみ得られる通行証。音に関わる資源を**変更する**操作は、この型の値を
/// 引数に要求する形でコンパイル時に境界を守らせる。生成できるのは AudioWorld 自身だけ。
struct AudioWorldToken {
    fileprivate init() {}
}

/// 依頼の種別を表す共通の鍵。
enum AudioRequestKey: Hashable {
    case periodicVerification
    /// バンドごとに鍵を分けることで、同時に別バンドをドラッグしても互いを畳み消さない。
    case eqBandGain(Int)
    case processingSettings
    case outputDeviceSelection
    case systemOutputAdoption
    /// 意味があるのは最新の1件だけであり、リセットはこの鍵を使わず submitUncoalesced で投入する。
    case diagnosticsSnapshot
    /// デバイス 1 台あたり複数回の問い合わせを伴うため、構成変更の通知が連続して届く局面で畳まない
    /// とキューの占有が積み上がる。
    case outputDeviceOptions
    /// キューが塞がっている間も投入は続くため、畳まないと未処理の依頼が積み上がる。
    case heartbeat
    /// 意味があるのは最新の 1 件だけ。
    case mixerRoster
    /// ドラッグ中のゲイン変更が溜まらないよう 1 本にする。
    case mixerGainTable
}
