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

    func testExplainsExpandedMacOSWebKitAndDeveloperProcesses() {
        let webkit = humanizer.describe(
            executableName: "com.apple.WebKit.WebContent",
            path: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        )
        XCTAssertEqual(webkit.displayName, "Веб‑страницы WebKit")
        XCTAssertEqual(webkit.category, .browser)

        let audio = humanizer.describe(executableName: "coreaudiod", path: "/usr/sbin/coreaudiod")
        XCTAssertEqual(audio.displayName, "Аудиосистема macOS")
        XCTAssertEqual(audio.category, .media)

        let swiftc = humanizer.describe(executableName: "swift-frontend", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend")
        XCTAssertEqual(swiftc.displayName, "Компилятор Swift")
        XCTAssertEqual(swiftc.category, .development)

        let py314 = humanizer.describe(executableName: "python3.14", path: "/opt/homebrew/bin/python3.14")
        XCTAssertEqual(py314.displayName, "Python")
        XCTAssertEqual(py314.groupKey, "process:python")
        XCTAssertEqual(py314.category, .development)

        let mainProcess = humanizer.describe(executableName: "Brave Browser", path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        let helperProcess = humanizer.describe(executableName: "Brave Browser Helper", path: "/Applications/Brave Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Brave Browser Helper")
        XCTAssertGreaterThan(mainProcess.explanationPriority, helperProcess.explanationPriority)
    }
}
