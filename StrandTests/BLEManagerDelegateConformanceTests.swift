import CoreBluetooth
import XCTest
@testable import Strand

/// CoreBluetooth reaches BLEManager only through Objective-C selectors. A delegate method that ends up
/// outside its conformance extension (or with a drifted signature) is never called and fails silently,
/// so pin every callback the app relies on. Checks the class only; no CBCentralManager is created.
final class BLEManagerDelegateConformanceTests: XCTestCase {
    func testEveryDelegateCallbackIsVisibleToTheObjectiveCRuntime() {
        let selectors: [Selector] = [
            #selector(CBCentralManagerDelegate.centralManagerDidUpdateState(_:)),
            #selector(CBCentralManagerDelegate.centralManager(_:didDiscover:advertisementData:rssi:)),
            #selector(CBCentralManagerDelegate.centralManager(_:didConnect:)),
            #selector(CBCentralManagerDelegate.centralManager(_:didDisconnectPeripheral:error:)),
            #selector(CBCentralManagerDelegate.centralManager(_:didFailToConnect:error:)),
            #selector(CBCentralManagerDelegate.centralManager(_:willRestoreState:)),
            #selector(CBPeripheralDelegate.peripheral(_:didDiscoverServices:)),
            #selector(CBPeripheralDelegate.peripheral(_:didDiscoverCharacteristicsFor:error:)),
            // Characteristic overloads; the descriptor variants share the Swift name.
            NSSelectorFromString("peripheral:didWriteValueForCharacteristic:error:"),
            NSSelectorFromString("peripheral:didUpdateValueForCharacteristic:error:"),
            #selector(CBPeripheralDelegate.peripheral(_:didUpdateNotificationStateFor:error:)),
        ]

        let missing = selectors.filter { !BLEManager.instancesRespond(to: $0) }.map(NSStringFromSelector)

        XCTAssertEqual(missing, [])
    }
}
