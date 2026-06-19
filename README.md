# AWARE: Keyboard

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)

This sensor module captures keystroke events from a custom iOS keyboard extension and persists them to a local SQLite database. Because iOS keyboard extensions run in a sandboxed process, events are bridged to the host app through a shared App Group `UserDefaults` container and then flushed by `KeyboardSensor`.

## Requirements

- iOS 16 or later
- An Apple Developer account (required to create App Groups)

## Installation

1. Open Package Manager in Xcode
    * `File` → `Add Package Dependencies…`

2. Enter the repository URL
    * `https://github.com/awareframework/com.awareframework.ios.sensor.keyboard.git`

3. Add the package to your **app target** (not the keyboard extension target).

## Setup

Because iOS keyboard extensions run in a separate process, data must be exchanged through an App Group shared container.

### 1. Create an App Group

In the [Apple Developer portal](https://developer.apple.com/account), create an App Group identifier such as:

```
group.com.yourorganization.aware
```

### 2. Enable the entitlement in both targets

In Xcode, add the **App Groups** capability to both your **host app target** and your **keyboard extension target**, then select (or add) the same App Group identifier.

### 3. Add a Keyboard Extension target

Add a new **Custom Keyboard Extension** target to your Xcode project if you do not already have one.

### 4. Subclass KeyboardInputViewController

In the keyboard extension target, subclass `KeyboardInputViewController` and set `appGroupIdentifier` before calling `super.viewDidLoad()`:

```swift
import com_awareframework_ios_sensor_keyboard

class KeyboardViewController: KeyboardInputViewController {
    override func viewDidLoad() {
        appGroupIdentifier = "group.com.yourorganization.aware"
        super.viewDidLoad()
    }
}
```

### 5. Configure and start KeyboardSensor in the host app

```swift
import com_awareframework_ios_sensor_keyboard

let sensor = KeyboardSensor(KeyboardSensor.Config().apply { config in
    config.appGroupIdentifier = "group.com.yourorganization.aware"
    config.rawDataMode = .category
    config.sensorObserver = self  // optional
    config.debug = true
})

sensor.start()
```

## Public Functions

### KeyboardSensor

+ `init(_ config: KeyboardSensor.Config)`: — Initializes the sensor with the given configuration.
+ `start()`: — Starts periodic flushing of keystroke events from the shared container to SQLite.
+ `stop()`: Stops the sensor and removes all observers.
+ `sync(force: Bool)`: Uploads stored data to the configured remote host.
+ `set(label: String)`: Attaches a label to subsequently recorded events.

### KeyboardSensor.Config

Class to hold the configuration of the sensor.

#### Fields

+ `appGroupIdentifier: String`: App Group ID shared with the keyboard extension. **Required.** (default = `""`)
+ `rawDataMode: KeyboardRawDataMode`: Controls how text and key values are stored. (default = `.raw`)
+ `sensorObserver: KeyboardObserver?`: Callback for live keystroke events. (default = `nil`)
+ `debug: Bool`: Enables verbose logging. (default = `false`)
+ `label: String`: Label attached to recorded data. (default = `""`)
+ `deviceId: String`: AWARE device UUID. (default = `auto`)
+ `dbEncryptionKey: String?`: Encryption key for the SQLite database. (default = `nil`)
+ `dbType: DatabaseType`: Database engine type. (default = `.none`)
+ `dbPath: String`: SQLite database file path. (default = `"aware_keyboard"`)
+ `dbHost: String?`: Remote host for data sync. (default = `nil`)

### Raw Data Modes

`KeyboardSensor.Config.rawDataMode` controls whether raw text is stored in SQLite and in uploaded payloads.

| Mode | `beforeText` / `currentText` | `key` | Use case |
|------|-------------------------------|-------|----------|
| `.raw` | Raw text | Raw key value | Full debugging or studies that explicitly require text content. |
| `.category` | `"*"` | Category code | Behavioral analysis without storing typed content. |
| `.none` | `"*"` | `"*"` | Store only timing, password flag, and event type. |

Category mode stores `key` as one of the following codes:

| Code | Meaning |
|------|---------|
| `t` | Text character |
| `s` | Space |
| `d` | Delete / backspace |
| `r` | Return / enter |
| `e` | Emoji |
| `p` | Prediction / suggestion selection |
| `o` | Other special key |

### KeyboardObserver

Implement this protocol to receive live keystroke callbacks:

```swift
class Observer: KeyboardObserver {
    func onKeyboardEvent(data: KeyboardData) {
        print(data.currentText)
    }
}
```

### KeyboardInputViewController

Open base class for the custom keyboard extension target. Provides a full QWERTY layout with letter, number, and symbol modes. Override `viewDidLoad()` to set `appGroupIdentifier` before calling `super`.

## Broadcasts

### Fired Broadcasts

| Notification | When |
|---|---|
| `actionAwareKeyboard` | One or more keystroke events were flushed to the database. |
| `actionAwareKeyboardStart` | Sensor started. |
| `actionAwareKeyboardStop` | Sensor stopped. |
| `actionAwareKeyboardSync` | Sync was requested. |
| `actionAwareKeyboardSyncCompletion` | Sync finished. `userInfo` contains `status` (Bool) and `error` (Error?) keys. |

### Received Broadcasts

| Notification | Effect |
|---|---|
| `actionAwareKeyboardStart` | Starts the sensor (same as calling `start()`). |
| `actionAwareKeyboardStop` | Stops the sensor (same as calling `stop()`). |
| `actionAwareKeyboardSync` | Triggers a sync attempt. |
| `actionAwareKeyboardSetLabel` | Updates the data label. Expects `KeyboardSensor.EXTRA_LABEL` in `userInfo`. |

## Data Representations

### KeyboardData

| Field | Type | Description |
|-------|------|-------------|
| `id` | `Int64?` | Auto-incremented database row ID. |
| `timestamp` | `Int64` | Unix time in milliseconds since epoch. |
| `deviceId` | `String` | AWARE device UUID. |
| `label` | `String` | Customizable label for calibration or traceability. |
| `packageName` | `String` | Bundle ID of the host app (empty — iOS extensions cannot reliably obtain it). |
| `beforeText` | `String` | Text in the input field immediately before this keystroke (blank for password fields). |
| `currentText` | `String` | Text in the input field immediately after this keystroke (blank for password fields). |
| `isPassword` | `Int` | `1` if the field is a secure/password field, `0` otherwise. |
| `key` | `String` | Key value or masked/category value depending on `rawDataMode`. |
| `eventType` | `String` | Event kind, such as `"key"`, `"long_press_start"`, `"long_press_repeat"`, `"long_press_end"`, or `"suggestion"`. |
| `timezone` | `Int` | Device timezone offset. |
| `os` | `String` | Operating system (`"iOS"`). |
| `jsonVersion` | `Int` | Schema version. |

## Example Usage

```swift
import UIKit
import com_awareframework_ios_sensor_keyboard

class AppDelegate: UIResponder, UIApplicationDelegate, KeyboardObserver {

    var sensor: KeyboardSensor?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        sensor = KeyboardSensor(KeyboardSensor.Config().apply { config in
            config.appGroupIdentifier = "group.com.yourorganization.aware"
            config.rawDataMode = .category
            config.sensorObserver = self
            config.debug = true
        })
        sensor?.start()
        return true
    }

    // MARK: - KeyboardObserver

    func onKeyboardEvent(data: KeyboardData) {
        print("[Keyboard] before=\(data.beforeText) current=\(data.currentText) key=\(data.key) password=\(data.isPassword)")
    }
}
```

## Related Links

- [Creating a custom keyboard | Apple Developer Documentation](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)
- [UIInputViewController | Apple Developer Documentation](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)
- [UIInputViewAudioFeedback | Apple Developer Documentation](https://developer.apple.com/documentation/uikit/uiinputviewaudiofeedback)
- [App Groups Entitlement | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)

## Author

Yuuki Nishiyama (The University of Tokyo), nishiyama@csis.u-tokyo.ac.jp

## License

Copyright (c) 2018 AWARE Mobile Context Instrumentation Middleware/Framework (http://www.awareframework.com)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
