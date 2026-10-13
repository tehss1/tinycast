import Foundation

@main
struct UpdateInstallerTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = UpdateInstaller(
            bundleURL: directory.appendingPathComponent("Tinycast.app"),
            stagingDirectory: directory.appendingPathComponent("Updates"), token: nil)
        guard let version = AppVersion("0.11.19-composer.13") else { fatalError("invalid fixture version") }
        let release = AvailableRelease(
            version: version, tag: "v\(version)", notes: "Fixture",
            assetURL: URL(string: "https://example.invalid/never-download.zip")!,
            assetSize: 1, publishedAt: nil)
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            try await installer.install(release) { _ in
                fatalError("an already cancelled install must never enter a phase")
            }
        }
        task.cancel()
        do {
            try await task.value
            fatalError("a cancelled install must throw cancellation")
        } catch is CancellationError {
            precondition(!FileManager.default.fileExists(atPath: directory.path))
        }
        print("Cancelled installation performs no download or filesystem mutation.")
    }
}
