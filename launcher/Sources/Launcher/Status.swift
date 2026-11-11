import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import IOKit.ps
import SQLite3

struct BatteryInfo {
    let percent: Int
    let charging: Bool
    let plugged: Bool
}

struct WifiInfo {
    let connected: Bool
    let ssid: String?
    let bars: Int
}

struct SystemNotification {
    let id: Int64
    let app: String
    let appPath: String?
    let title: String
    let subtitle: String
    let body: String
    let date: Date
}

enum SystemStatus {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE, d MMM"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date).replacingOccurrences(of: ".", with: "").lowercased()
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "agora" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        if s < 172800 { return "ontem" }
        return "\(s / 86400) d"
    }

    static func battery() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return BatteryInfo(percent: current * 100 / max, charging: charging, plugged: plugged)
        }
        return nil
    }

    static func wifi() -> WifiInfo {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else {
            return WifiInfo(connected: false, ssid: nil, bars: 0)
        }
        let rssi = iface.rssiValue()
        guard rssi != 0 else { return WifiInfo(connected: false, ssid: nil, bars: 0) }
        let bars = rssi >= -55 ? 3 : (rssi >= -70 ? 2 : 1)
        return WifiInfo(connected: true, ssid: iface.ssid(), bars: bars)
    }
}

final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

enum NotificationReader {
    private static var appCache: [String: (String, String?)] = [:]

    private static func dbURL() -> URL? {
        let fm = FileManager.default
        let modern = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
        if fm.fileExists(atPath: modern.path) { return modern }
        let userDir = (NSTemporaryDirectory() as NSString).deletingLastPathComponent
        let legacy = URL(fileURLWithPath: userDir).appendingPathComponent("0/com.apple.notificationcenter/db2/db")
        return fm.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private static func app(_ bundleID: String) -> (String, String?) {
        if let cached = appCache[bundleID] { return cached }
        var result: (String, String?) = (bundleID.split(separator: ".").last.map(String.init) ?? bundleID, nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            result = (name, url.path)
        }
        appCache[bundleID] = result
        return result
    }

    static var lastError = ""

    static func read() -> [SystemNotification]? {
        guard let source = dbURL() else {
            lastError = "banco de notificações não encontrado"
            return nil
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("launcher-notificacoes-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        var copied = (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil
        var copyError = ""
        if copied {
            for suffix in ["", "-wal"] {
                let from = URL(fileURLWithPath: source.path + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                do {
                    let data = try Data(contentsOf: from)
                    try data.write(to: tmp.appendingPathComponent("db" + suffix))
                } catch {
                    if suffix.isEmpty {
                        copied = false
                        copyError = (error as NSError).localizedDescription
                    }
                }
            }
        }

        var db: OpaquePointer?
        let opened: Int32
        if copied {
            opened = sqlite3_open_v2(tmp.appendingPathComponent("db").path, &db, SQLITE_OPEN_READWRITE, nil)
        } else {
            opened = sqlite3_open_v2("file:" + source.path + "?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        }
        guard opened == SQLITE_OK else {
            if !copyError.isEmpty {
                lastError = "sem permissão para ler o banco: " + copyError
                sqlite3_close(db)
                return nil
            }
            lastError = "sqlite não abriu: " + String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT r.data, a.identifier, r.delivered_date, r.rec_id FROM record r LEFT JOIN app a ON a.app_id = r.app_id ORDER BY r.delivered_date DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            var tables: [String] = []
            var t: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &t, nil) == SQLITE_OK {
                while sqlite3_step(t) == SQLITE_ROW {
                    if let c = sqlite3_column_text(t, 0) { tables.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(t)
            lastError = "formato inesperado: " + String(cString: sqlite3_errmsg(db)) + " | tabelas: " + tables.joined(separator: ", ")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        lastError = ""
        var out: [SystemNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var bundleID = ""
            if let c = sqlite3_column_text(stmt, 1) { bundleID = String(cString: c) }
            let delivered = sqlite3_column_double(stmt, 2)
            var title = ""
            var subtitle = ""
            var body = ""
            if let blob = sqlite3_column_blob(stmt, 0) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
                if let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                    if bundleID.isEmpty, let a = plist["app"] as? String { bundleID = a }
                    if let req = plist["req"] as? [String: Any] {
                        title = req["titl"] as? String ?? ""
                        subtitle = req["subt"] as? String ?? ""
                        body = req["body"] as? String ?? ""
                    }
                }
            }
            if title.isEmpty && body.isEmpty { continue }
            let info = app(bundleID)
            out.append(SystemNotification(id: sqlite3_column_int64(stmt, 3), app: info.0, appPath: info.1, title: title, subtitle: subtitle, body: body,
                                          date: Date(timeIntervalSinceReferenceDate: delivered)))
        }
        return out
    }
}
