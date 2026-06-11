import XCTest
@testable import com_awareframework_ios_sensor_keyboard

final class KeyboardDataTests: XCTestCase {

    func testKeyboardDataRoundTrip() {
        var data = KeyboardData()
        data.packageName = "com.example.app"
        data.beforeText  = "hello"
        data.currentText = "hello "
        data.isPassword  = 0
        data.key         = "SPACE"
        data.eventType   = "key"

        let dict = data.toDictionary()
        let restored = KeyboardData(dict)

        XCTAssertEqual(restored.packageName, data.packageName)
        XCTAssertEqual(restored.beforeText,  data.beforeText)
        XCTAssertEqual(restored.currentText, data.currentText)
        XCTAssertEqual(restored.isPassword,  data.isPassword)
        XCTAssertEqual(restored.key,         data.key)
        XCTAssertEqual(restored.eventType,   data.eventType)
    }

    func testLongPressEventRoundTrip() {
        var data = KeyboardData()
        data.key = "⌫"
        data.eventType = "long_press_start"

        let restored = KeyboardData(data.toDictionary())

        XCTAssertEqual(restored.key, "⌫")
        XCTAssertEqual(restored.eventType, "long_press_start")
    }

    func testPasswordFieldBlanksText() {
        var data = KeyboardData()
        data.beforeText  = ""
        data.currentText = ""
        data.isPassword  = 1

        XCTAssertTrue(data.beforeText.isEmpty)
        XCTAssertTrue(data.currentText.isEmpty)
        XCTAssertEqual(data.isPassword, 1)
    }
}
