import XCTest
@testable import PurrCoreCore

final class ProcessHumanizerTests: XCTestCase {
    private let humanizer = ProcessHumanizer()

    func testGroupsRendererHelperUnderOuterApplication() {
        let result = humanizer.describe(
            executableName: "Brave Browser Helper (Renderer)",
            path: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/Current/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
        )

        XCTAssertEqual(result.displayName, "Brave Browser")
        XCTAssertEqual(result.groupKey, "app:brave-browser")
        XCTAssertEqual(result.category, .browser)
        XCTAssertEqual(result.explanation, "вкладки и веб‑контент")
    }

    func testExplainsKnownSystemDaemons() {
        let spotlight = humanizer.describe(executableName: "mdworker_shared", path: "/System/Library/Frameworks/CoreSpotlight.framework/mdworker_shared")
        let windowServer = humanizer.describe(executableName: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")

        XCTAssertEqual(spotlight.displayName, "Индексация Spotlight")
        XCTAssertEqual(spotlight.category, .system)
        XCTAssertEqual(windowServer.displayName, "Окна и графика macOS")
        XCTAssertEqual(windowServer.explanation, "отрисовка окон и экранов")
    }

    func testNormalizesAIApplicationHelpers() {
        let result = humanizer.describe(executableName: "Codex Helper (Renderer)", path: "")

        XCTAssertEqual(result.displayName, "Codex")
        XCTAssertEqual(result.groupKey, "process:codex")
        XCTAssertEqual(result.category, .ai)
    }
}
