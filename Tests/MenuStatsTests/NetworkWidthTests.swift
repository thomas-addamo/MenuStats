import XCTest
@testable import MenuStats

final class NetworkWidthTests: XCTestCase {
    /// Network rates change length every second ("0B", "1.4K", "135K", "120M"). Even with "Larghezza che si adatta
    /// al valore" on, the network module keeps one width, or the whole menu bar would shift at every sample.
    func testNetworkKeepsOneWidthWhateverTheRate() {
        let rates: [Double] = [0, 1_400, 135_000, 5_200_000, 120_000_000, 999_000_000, 2_500_000_000]
        for dynamicWidth in [true, false] {
            for showLabels in [true, false] {
                for style in NetworkStyle.allCases {
                    var options = MenubarOptions(Settings.shared)
                    options.dynamicWidth = dynamicWidth
                    options.showLabels = showLabels
                    options.networkStyle = style
                    let widths = Set(rates.map { rate -> CGFloat in
                        var snapshot = Snapshot()
                        snapshot.network = NetworkStats(interface: "en0", ipAddress: nil, downloadRate: rate, uploadRate: rate / 3,
                                                        totalDownloaded: 0, totalUploaded: 0)
                        let context = MenubarRenderer.Context(snapshot: snapshot, options: options, recent: { _, count in
                            Array(repeating: rate, count: count) })
                        return MenubarRenderer.segment(for: .network, context: context).width
                    })
                    XCTAssertEqual(widths.count, 1, "\(style), labels \(showLabels), dynamic \(dynamicWidth): \(widths.sorted())")
                }
            }
        }
    }
}
