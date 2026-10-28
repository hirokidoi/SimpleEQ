import XCTest

/// 切替に失敗して戻す経路は実デバイスで再現できないため、配線をソースで守る。
final class AudioEngineSourceTests: XCTestCase {
    func testEveryDelayLineRebuildInTheSwitchAlsoDecidesTheDriverRate() throws {
        let text = try String(
            contentsOf: RepositoryFiles.appSourceDirectory.appendingPathComponent("Audio/AudioEngine.swift"), encoding: .utf8
        )
        let start = try XCTUnwrap(text.range(of: "func switchOutputDevice(")).upperBound
        let next = ["\n    func ", "\n    private func "]
            .compactMap { text.range(of: $0, range: start..<text.endIndex)?.lowerBound }
            .min() ?? text.endIndex
        let body = text[start..<next]

        XCTAssertFalse(body.contains("rebuildPresentationDelay("), "切替で出力先が決まる地点はレートの判定を通す")
        XCTAssertTrue(body.contains("rebuildForOutputDevice(previousID"), "失敗時の巻き戻しも出力先が決まる地点")
    }
}
