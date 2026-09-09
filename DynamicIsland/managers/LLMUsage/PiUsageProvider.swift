import Foundation

struct PiUsageProvider: UsageProvider {
    let id: ProviderID = .pi
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/sessions")) {
        self.root = root
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("No ~/.pi/agent/sessions — Pi not detected")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UsageError.notFound("No Pi usage logs found")
        }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { throw UsageError.notFound("No Pi usage logs found") }
        return JSONLUsageParser.aggregate(files: files, now: now)
    }
}
