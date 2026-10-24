// Listens (never connects) to `ESP 32/go2_leash` BLE advertisements:
// manufacturer data FF FF <state> <seq> <posture> <cm> <count>. The operator picks one
// board; a new count from that board with posture 1 (SIT) or 2 (STAND) is a gesture.
// The first packet, a firmware reset (posture 0) and anything after a stale gap only
// set the baseline, so a board coming back never fires a command by itself.

import CoreBluetooth
import Foundation

struct LeashBoard: Identifiable {
    let id: UUID
    var rssi: Int
    var lastSeen: Date
    var state: UInt8
    var posture: UInt8
    var count: UInt8
}

@MainActor
final class LeashScanner: NSObject, ObservableObject {
    static let staleAfter: TimeInterval = 2

    @Published var radio = "off"
    @Published var boards: [UUID: LeashBoard] = [:]
    @Published var selected: UUID?

    /// (posture, count) for each accepted new gesture from the selected board.
    var onGesture: ((UInt8, UInt8) -> Void)?
    var onNote: ((String) -> Void)?

    /// Longest gap between the selected board's packets since the last reset (BLE loss measurement).
    @Published var maxGap: TimeInterval = 0
    /// A release counts only after this long without a held packet (filters one lost/odd packet).
    static let releaseConfirm: TimeInterval = 0.15
    private var lastHeldAt = Date.distantPast
    private var lastHeldDir = 0

    private var central: CBCentralManager?
    private var baseline: UInt8?
    private static let savedKey = "selectedLeashBoard"
    private let saved = UserDefaults.standard.string(forKey: LeashScanner.savedKey).flatMap(UUID.init)

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func select(_ id: UUID) {
        selected = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.savedKey)
        baseline = boards[id]?.count
        onNote?("board selected …\(id.uuidString.suffix(4)); baseline count \(baseline.map(String.init) ?? "-")")
    }

    /// Selected board's walk direction (1 forward, -1 backward, 0 none) and its age, for hold-to-walk.
    /// state byte: 1 = BOOT or forward pads touched, 2 = backward pads touched.
    func held(now: Date = Date()) -> (Int, TimeInterval) {
        guard let id = selected, let b = boards[id] else { return (0, .infinity) }
        let age = now.timeIntervalSince(b.lastSeen)
        if b.state == 1 || b.state == 2 { return (b.state == 1 ? 1 : -1, age) }
        let lingering = now.timeIntervalSince(lastHeldAt) < Self.releaseConfirm
        return (lingering ? lastHeldDir : 0, age)
    }

    func resetGap() { maxGap = 0 }

    func fresh(_ board: LeashBoard, now: Date = Date()) -> Bool {
        now.timeIntervalSince(board.lastSeen) <= Self.staleAfter
    }

    fileprivate func receive(_ id: UUID, rssi: Int, data: Data) {
        let b = [UInt8](data)
        guard b.count == 7, b[0] == 0xFF, b[1] == 0xFF else { return }
        let now = Date()
        let wasStale = boards[id].map { !fresh($0, now: now) } ?? true
        if id == selected, let prev = boards[id]?.lastSeen { maxGap = max(maxGap, now.timeIntervalSince(prev)) }
        if id == selected, b[2] == 1 || b[2] == 2 { lastHeldAt = now; lastHeldDir = b[2] == 1 ? 1 : -1 }
        boards[id] = LeashBoard(id: id, rssi: rssi, lastSeen: now, state: b[2], posture: b[4], count: b[6])
        if selected == nil, id == saved {
            selected = id                       // remembered board; first packet below is its baseline
            onNote?("remembered board …\(id.uuidString.suffix(4)) selected")
        }
        guard id == selected else { return }
        let posture = b[4], count = b[6]
        if baseline == nil || wasStale || posture == 0 {
            if baseline != count { onNote?("board baseline count \(count)\(wasStale ? " (after stale)" : "")") }
            baseline = count
            return
        }
        guard count != baseline else { return }
        baseline = count
        onGesture?(posture, count)
    }
}

extension LeashScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                radio = "scanning"
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .unauthorized: radio = "Bluetooth not allowed (Settings)"
            case .poweredOff: radio = "Bluetooth off"
            default: radio = "unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        let id = peripheral.identifier, rssi = RSSI.intValue
        Task { @MainActor in self.receive(id, rssi: rssi, data: data) }
    }
}
