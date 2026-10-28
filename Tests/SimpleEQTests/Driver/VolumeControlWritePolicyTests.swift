import XCTest
import SimpleEQRingC
@testable import SimpleEQ

final class VolumeControlWritePolicyTests: XCTestCase {

    private var servicePath: String { String(cString: simpleeq_audio_service_path()) }
    private var serviceName: String { String(servicePath.split(separator: "/").last ?? "") }

    private func isServicePath(_ path: String?) -> Bool {
        guard let path else { return simpleeq_volume_control_path_is_audio_service(nil) }
        return path.withCString { simpleeq_volume_control_path_is_audio_service($0) }
    }

    private func isServiceName(_ name: String?) -> Bool {
        guard let name else { return simpleeq_volume_control_process_name_is_audio_service(nil) }
        return name.withCString { simpleeq_volume_control_process_name_is_audio_service($0) }
    }

    func testPathMatchesOnlyTheExactServicePath() {
        XCTAssertTrue(isServicePath(servicePath))
        XCTAssertFalse(isServicePath("/tmp/" + serviceName))
        XCTAssertFalse(isServicePath(servicePath + "x"))
        XCTAssertFalse(isServicePath(""))
        XCTAssertFalse(isServicePath(nil))
    }

    func testNameMatchesOnlyTheLastPathComponent() {
        XCTAssertTrue(isServiceName(serviceName))
        XCTAssertFalse(isServiceName(servicePath))
        XCTAssertFalse(isServiceName(String(serviceName.dropFirst())))
        XCTAssertFalse(isServiceName(serviceName + "x"))
        XCTAssertFalse(isServiceName(""))
        XCTAssertFalse(isServiceName(nil))
    }

    func testWriteIsRefusedOnlyFromTheServiceWhileTheSeatIsHeld() {
        XCTAssertTrue(simpleeq_volume_control_refuses_write(true, true))
        XCTAssertFalse(simpleeq_volume_control_refuses_write(true, false))
        XCTAssertFalse(simpleeq_volume_control_refuses_write(false, true))
        XCTAssertFalse(simpleeq_volume_control_refuses_write(false, false))
    }
}
