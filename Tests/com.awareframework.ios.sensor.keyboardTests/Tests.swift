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

    func testRawDataModeMasksKeyboardFields() {
        XCTAssertEqual(KeyboardRawDataMode.raw.maskedText("hello"), "hello")
        XCTAssertEqual(KeyboardRawDataMode.raw.maskedKey("a", eventType: "key"), "a")

        XCTAssertEqual(KeyboardRawDataMode.category.maskedText("hello"), "*")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey("a", eventType: "key"), "t")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey(" ", eventType: "key"), "s")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey("⌫", eventType: "key"), "d")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey("\n", eventType: "key"), "r")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey("word", eventType: "suggestion"), "p")
        XCTAssertEqual(KeyboardRawDataMode.category.maskedKey("SHIFT", eventType: "key"), "o")

        XCTAssertEqual(KeyboardRawDataMode.none.maskedText("hello"), "*")
        XCTAssertEqual(KeyboardRawDataMode.none.maskedKey("a", eventType: "key"), "*")
    }
}
