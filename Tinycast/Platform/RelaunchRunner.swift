import Foundation

/// `open` on a running bundle id only re-activates it, so the relaunch outlives us.
enum RelaunchRunner {
    static func relaunchAfterExit(_ bundleURL: URL, inBackground: Bool = false) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; "
                + "/usr/bin/open \(inBackground ? "-g " : "")'\(quoted)'"
        ]
        // Orphaned on our exit and reparented to launchd, which is the whole point.
        try? process.run()
    }
}
