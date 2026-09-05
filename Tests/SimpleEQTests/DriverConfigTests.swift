import XCTest
@testable import SimpleEQ

/// UID はユーザが組んだ Aggregate デバイスの構成が依存する外部インタフェースであり、
/// 意図せず変わると構成が黙って壊れるため値そのものを固定する。
final class DriverConfigTests: XCTestCase {
    func testDeviceNameMatchesDriverImplementation() {
        XCTAssertEqual(DriverConfig.deviceName, "SimpleEQ Audio 2ch")
    }

    func testDeviceUIDMatchesDriverImplementation() {
        XCTAssertEqual(DriverConfig.deviceUID, "SimpleEQAudio2ch_UID")
    }
}
