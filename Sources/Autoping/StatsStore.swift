import AutopingCore
import Foundation

/// All-time statistics per host, kept as JSON in Application Support.
@MainActor
final class StatsStore {
    private var statsByHost: [String: StatCounter] = [:]
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Autoping", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("stats.json")

        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: StatCounter].self, from: data) {
            statsByHost = stored
        }
    }

    subscript(host: String) -> StatCounter {
        get { statsByHost[host.lowercased()] ?? StatCounter() }
        set { statsByHost[host.lowercased()] = newValue }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(statsByHost) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
