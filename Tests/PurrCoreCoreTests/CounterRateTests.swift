import XCTest
@testable import PurrCoreCore

final class CounterRateTests: XCTestCase {
    func testConvertsCumulativeCountersToPerSecondRates() {
        var calculator = CounterRateCalculator()
        XCTAssertEqual(calculator.update(downloadTotal: 1_000, uploadTotal: 500, timestamp: 10), .zero)

        let rate = calculator.update(downloadTotal: 3_000, uploadTotal: 1_500, timestamp: 12)

        XCTAssertEqual(rate.downloadBytesPerSecond, 1_000)
        XCTAssertEqual(rate.uploadBytesPerSecond, 500)
    }

    func testCounterResetDoesNotCreateNegativeRate() {
        var calculator = CounterRateCalculator()
        _ = calculator.update(downloadTotal: 10_000, uploadTotal: 10_000, timestamp: 10)

        XCTAssertEqual(calculator.update(downloadTotal: 100, uploadTotal: 200, timestamp: 11), .zero)
    }
}
