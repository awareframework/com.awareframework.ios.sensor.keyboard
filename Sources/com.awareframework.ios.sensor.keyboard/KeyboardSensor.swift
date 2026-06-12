import UIKit
import com_awareframework_ios_core

extension Notification.Name {
    public static let actionAwareKeyboard = Notification.Name(KeyboardSensor.ACTION_AWARE_KEYBOARD)
    public static let actionAwareKeyboardStart = Notification.Name(KeyboardSensor.ACTION_AWARE_KEYBOARD_START)
    public static let actionAwareKeyboardStop = Notification.Name(KeyboardSensor.ACTION_AWARE_KEYBOARD_STOP)
    public static let actionAwareKeyboardSync = Notification.Name(KeyboardSensor.ACTION_AWARE_KEYBOARD_SYNC)
    public static let actionAwareKeyboardSetLabel = Notification.Name(KeyboardSensor.ACTION_AWARE_KEYBOARD_SET_LABEL)
    public static let actionAwareKeyboardSyncCompletion = Notification.Name(
        KeyboardSensor.ACTION_AWARE_KEYBOARD_SYNC_COMPLETION)
}

public protocol KeyboardObserver {
    func onKeyboardEvent(data: KeyboardData)
}

/// Reads keystroke events produced by KeyboardInputViewController (keyboard extension)
/// from a shared App Group UserDefaults and persists them to SQLite.
///
/// Setup:
///   1. Register an App Group in the Apple Developer portal.
///   2. Add the App Group entitlement to both the host app target and the keyboard extension target.
///   3. Set CONFIG.appGroupIdentifier to that App Group ID.
///   4. In your keyboard extension, set KeyboardInputViewController.appGroupIdentifier to the same value.
public class KeyboardSensor: AwareSensor {

    public static let TAG = "AWARE::Keyboard"

    public static let ACTION_AWARE_KEYBOARD = "com.awareframework.ios.sensor.keyboard"
    public static let ACTION_AWARE_KEYBOARD_START =
        "com.awareframework.ios.sensor.keyboard.SENSOR_START"
    public static let ACTION_AWARE_KEYBOARD_STOP =
        "com.awareframework.ios.sensor.keyboard.SENSOR_STOP"
    public static let ACTION_AWARE_KEYBOARD_SET_LABEL =
        "com.awareframework.ios.sensor.keyboard.SET_LABEL"
    public static let EXTRA_LABEL = "label"
    public static let ACTION_AWARE_KEYBOARD_SYNC =
        "com.awareframework.ios.sensor.keyboard.SENSOR_SYNC"
    public static let ACTION_AWARE_KEYBOARD_SYNC_COMPLETION =
        "com.awareframework.ios.sensor.keyboard.SENSOR_SYNC_COMPLETION"
    public static let EXTRA_STATUS = "status"
    public static let EXTRA_ERROR = "error"

    public var CONFIG = Config()

    private var flushTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?

    public class Config: SensorConfig {
        public var sensorObserver: KeyboardObserver? = nil

        /// App Group identifier shared between the keyboard extension and this sensor.
        /// Example: "group.com.yourorganization.aware"
        public var appGroupIdentifier: String = ""
        public var rawDataMode: KeyboardRawDataMode = .raw

        public override init() {
            super.init()
            dbPath = "aware_keyboard"
        }

        public func apply(closure: (_ config: KeyboardSensor.Config) -> Void) -> Self {
            closure(self)
            return self
        }
    }

    public override convenience init() {
        self.init(KeyboardSensor.Config())
    }

    public init(_ config: KeyboardSensor.Config) {
        super.init()
        CONFIG = config
        initializeDbEngine(config: config)
        super.syncConfig = DbSyncConfig().apply { syncConfig in
            syncConfig.serverType = config.serverType
            syncConfig.debug = config.debug
            syncConfig.batchSize = 1000
            syncConfig.dispatchQueue = DispatchQueue(
                label: "com.awareframework.ios.sensor.keyboard.sync.queue")
            syncConfig.completionHandler = { [weak self] status, error in
                guard let self else { return }
                var userInfo: [String: Any] = [KeyboardSensor.EXTRA_STATUS: status]
                if let error { userInfo[KeyboardSensor.EXTRA_ERROR] = error }
                self.notificationCenter.post(
                    name: .actionAwareKeyboardSyncCompletion, object: self, userInfo: userInfo)
            }
        }
        initializeTables()
    }

    /// True if the keyboard extension has been granted "Allow Full Access" within the last 24 hours.
    /// Returns false if the App Group is not configured or the extension has never run with full access.
    public var hasFullAccess: Bool {
        guard !CONFIG.appGroupIdentifier.isEmpty,
              let defaults = UserDefaults(suiteName: CONFIG.appGroupIdentifier),
              let ts = defaults.object(forKey: KeyboardSharedKeys.lastFullAccessDate) as? TimeInterval
        else { return false }
        return Date().timeIntervalSince1970 - ts < 86_400  // valid within 24 hours
    }

    // MARK: - AwareSensor lifecycle

    public override func start() {
        guard !CONFIG.appGroupIdentifier.isEmpty else {
            if CONFIG.debug {
                print(KeyboardSensor.TAG, "appGroupIdentifier not configured — sensor will not start")
            }
            return
        }
        updateSharedRawDataPreference()

        // Flush any events that accumulated while the app was in the background.
        flushPendingEvents()

        // Periodic flush every 30 s while the app is foregrounded.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.flushPendingEvents()
        }

        // Also flush immediately when the user returns to the app.
        foregroundObserver = notificationCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingEvents()
        }

        notificationCenter.post(name: .actionAwareKeyboardStart, object: self)
        if CONFIG.debug { print(KeyboardSensor.TAG, "started") }
    }

    public override func stop() {
        flushTimer?.invalidate()
        flushTimer = nil

        if let observer = foregroundObserver {
            notificationCenter.removeObserver(observer)
            foregroundObserver = nil
        }

        notificationCenter.post(name: .actionAwareKeyboardStop, object: self)
        if CONFIG.debug { print(KeyboardSensor.TAG, "stopped") }
    }

    public override func sync(force: Bool = false) {
        guard let syncConfig = super.syncConfig else { return }
        notificationCenter.post(name: .actionAwareKeyboardSync, object: self)
        makeSyncEngine().startSync(syncConfig)
    }

    public override func set(label: String) {
        CONFIG.label = label
        notificationCenter.post(
            name: .actionAwareKeyboardSetLabel, object: self,
            userInfo: [KeyboardSensor.EXTRA_LABEL: label])
    }

    // MARK: - Shared container

    /// Reads all pending events from the App Group UserDefaults, saves them to SQLite,
    /// then clears the queue. Thread-safe: the clear happens before processing to prevent
    /// double-saving if the extension writes concurrently.
    func flushPendingEvents() {
        guard let defaults = UserDefaults(suiteName: CONFIG.appGroupIdentifier) else { return }
        updateSharedRawDataPreference()

        guard let raw = defaults.array(forKey: KeyboardSharedKeys.pendingEvents) as? [[String: Any]],
              !raw.isEmpty else { return }

        // Clear first to minimise duplicate risk from concurrent extension writes.
        defaults.removeObject(forKey: KeyboardSharedKeys.pendingEvents)
        defaults.synchronize()

        let events: [KeyboardData] = raw.map { dict in
            var data = KeyboardData(dict)
            data.label = CONFIG.label
            data.beforeText = CONFIG.rawDataMode.maskedText(data.beforeText)
            data.currentText = CONFIG.rawDataMode.maskedText(data.currentText)
            data.key = CONFIG.rawDataMode.maskedKey(data.key, eventType: data.eventType)
            return data
        }

        saveModels(events)

        for event in events {
            CONFIG.sensorObserver?.onKeyboardEvent(data: event)
            notificationCenter.post(name: .actionAwareKeyboard, object: self)
        }

        if CONFIG.debug { print(KeyboardSensor.TAG, "flushed \(events.count) event(s)") }
    }

    // MARK: - Private helpers

    private func initializeTables() {
        guard let queue = (dbEngine as? SQLiteEngine)?.getSQLiteInstance() else { return }
        do {
            try KeyboardData.createTable(queue: queue)
        } catch {
            if CONFIG.debug { print(KeyboardSensor.TAG, error) }
        }
    }

    private func saveModels(_ models: [KeyboardData]) {
        guard let engine = dbEngine as? SQLiteEngine else { return }
        engine.save(models)
    }

    private func updateSharedRawDataPreference() {
        guard !CONFIG.appGroupIdentifier.isEmpty,
              let defaults = UserDefaults(suiteName: CONFIG.appGroupIdentifier) else { return }
        defaults.set(CONFIG.rawDataMode.rawValue, forKey: KeyboardSharedKeys.rawDataMode)
        defaults.synchronize()
    }

    private func makeSyncEngine() -> Engine {
        Engine.Builder()
            .setPath(CONFIG.dbPath)
            .setType(CONFIG.dbType)
            .setHost(CONFIG.dbHost)
            .setEncryptionKey(CONFIG.dbEncryptionKey)
            .setTableName(KeyboardData.TABLE_NAME)
            .build()
    }
}
