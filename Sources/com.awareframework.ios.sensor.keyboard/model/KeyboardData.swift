import Foundation
import GRDB
import com_awareframework_ios_core

private func escapeSqlJsonString(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: "\\n")
     .replacingOccurrences(of: "\r", with: "\\r")
}

/// Shared key for pending events in App Group UserDefaults.
/// Used by KeyboardInputViewController (extension side) and KeyboardSensor (app side).
public enum KeyboardSharedKeys {
    public static let pendingEvents      = "com.awareframework.keyboard.pending_events"
    public static let lastFullAccessDate = "com.awareframework.keyboard.last_full_access_date"
    public static let rawDataMode        = "com.awareframework.keyboard.raw_data_mode"
}

public enum KeyboardRawDataMode: String, CaseIterable, Codable {
    case raw
    case category
    case none

    public static func fromSharedDefaults(_ defaults: UserDefaults) -> KeyboardRawDataMode {
        if let rawValue = defaults.string(forKey: KeyboardSharedKeys.rawDataMode),
           let mode = KeyboardRawDataMode(rawValue: rawValue) {
            return mode
        }
        return .raw
    }

    public func maskedText(_ value: String) -> String {
        self == .raw ? value : "*"
    }

    public func maskedKey(_ key: String, eventType: String) -> String {
        switch self {
        case .raw:
            return key
        case .none:
            return "*"
        case .category:
            return Self.keyCategory(key, eventType: eventType)
        }
    }

    private static func keyCategory(_ key: String, eventType: String) -> String {
        if eventType == "suggestion" {
            return "p"
        }

        switch key {
        case " ", "SPACE", "space":
            return "s"
        case "⌫", "DELETE", "BACKSPACE", "delete", "backspace":
            return "d"
        case "\n", "\r", "RETURN", "ENTER", "return", "enter":
            return "r"
        default:
            if key.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji }) {
                return "e"
            }
            return key.count == 1 ? "t" : "o"
        }
    }
}

/// One keyboard event. Core fields mirror the AWARE Android keyboard sensor schema:
/// package_name, before_text, current_text, is_password.
public struct KeyboardData: BaseDbModelSQLite {
    public static let databaseTableName = "ios_keyboard"
    public static let TABLE_NAME = databaseTableName

    public var id: Int64?
    public var timestamp: Int64
    public var deviceId: String = AwareUtils.getCommonDeviceId()
    public var label: String = ""
    public var timezone: Int = AwareUtils.getTimeZone()
    public var os: String = "iOS"
    public var jsonVersion: Int = 1

    /// Bundle ID of the host app where the keyboard was used.
    /// iOS keyboard extensions cannot reliably obtain this; stored as empty string when unavailable.
    public var packageName: String = ""

    /// Text in the input field immediately before this keystroke (blank for password fields).
    public var beforeText: String = ""

    /// Text in the input field immediately after this keystroke (blank for password fields).
    public var currentText: String = ""

    /// 1 if the input field is a password/secure field, 0 otherwise.
    public var isPassword: Int = 0

    /// Key associated with this event, when known. Examples: "a", "SPACE", "⌫".
    public var key: String = ""

    /// Event kind. Examples: "key", "long_press_start", "long_press_repeat", "long_press_end".
    public var eventType: String = "key"

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        label: String = ""
    ) {
        self.timestamp = timestamp
        self.label = label
    }

    public init(_ dict: [String: Any]) {
        self.id          = dict["id"] as? Int64
        self.timestamp   = dict["timestamp"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
        self.deviceId    = dict["deviceId"] as? String ?? AwareUtils.getCommonDeviceId()
        self.label       = dict["label"] as? String ?? ""
        self.packageName = dict["packageName"] as? String ?? ""
        self.beforeText  = dict["beforeText"] as? String ?? ""
        self.currentText = dict["currentText"] as? String ?? ""
        self.isPassword  = dict["isPassword"] as? Int ?? 0
        self.key         = dict["key"] as? String ?? ""
        self.eventType   = dict["eventType"] as? String ?? "key"
    }

    public func toDictionary() -> [String: Any] {
        [
            "id":          id ?? -1,
            "timestamp":   timestamp,
            "deviceId":    deviceId,
            "label":       label,
            "packageName": packageName,
            "beforeText":  escapeSqlJsonString(beforeText),
            "currentText": escapeSqlJsonString(currentText),
            "isPassword":  isPassword,
            "key":         key,
            "eventType":   eventType,
            "os":          os,
            "timezone":    timezone,
            "jsonVersion": jsonVersion,
        ]
    }

    public static func createTable(queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp",   .integer).notNull()
                t.column("deviceId",    .text).notNull()
                t.column("label",       .text).notNull()
                t.column("packageName", .text).notNull()
                t.column("beforeText",  .text).notNull()
                t.column("currentText", .text).notNull()
                t.column("isPassword",  .integer).notNull()
                t.column("key",         .text).notNull()
                t.column("eventType",   .text).notNull()
                t.column("os",          .text).notNull()
                t.column("timezone",    .integer).notNull()
                t.column("jsonVersion", .integer).notNull()
            }
            try migrateColumnsIfNeeded(db)
        }
    }

    private static func migrateColumnsIfNeeded(_ db: Database) throws {
        let columns = Set(try db.columns(in: databaseTableName).map(\.name))
        if columns.contains("key") == false {
            try db.alter(table: databaseTableName) { t in
                t.add(column: "key", .text).notNull().defaults(to: "")
            }
        }
        if columns.contains("eventType") == false {
            try db.alter(table: databaseTableName) { t in
                t.add(column: "eventType", .text).notNull().defaults(to: "key")
            }
        }
    }
}
