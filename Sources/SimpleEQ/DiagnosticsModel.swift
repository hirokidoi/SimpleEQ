import Foundation

/// 診断の表示・書き出しが読む状態の保持先。EQ 本体のビューが購読する観測対象とは分けてある。
/// アプリの生存期間を通じて 1 つを保ち、ウィンドウの開閉では作り直さない。
@MainActor
final class DiagnosticsModel: ObservableObject {

    /// 表示・書き出しが読むスナップショット。オーディオ世界の観測量そのものは UI 世界から直接読まず、
    /// 依頼の投入を契機に取ったスナップショットがここへ押し出される単一の入口を持つ。
    @Published private(set) var snapshot: AudioRuntimeMetrics.Snapshot
    /// 定期更新の可否。Diagnostics ウィンドウの可視性から結線する。
    @Published var active: Bool = false
    /// 書き出しの置き場。起動中だけ保たれ、再起動で既定へ戻る。
    @Published private(set) var exportDirectory: URL
    /// 直近の書き出しの結果。メニューから撃った分もここへ残る。
    @Published private(set) var lastExport: ExportOutcome?

    enum ExportOutcome: Equatable {
        case written(fileName: String)
        case failed(reason: String)
    }

    private let engine: AudioEngine
    private let audioWorld: AudioWorld
    /// 書き出しのファイル操作を行うキュー。
    /// 置き場は画面から選び直せるため、応答の遅い置き場を選ばれてもメインスレッドを止めないようにする。
    nonisolated private static let fileQueue = DispatchQueue(label: "SimpleEQ.diagnostics.export", qos: .utility)

    init(engine: AudioEngine, audioWorld: AudioWorld, exportDirectory: URL = DiagnosticsExport.defaultDirectory()) {
        self.engine = engine
        self.audioWorld = audioWorld
        self.exportDirectory = exportDirectory
        self.snapshot = .initial(appliedSampleRate: AudioConfig.appliedSampleRate)
    }

    // MARK: - 観測量

    /// 定期更新用。意味があるのは最新の 1 件だけのため畳み込む。
    func refresh() {
        audioWorld.submit(coalescingKey: AudioRequestKey.diagnosticsSnapshot) { [engine, weak self] token in
            let snapshot = engine.runtimeMetricsSnapshot(token)
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
    }

    /// 取りこぼしてはならない単発の依頼として送る
    /// (定期更新の畳み込みに巻き込まれて消えることを避けるため、鍵を共有しない)。
    func reset() {
        audioWorld.submitUncoalesced { [engine, weak self] token in
            // 基準値を立てる前に共有ヘッダの現在値を取り込む。
            engine.refreshDriverObservations(token)
            engine.runtimeMetrics.reset()
            let snapshot = engine.runtimeMetricsSnapshot(token)
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
    }

    /// スナップショットを受け取る単一の入口。値が変わらない場合は代入しない。
    private func apply(_ snapshot: AudioRuntimeMetrics.Snapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }

    // MARK: - 書き出し

    /// 置き場を選び直す。永続化はしない。
    func setExportDirectory(_ url: URL) {
        exportDirectory = url
    }

    /// 置き場を用意して、その場所を開く。まだ一度も書き出していない間は置き場自体が無いため、
    /// 書き出しの直前と同じ手当てを通す。ディレクトリの用意は書き出しと同じキューで行う
    /// (応答の遅い置き場を選ばれてもメインスレッドを止めない)。
    func revealExportDirectory(open: @escaping @MainActor (URL) -> Void) {
        let directory = exportDirectory
        Self.fileQueue.async {
            guard DiagnosticsExport.ensureDirectory(directory) else { return }
            DispatchQueue.main.async { open(directory) }
        }
    }

    /// その場で取ったスナップショットを書き出す。
    /// 画面へ押し出された値は画面が開いている間しか更新されないため、書き出しにはそれを使わず、
    /// リセットと同じ単発の依頼で取り直す。
    func export(now: Date = Date()) {
        // 置き場は UI 世界の値のため、依頼を投げる前 (メインスレッド) に読んで持ち回る。
        let directory = exportDirectory
        audioWorld.submitUncoalesced { [engine, weak self] token in
            let snapshot = engine.runtimeMetricsSnapshot(token)
            let text = DiagnosticsReport.text(snapshot, exportedAt: now)
            Self.fileQueue.async {
                let outcome = DiagnosticsExport.write(text, into: directory, at: now)
                // 書き出した値を表示へ反映し直さない (書き込みの間に定期更新が進んでいた場合、
                // 表示だけが書き出し時点へ巻き戻る)。表示の更新は定期更新が担う。
                DispatchQueue.main.async { self?.lastExport = outcome }
            }
        }
    }
}
