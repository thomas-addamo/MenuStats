import XCTest
@testable import MenuStats

final class NetworkProcessReaderTests: XCTestCase {
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// Closing the Network tab stops nettop; its pipe then reaches end of file. The reader must stop listening,
    /// or the read handler fires in a loop and keeps a core busy until the app quits.
    func testStoppingDoesNotKeepReadingTheClosedPipe() {
        let reader = NetworkProcessReader()
        for _ in 0..<3 {
            reader.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            reader.stop()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let before = cpuSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let used = cpuSeconds() - before
        XCTAssertLessThan(used, 0.2, "MenuStats used \(used) s of CPU in 2 s with nothing to read")
    }
}
