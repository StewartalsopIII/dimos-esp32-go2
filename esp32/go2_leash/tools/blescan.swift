// Mac Bluetooth listener for go2_leash: prints each change of state/posture/count from the board's adverts.
// Use it when serial readback is unreliable. Build and run:
//   swiftc -O blescan.swift -o /tmp/blescan && /tmp/blescan 60     # listen 60 s
// state 1 = forward (G32 edge or BOOT held), 2 = backward (G4/G15), 0 = none.
import CoreBluetooth
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
final class S: NSObject, CBCentralManagerDelegate {
    var m: CBCentralManager!
    var last = ""
    override init() { super.init(); m = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("radio state \(c.state.rawValue)")
        if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        guard let d = a[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let b = [UInt8](d)
        guard b.count == 7, b[0] == 0xFF, b[1] == 0xFF else { return }
        let dir = b[2] == 1 ? "FORWARD" : b[2] == 2 ? "BACKWARD" : "none"
        let line = "state=\(b[2]) (\(dir)) posture=\(b[4]) count=\(b[6])"
        if line != last { last = line; print("\(Date().formatted(date: .omitted, time: .standard)) \(line)") }
    }
}
let s = S()
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90))
