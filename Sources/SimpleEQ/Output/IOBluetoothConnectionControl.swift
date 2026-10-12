import CoreBluetooth
import Foundation
import IOBluetooth
import Synchronization

/// 切断と許可の応答待ちで、オーディオ世界とメインを塞がないために専用キューで動かす。
final class IOBluetoothConnectionControl: BluetoothConnectionControl {
    private let queue = DispatchQueue(label: "com.simpleeq.bluetooth")
    private let cache = Mutex<BluetoothAuthorizationCache>(BluetoothAuthorizationCache())
    private let changeHandler = Mutex<(@Sendable () -> Void)?>(nil)

    var isAuthorizationDenied: Bool { cache.withLock { $0.isDenied } }

    func prepareAuthorization() {
        // 初回の呼び出しが許可のプロンプトを出す。応答待ちでこのキューだけが止まる。
        queue.async {
            _ = IOBluetoothDevice.pairedDevices()
            self.readAuthorization()
        }
    }

    func refreshAuthorization() {
        queue.async { self.readAuthorization() }
    }

    func observeAuthorizationChanges(_ handler: @escaping @Sendable () -> Void) {
        changeHandler.withLock { $0 = handler }
    }

    /// 専用キュー上でのみ呼ぶ。
    private func readAuthorization() {
        let authorization = CBManager.authorization
        let changed = cache.withLock { $0.update(authorization) }
        guard changed else { return }
        let handler = changeHandler.withLock { $0 }
        handler?()
    }

    func disconnect(outputDeviceUID: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            let addresses = paired.compactMap { $0.addressString }
            guard let address = BluetoothAddress.pairedAddress(matchingDeviceUID: outputDeviceUID, among: addresses),
                  let device = IOBluetoothDevice(addressString: address) else {
                completion(false)
                return
            }
            completion(device.closeConnection() == kIOReturnSuccess)
        }
    }
}
