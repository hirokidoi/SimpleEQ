import Foundation

enum TestDefaults {
    static let namePrefix = "SimpleEQTests"

    static func makeName(_ label: String) -> String {
        "\(namePrefix).\(label).\(UUID().uuidString)"
    }

    static func remove(name: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: name)
    }
}
