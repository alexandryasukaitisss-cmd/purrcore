import XCTest
@testable import PurrCoreCore

final class CatSpeedPolicyTests: XCTestCase {
    func testCatRunsFasterAsCPUUsageRises() {
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: 0), 0.20, accuracy: 0.0001)
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: 20), 0.176, accuracy: 0.0001)
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: 50), 0.14, accuracy: 0.0001)
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: 90), 0.092, accuracy: 0.0001)
    }

    func testCPUValueIsClampedBeforeSelectingSpeed() {
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: -50), 0.20, accuracy: 0.0001)
        XCTAssertEqual(CatSpeedPolicy.frameInterval(cpuPercent: 400), 0.08, accuracy: 0.0001)
    }
}
