import XCTest

final class AppInfoPlistTests: XCTestCase {
    // 説明文が無いと Tap の作成が黙って失敗し、AirPlay モードに入れない。
    func testTheAudioCaptureUsageIsDescribed() throws {
        let data = try Data(contentsOf: RepositoryFiles.appInfoPlist)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let description = try XCTUnwrap(plist["NSAudioCaptureUsageDescription"] as? String)
        XCTAssertFalse(description.isEmpty)
    }
}
