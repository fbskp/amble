// BLE probe. Usage:
//   probe scan [seconds]
//   probe connect <name-substring | peripheral-uuid> [listen-seconds]   (read-only)
//   probe ctl <name-substring | peripheral-uuid> <step> [<step> ...]    (WRITES to FTMS control point 2AD9)
// ctl steps: req | start | stop | pause | reset | speed=<km/h> | wait=<seconds>
//   e.g.  probe ctl WalkMate-<number> req start wait=5 speed=2.0 wait=10 stop
// Ctrl-C during ctl sends a stop command before exiting.
// scan/connect never write. connect dumps all services/characteristics, reads readable ones,
// subscribes to every notify/indicate characteristic and logs data.
import CoreBluetooth
import Foundation

func hex(_ d: Data?) -> String { d?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "<nil>" }
func ts() -> String { String(format: "%.2f", Date().timeIntervalSince(start)) }
let start = Date()
setvbuf(stdout, nil, _IOLBF, 0)

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    let mode: String, target: String?, seconds: Double
    var seen = Set<UUID>()
    var peripheral: CBPeripheral?
    var ctrlPoint: CBCharacteristic?
    var scriptStarted = false
    let script: [String]

    init(mode: String, target: String?, seconds: Double, script: [String] = []) {
        self.mode = mode; self.target = target; self.seconds = seconds; self.script = script
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { print("Bluetooth state: \(c.state.rawValue) (need poweredOn; check permission in System Settings > Privacy > Bluetooth)"); return }
        print("Scanning...")
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if mode == "scan" { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("Done."); exit(0) } }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if self.peripheral == nil { print("Target not found."); exit(1) } } }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        if mode == "scan" {
            guard seen.insert(p.identifier).inserted else { return }
            let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString }.joined(separator: ",") ?? ""
            let mfg = hex(ad[CBAdvertisementDataManufacturerDataKey] as? Data)
            print("[\(ts())] \(name)  rssi=\(rssi)  id=\(p.identifier.uuidString)  services=[\(svcs)]  mfg=\(mfg)")
        } else if let t = target, peripheral == nil,
                  p.identifier.uuidString.lowercased() == t.lowercased() || name.lowercased().contains(t.lowercased()) {
            print("Found \(name) (\(p.identifier.uuidString)), advertisement: \(ad)")
            peripheral = p; p.delegate = self
            c.stopScan(); c.connect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("[\(ts())] Connected. Discovering services...")
        p.discoverServices(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("Done listening."); exit(0) }
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { print("Connect failed: \(String(describing: error))"); exit(1) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { print("[\(ts())] Disconnected: \(String(describing: error))"); exit(0) }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { print("SERVICE \(s.uuid.uuidString)"); p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            var props: [String] = []
            let pr = c.properties
            if pr.contains(.read) { props.append("read") }
            if pr.contains(.write) { props.append("write") }
            if pr.contains(.writeWithoutResponse) { props.append("writeNoResp") }
            if pr.contains(.notify) { props.append("notify") }
            if pr.contains(.indicate) { props.append("indicate") }
            print("  CHAR \(c.uuid.uuidString) [\(props.joined(separator: ","))] (service \(s.uuid.uuidString))")
            if pr.contains(.read) { p.readValue(for: c) }
            if c.uuid == CBUUID(string: "2AD9") { ctrlPoint = c }
            if pr.contains(.notify) || pr.contains(.indicate) { p.setNotifyValue(true, for: c) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { print("[\(ts())] \(c.uuid.uuidString) error: \(e.localizedDescription)"); return }
        let str = c.value.flatMap { String(data: $0, encoding: .utf8) }.map { s in s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } ? "  \"\(s)\"" : "" } ?? ""
        print("[\(ts())] \(c.uuid.uuidString) = \(hex(c.value))\(str)")
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        print("  notify \(c.uuid.uuidString): \(error?.localizedDescription ?? (c.isNotifying ? "on" : "off"))")
        if mode == "ctl", c.uuid == CBUUID(string: "2AD9"), c.isNotifying, !scriptStarted {
            scriptStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runScript(self.script[...]) }
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        print("[\(ts())] write to \(c.uuid.uuidString) \(error.map { "FAILED: \($0.localizedDescription)" } ?? "acknowledged")")
    }

    func send(_ bytes: [UInt8], _ label: String) {
        guard let p = peripheral, let cp = ctrlPoint else { print("no control point"); return }
        print("[\(ts())] >>> \(label): \(hex(Data(bytes)))")
        p.writeValue(Data(bytes), for: cp, type: .withResponse)
    }

    func runScript(_ steps: ArraySlice<String>) {
        guard let step = steps.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { print("Script finished."); exit(0) }
            return
        }
        var delay = 1.0
        switch step {
        case "req": send([0x00], "request control")
        case "start": send([0x07], "start/resume")
        case "stop": send([0x08, 0x01], "stop")
        case "pause": send([0x08, 0x02], "pause")
        case "reset": send([0x01], "reset")
        case let s where s.hasPrefix("speed="):
            let kmh = Double(s.dropFirst(6)) ?? 0
            let v = UInt16(max(0, min(kmh, 6.0)) * 100)
            send([0x02, UInt8(v & 0xff), UInt8(v >> 8)], "set speed \(kmh) km/h")
        case let s where s.hasPrefix("wait="): delay = Double(s.dropFirst(5)) ?? 1
        default: print("unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.runScript(steps.dropFirst()) }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: probe scan [secs] | probe connect <name|uuid> [secs]"); exit(2) }
let probe: Probe
switch args[1] {
case "scan": probe = Probe(mode: "scan", target: nil, seconds: Double(args.count > 2 ? args[2] : "") ?? 10)
case "connect" where args.count > 2: probe = Probe(mode: "connect", target: args[2], seconds: Double(args.count > 3 ? args[3] : "") ?? 30)
case "ctl" where args.count > 3: probe = Probe(mode: "ctl", target: args[2], seconds: 900, script: Array(args[3...]))
default: print("bad arguments (build 2): got \(args.dropFirst())"); exit(2)
}
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\nInterrupted: sending stop")
    if probe.mode == "ctl" { probe.send([0x08, 0x01], "stop") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(130) }
}
sigint.resume()
RunLoop.main.run()
