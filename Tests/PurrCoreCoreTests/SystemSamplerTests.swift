import XCTest
@testable import PurrCoreCore

final class SystemSamplerTests: XCTestCase {
    func testSamplesLiveMacMetricsAndProcesses() async {
        let sampler = SystemSampler()
        _ = await sampler.sample(includeProcesses: true)
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        let sample = await sampler.sample(includeProcesses: true)

        XCTAssertGreaterThan(sample.memory.totalBytes, 0)
        XCTAssertLessThanOrEqual(sample.memory.usedBytes, sample.memory.totalBytes)
        XCTAssertTrue((0...100).contains(sample.cpuPercent))
        XCTAssertGreaterThan(sample.processes.count, 0)
        XCTAssertGreaterThan(sample.processes.map(\.residentBytes).max() ?? 0, 0)
    }
}
