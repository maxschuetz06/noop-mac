import Foundation

/// Where the app process runs. Inside the XCTest host (`NOOP.app` launched by StrandTests) the app still
/// builds an `AppModel` so hosted screens get their environment object, but it must not wake
/// CoreBluetooth, open the user's store or start its background schedulers.
enum AppRuntime {
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
