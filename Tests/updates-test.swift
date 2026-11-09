import CryptoKit
import Foundation
import Security

@main
@MainActor
struct UpdatesTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func guardsReleaseTriggers() {
        let now = Date(timeIntervalSince1970: 1000)
        func accepts(
            repository: String = "tehss1/tinycast", channel: ReleaseChannel = .stable,
            path: String = "/Applications/Tinycast.app", enabled: Bool = true,
            inFlight: Bool = false, lastAttempt: Date? = nil
        ) -> Bool {
            ReleaseUpdatePolicy.accepts(
                repository: repository, channel: channel, bundlePath: path, enabled: enabled,
                inFlight: inFlight, now: now, lastAttempt: lastAttempt)
        }
        expect(accepts(), "fork installed release accepts trigger")
        expect(!accepts(repository: "abue-ammar/tinycast"), "upstream ignores trigger")
        expect(!accepts(channel: .development), "Dev ignores trigger")
        expect(!accepts(channel: .beta), "beta ignores trigger")
        expect(!accepts(path: "/tmp/Tinycast.app"), "other copies ignore trigger")
        expect(!accepts(enabled: false), "opt out ignores trigger")
        expect(!accepts(inFlight: true), "duplicate trigger ignored")
        expect(!accepts(lastAttempt: now), "burst throttled")
        expect(accepts(lastAttempt: now.addingTimeInterval(-60)), "later check allowed")
        func canInstall(
            running: AppVersion? = AppVersion("0.12.1-composer.23"),
            candidate: AppVersion? = AppVersion("0.12.1-composer.24"),
            activity: UpdateActivity = UpdateActivity(), busy: Bool = false, visible: Bool = false
        ) -> Bool {
            ReleaseUpdatePolicy.canInstall(
                running: running, candidate: candidate, activity: activity,
                quickActionBusy: busy, hasVisibleWindows: visible)
        }
        expect(canInstall(), "newer release while idle")
        expect(!canInstall(running: nil), "unknown running version refused")
        expect(!canInstall(candidate: nil), "unknown candidate refused")
        expect(!canInstall(candidate: AppVersion("0.12.1-composer.23")), "equal refused")
        expect(!canInstall(candidate: AppVersion("0.12.1-composer.22")), "older refused")
        expect(!canInstall(busy: true), "generation delivery and pending save defer")
        expect(!canInstall(visible: true), "Composer Quick Action and other windows defer")
        let activities = [
            UpdateActivity(isExpandingSnippet: true), UpdateActivity(isRunningExtension: true),
            UpdateActivity(isUninstalling: true), UpdateActivity(isRecordingHotKey: true),
            UpdateActivity(isShowingDialog: true), UpdateActivity(isPaletteVisible: true)
        ]
        for activity in activities {
            expect(!canInstall(activity: activity), "every tracked interruption defers")
        }
        expect(canInstall(), "closing panels and completing work permits install")
    }

    static func manualTakeover() async {
        var ownerFinished = false
        let pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3600)) } catch {}
            ownerFinished = true
        }
        await UpdateManualOwnership.takeOver(from: pending)
        expect(pending.isCancelled && ownerFinished, "manual control cancels and awaits unattended owner")
        await UpdateManualOwnership.takeOver(from: nil)
        expect(!ReleaseUpdatePolicy.accepts(repository: "tehss1/tinycast", channel: .stable,
            bundlePath: "/Applications/Tinycast.app", enabled: true,
            inFlight: true, now: Date(), lastAttempt: nil),
            "second notification cannot restage an update already under way")
        for kind in UpdateWindowKind.allCases {
            expect(UpdateWindowKind.blocksUpdate([kind]) == (kind == .work),
                "only explicit work windows block")
        }
        expect(!UpdateWindowKind.blocksUpdate([.statusItemHost, .passiveHUD]),
            "status hosts and passive HUDs allow idle update")
        expect(UpdateWindowKind.blocksUpdate([.statusItemHost, .work, .passiveHUD]),
            "nonactivating work panel still blocks among passive windows")
    }

    static func main() async {
        await manualTakeover()
        guardsReleaseTriggers()
        parsesVersions()
        ordersVersions()
        roundTripsVersionsThroughJSON()
        derivesChannels()
        resolvesReleaseRepositories()
        rejectsRepositoryChanges()
        validatesCachedReleaseIdentity()
        picksNewestForChannel()
        picksTheZipThisMacCanRun()
        rejectsUnusableFeeds()
        tellsARefusalFromAnOutage()
        sendsTheTokenOnlyToGitHub()
        offersOnlyWhatIsWorthInstalling()
        picksTheSignatureBesideItsZip()
        refusesWhatNeitherTrustPathVouchesFor()
        verifiesTheReleaseSignature()
        blocksWhileBusy()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - AppVersion

    static func parsesVersions() {
        expect(AppVersion("0.2.1")?.description == "0.2.1", "parses a plain triple")
        expect(AppVersion("v0.2.1")?.description == "0.2.1", "strips the tag's leading v")
        expect(AppVersion(" 0.2.1 ")?.description == "0.2.1", "tolerates surrounding whitespace")
        expect(AppVersion("0.2.0-beta.42")?.beta == 42, "reads the beta counter")
        expect(AppVersion("0.2.0-beta.42")?.description == "0.2.0-beta.42", "round-trips a beta")
        expect(AppVersion("0.2.1-composer.7")?.composer == 7, "reads a Composer counter")
        expect(
            AppVersion("v0.2.1-composer.7")?.description == "0.2.1-composer.7",
            "round-trips a customized stable version")
        expect(AppVersion("0.2.1")?.isPrerelease == false, "a plain triple is not a prerelease")
        expect(AppVersion("0.2.0-beta.1")?.isPrerelease == true, "a beta is a prerelease")
        expect(
            AppVersion("0.2.1-composer.1")?.isPrerelease == false,
            "a customized stable build is not a prerelease")

        expect(AppVersion("0.2") == nil, "rejects a two-part version")
        expect(AppVersion("0.2.1.3") == nil, "rejects a four-part version")
        expect(AppVersion("0.2.x") == nil, "rejects a non-numeric field")
        expect(AppVersion("0.2.-1") == nil, "rejects a signed field")
        expect(AppVersion("0.2.0-alpha.1") == nil, "rejects a channel that never ships")
        expect(AppVersion("0.2.0-beta") == nil, "rejects a beta with no counter")
        expect(AppVersion("0.2.0-beta.x") == nil, "rejects a non-numeric beta counter")
        expect(AppVersion("0.2.1-composer") == nil, "rejects Composer without a counter")
        expect(AppVersion("0.2.1-composer.-1") == nil, "rejects a signed Composer counter")
        expect(AppVersion("0.2.1-composer.1.extra") == nil, "rejects extra Composer fields")
        expect(AppVersion("") == nil, "rejects an empty string")
        expect(AppVersion("nightly") == nil, "rejects a name")
    }

    static func ordersVersions() {
        func version(_ text: String) -> AppVersion {
            guard let parsed = AppVersion(text) else {
                fatalError("the ordering cases must all parse — \(text) did not")
            }
            return parsed
        }

        expect(version("1.10.0") > version("1.9.0"), "compares minor numerically, not lexically")
        expect(version("2.0.0") > version("1.99.99"), "major outranks everything below it")
        expect(version("0.2.1") > version("0.2.0"), "patch breaks a tie")
        expect(version("1.0.0") > version("1.0.0-beta.5"), "a release outranks its own prerelease")
        expect(
            version("1.0.0-composer.1") > version("1.0.0"),
            "a customized stable build outranks its official base")
        expect(
            version("1.0.0-composer.12") > version("1.0.0-composer.9"),
            "Composer counters compare numerically")
        expect(
            version("0.2.0-beta.10") > version("0.2.0-beta.9"),
            "beta counters compare numerically, not lexically")
        expect(version("0.3.0-beta.1") > version("0.2.9"), "a newer triple wins despite being beta")
        expect(version("0.2.1") == version("0.2.1"), "equal triples are equal")
        expect(
            version("0.2.0-beta.1") != version("0.2.0"),
            "a prerelease is never equal to its release")
    }

    static func roundTripsVersionsThroughJSON() {
        guard let original = AppVersion("0.2.0-beta.7"),
            let encoded = try? JSONEncoder().encode(original),
            let decoded = try? JSONDecoder().decode(AppVersion.self, from: encoded)
        else {
            failures += 1
            print("FAIL: a version survives the cache file")
            return
        }
        expect(decoded == original, "a version survives the cache file")
        expect(
            String(bytes: encoded, encoding: .utf8) == "\"0.2.0-beta.7\"",
            "and is stored as a readable string rather than a field bag")
        expect(
            (try? JSONDecoder().decode(AppVersion.self, from: Data("\"junk\"".utf8))) == nil,
            "a corrupt cached version fails to decode instead of defaulting")
    }

    // MARK: - ReleaseChannel

    static func derivesChannels() {
        let stable = ReleaseChannel(bundleID: "com.tinycast.app")
        let beta = ReleaseChannel(bundleID: "com.tinycast.app.beta")
        let dev = ReleaseChannel(bundleID: "com.tinycast.app.dev")

        expect(stable == .stable, "the stable bundle id is the stable channel")
        expect(beta == .beta, "the beta bundle id is the beta channel")
        expect(dev == .development, "the dev bundle id is a local build")
        expect(ReleaseChannel(bundleID: nil) == .development, "a missing bundle id never updates")

        expect(stable.updatesItself && beta.updatesItself, "both shipped channels update")
        expect(!dev.updatesItself, "a local build does not update itself")

        expect(stable.accepts(prerelease: false), "stable takes releases")
        expect(!stable.accepts(prerelease: true), "stable never crosses to a prerelease")
        expect(beta.accepts(prerelease: true), "beta takes prereleases")
        expect(!beta.accepts(prerelease: false), "beta never crosses to a stable release")
        expect(
            !dev.accepts(prerelease: true) && !dev.accepts(prerelease: false),
            "a local build accepts nothing at all")
    }

    // MARK: - ReleaseFeed

    static func resolvesReleaseRepositories() {
        expect(
            ReleaseFeed.repository(in: nil) == ReleaseFeed.fallbackRepository,
            "a build without a stamp keeps the fork release feed")
        expect(
            ReleaseFeed.repository(
                in: [ReleaseFeed.repositoryInfoKey: "example-fork/tinycast"])
                == "example-fork/tinycast",
            "a custom release can stamp its own repository into the app")
        expect(
            ReleaseFeed.repository(
                in: [ReleaseFeed.repositoryInfoKey: "  example-fork/tinycast  "])
                == "example-fork/tinycast",
            "surrounding whitespace is ignored")
        expect(
            ReleaseFeed.repository(
                in: [ReleaseFeed.repositoryInfoKey: "https://example.invalid/releases"])
                == ReleaseFeed.fallbackRepository,
            "a URL cannot escape the GitHub repository path")
        expect(
            ReleaseFeed.repository(
                in: [ReleaseFeed.repositoryInfoKey: "owner/repo/extra"])
                == ReleaseFeed.fallbackRepository,
            "only an owner and repository pair is accepted")
        expect(
            ReleaseFeed.repository(
                in: [ReleaseFeed.repositoryInfoKey: "$(TINYCAST_UPDATE_REPOSITORY)"])
                == ReleaseFeed.fallbackRepository,
            "an unresolved build setting keeps the fork feed")
        expect(
            ReleaseFeed.endpoint(for: "example-fork/tinycast").absoluteString
                == "https://api.github.com/repos/example-fork/tinycast/releases?per_page=20",
            "the selected repository owns the GitHub Releases endpoint")
    }

    static func rejectsRepositoryChanges() {
        let fork = "tehss1/tinycast"
        expect(
            ReleaseFeed.acceptsRepository(in: [ReleaseFeed.repositoryInfoKey: fork], expected: fork),
            "the fork installs an app that keeps its update repository")
        expect(
            !ReleaseFeed.acceptsRepository(
                in: [ReleaseFeed.repositoryInfoKey: ReleaseFeed.officialRepository], expected: fork),
            "an otherwise matching stock app cannot redirect the fork to upstream")
        expect(
            !ReleaseFeed.acceptsRepository(in: nil, expected: fork),
            "a fork refuses a downloaded app missing its repository stamp")
        expect(
            !ReleaseFeed.acceptsRepository(
                in: [ReleaseFeed.repositoryInfoKey: "$(TINYCAST_UPDATE_REPOSITORY)"], expected: fork),
            "a fork refuses an unresolved repository build setting")
        expect(
            ReleaseFeed.acceptsRepository(in: nil, expected: ReleaseFeed.officialRepository),
            "an official app still accepts historical official builds without a stamp")
    }

    static func validatesCachedReleaseIdentity() {
        guard let version = AppVersion("0.11.19-composer.12") else { fatalError("invalid fixture version") }
        let release = AvailableRelease(
            version: version, tag: "v\(version)",
            assetURL: URL(string: "https://api.github.com/repos/tehss1/tinycast/releases/assets/12")!,
            assetSize: 1, signatureURL: nil, publishedAt: nil)
        guard let encoded = try? JSONEncoder().encode(release),
            var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        else { fatalError("invalid fixture encoding") }
        expect(
            (try? JSONDecoder().decode(AvailableRelease.self, from: encoded)) == release,
            "valid cached release identity survives a round trip")
        for tag in ["../../victim", "v0.11.19-composer.13", "unrecognized"] {
            object["tag"] = tag
            guard let tampered = try? JSONSerialization.data(withJSONObject: object) else {
                fatalError("invalid fixture JSON")
            }
            expect(
                (try? JSONDecoder().decode(AvailableRelease.self, from: tampered)) == nil,
                "a cached tag cannot traverse paths or disagree with its validated version")
        }
    }

    /// Shaped like GitHub's `/releases` payload, down to the snake-cased keys.
    static func feed(_ entries: String...) -> Data {
        Data("[\(entries.joined(separator: ","))]".utf8)
    }

    static func entry(
        tag: String, prerelease: Bool, draft: Bool = false, assets: [String] = ["Tinycast-x.zip"]
    ) -> String {
        let list = assets.map {
            """
            {"name":"\($0)","size":1024,
             "url":"https://example.invalid/\($0)"}
            """
        }
        return """
            {"tag_name":"\(tag)","prerelease":\(prerelease),"draft":\(draft),
             "published_at":"2026-01-05T12:00:00Z",
             "assets":[\(list.joined(separator: ","))]}
            """
    }

    static func picksNewestForChannel() {
        let body = feed(
            entry(tag: "v0.2.0", prerelease: false),
            entry(tag: "v0.3.0", prerelease: false),
            entry(tag: "v0.4.0-beta.1", prerelease: true),
            entry(tag: "v0.4.0-beta.2", prerelease: true))

        let stable = ReleaseFeed.newest(from: body, channel: .stable, architecture: .appleSilicon)
        expect(stable?.version == AppVersion("0.3.0"), "stable takes the newest release")
        expect(stable?.tag == "v0.3.0", "and keeps the tag as published")
        expect(stable?.assetSize == 1024, "and the asset size, for the progress readout")
        expect(
            stable?.assetURL.absoluteString.hasSuffix(".zip") == true,
            "and selects the zip asset")
        expect(stable?.publishedAt != nil, "and parses the ISO-8601 timestamp")

        let beta = ReleaseFeed.newest(from: body, channel: .beta, architecture: .appleSilicon)
        expect(beta?.version == AppVersion("0.4.0-beta.2"), "beta takes the newest prerelease")
        let fork = feed(
            entry(tag: "v0.3.0", prerelease: false),
            entry(tag: "v0.3.0-composer.2", prerelease: false),
            entry(tag: "v0.3.0-composer.12", prerelease: false))
        expect(
            ReleaseFeed.newest(from: fork, channel: .stable, architecture: .appleSilicon)?.version
                == AppVersion("0.3.0-composer.12"),
            "the stable fork feed selects the newest Composer counter above its upstream base")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0-composer.13", prerelease: true)),
                channel: .beta, architecture: .appleSilicon) == nil,
            "a stable Composer version incorrectly marked prerelease is rejected")

        expect(
            ReleaseFeed.newest(from: body, channel: .development, architecture: .appleSilicon) == nil,
            "a local build is offered nothing, however new the feed is")
    }

    static func tellsARefusalFromAnOutage() {
        let body = Data("[]".utf8)
        func response(_ status: Int, authorized: Bool = false) -> ReleaseFeed.Response {
            ReleaseFeed.Response(status: status, data: body, authorized: authorized)
        }
        expect(response(200) == .body(body), "200 carries the feed")
        expect(response(401, authorized: true) == .refused, "a bad token is a refusal")
        expect(
            response(404, authorized: true) == .refused,
            "a repository hidden from the stored token is a refusal")
        expect(response(404) == .missing, "without a token a 404 never blames one")
        expect(response(403, authorized: true) == .refused, "a forbidden token is an access refusal")
        expect(response(403) == .refused, "403 alone does not prove a rate limit")
        expect(
            ReleaseFeed.Response(status: 403, data: body, authorized: true, rateLimitRemaining: "0")
                == .limited,
            "an exhausted primary quota is a rate limit")
        expect(
            ReleaseFeed.Response(status: 403, data: body, authorized: true,
                rateLimitRemaining: "10", retryAfter: "60") == .limited,
            "Retry-After identifies a secondary rate limit with quota remaining")
        expect(
            ReleaseFeed.Response(status: 403, data: body, authorized: true, rateLimitRemaining: "10")
                == .refused,
            "a permission failure with quota remaining is an access refusal")
        expect(response(429, authorized: true) == .limited, "a secondary rate limit reads the same")
        expect(response(503) == .unreachable, "a server error is an outage")
        expect(
            ReleaseFeed.repository(in: [ReleaseFeed.repositoryInfoKey: "../tinycast"])
                == ReleaseFeed.fallbackRepository,
            "a path-traversing repository is ignored")
        expect(
            ReleaseFeed.repository(in: [ReleaseFeed.repositoryInfoKey: "owné/tinycast"])
                == ReleaseFeed.fallbackRepository,
            "a repository outside GitHub's ASCII names is ignored")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0", prerelease: false, assets: ["Tinycast-0.3.0.zip"])),
                channel: .stable, architecture: .appleSilicon)?.assetURL.absoluteString
                == "https://example.invalid/Tinycast-0.3.0.zip",
            "the asset is fetched from its API address")
    }

    static func rejectsUnusableFeeds() {
        expect(
            ReleaseFeed.newest(from: Data(), channel: .stable, architecture: .appleSilicon) == nil,
            "an empty body yields nil")
        expect(
            ReleaseFeed.newest(
                from: Data("not json".utf8), channel: .stable, architecture: .appleSilicon) == nil,
            "a malformed body yields nil rather than throwing")
        expect(
            ReleaseFeed.newest(from: feed(), channel: .stable, architecture: .appleSilicon) == nil,
            "an empty feed yields nil")

        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0", prerelease: false, draft: true)), channel: .stable,
                architecture: .appleSilicon) == nil,
            "a draft is not installable")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0", prerelease: false, assets: [])), channel: .stable,
                architecture: .appleSilicon) == nil,
            "a release with no assets is skipped")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0", prerelease: false, assets: ["Tinycast-x.dmg"])),
                channel: .stable, architecture: .appleSilicon) == nil,
            "a DMG-only release is not installable, so it is not offered")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "nightly", prerelease: false)), channel: .stable,
                architecture: .appleSilicon) == nil,
            "an unparseable tag is skipped")
        expect(
            ReleaseFeed.newest(
                from: feed(entry(tag: "v0.3.0-beta.1", prerelease: false)), channel: .stable,
                architecture: .appleSilicon) == nil,
            "a beta tag flagged as a release is mis-published, not an update")

        let mixed = feed(
            entry(tag: "v0.3.0", prerelease: false), entry(tag: "junk", prerelease: false))
        expect(
            ReleaseFeed.newest(from: mixed, channel: .stable, architecture: .appleSilicon)?.version
                == AppVersion("0.3.0"),
            "one bad entry does not discard the whole feed")
    }

    /// Stable carries a thin arm64 zip and a universal one; each Mac gets what it runs.
    static func picksTheZipThisMacCanRun() {
        let both = feed(
            entry(
                tag: "v0.3.0", prerelease: false,
                assets: ["Tinycast-0.3.0.zip", "Tinycast-Universal-0.3.0.zip"]))
        expect(
            ReleaseFeed.newest(from: both, channel: .stable, architecture: .intel)?
                .assetURL.absoluteString.contains("-Universal-") == true,
            "Intel takes the universal zip, the only one with an x86_64 slice")
        expect(
            ReleaseFeed.newest(from: both, channel: .stable, architecture: .appleSilicon)?
                .assetURL.absoluteString.contains("-Universal-") == false,
            "Apple silicon prefers the thin zip, and never pays for the Intel slice")

        let thinOnly = feed(entry(tag: "v0.3.0", prerelease: false, assets: ["Tinycast-0.3.0.zip"]))
        expect(
            ReleaseFeed.newest(from: thinOnly, channel: .stable, architecture: .intel) == nil,
            "Intel is offered nothing rather than an arm64 build it cannot launch")

        let universalOnly = feed(
            entry(tag: "v0.3.0", prerelease: false, assets: ["Tinycast-Universal-0.3.0.zip"]))
        expect(
            ReleaseFeed.newest(from: universalOnly, channel: .stable, architecture: .appleSilicon)?
                .version == AppVersion("0.3.0"),
            "Apple silicon falls back to the universal zip when it is the only one published")
    }

    static func sendsTheTokenOnlyToGitHub() {
        let asset = URL(string: "https://api.github.com/repos/o/r/releases/assets/1")!
        expect(ReleaseFeed.acceptsToken(asset), "the API's asset address may carry the token")
        expect(
            !ReleaseFeed.acceptsToken(URL(string: "http://api.github.com/repos/o/r/releases/assets/1")!),
            "a cleartext address never carries the token")
        expect(
            !ReleaseFeed.acceptsToken(URL(string: "https://api.github.com.example.invalid/a.zip")!),
            "a host merely starting with GitHub's never carries the token")
        expect(
            !ReleaseFeed.acceptsToken(URL(string: "https://example.invalid/a.zip")!),
            "another host never carries the token")
        func redirected(_ url: String) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            return ReleaseFeed.redirectedRequest(request, from: asset)
        }
        expect(
            redirected("https://api.github.com/repos/new/repo/releases")
                .value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
            "a same-host HTTPS feed redirect retains authentication")
        expect(
            redirected("https://objects.githubusercontent.com/signed.zip")
                .value(forHTTPHeaderField: "Authorization") == nil,
            "feed and download redirects to signed storage remove authentication")
        expect(
            redirected("http://api.github.com/repos/o/r/releases")
                .value(forHTTPHeaderField: "Authorization") == nil,
            "an HTTPS downgrade removes authentication even on the original host")
    }

    static func offersOnlyWhatIsWorthInstalling() {
        let running = AppVersion("0.2.0")!
        let newer = AvailableRelease(
            version: AppVersion("0.3.0")!, tag: "v0.3.0",
            assetURL: URL(string: "https://example.invalid/a.zip")!, assetSize: 1,
            signatureURL: nil, publishedAt: nil)
        let same = AvailableRelease(
            version: running, tag: "v0.2.0",
            assetURL: URL(string: "https://example.invalid/a.zip")!, assetSize: 1,
            signatureURL: nil, publishedAt: nil)

        expect(
            ReleaseFeed.offer(newer, running: running)?.version == newer.version,
            "a newer release is offered")
        expect(
            ReleaseFeed.offer(same, running: running) == nil,
            "the running version is not an update")
        expect(
            ReleaseFeed.offer(nil, running: running) == nil,
            "nothing in the feed offers nothing")
        expect(
            ReleaseFeed.offer(newer, running: AppVersion("0.4.0")!) == nil,
            "an older release never downgrades a newer install")
    }

    static func picksTheSignatureBesideItsZip() {
        let signed = feed(
            entry(
                tag: "v1.0.0", prerelease: false,
                assets: [
                    "Tinycast-1.0.0.dmg", "Tinycast-1.0.0.zip", "Tinycast-1.0.0.zip.sig",
                    "Tinycast-Universal-1.0.0.zip", "Tinycast-Universal-1.0.0.zip.sig"
                ]))
        expect(
            ReleaseFeed.newest(from: signed, channel: .stable, architecture: .appleSilicon)?
                .signatureURL?.lastPathComponent == "Tinycast-1.0.0.zip.sig",
            "the thin zip carries its own signature")
        expect(
            ReleaseFeed.newest(from: signed, channel: .stable, architecture: .intel)?
                .signatureURL?.lastPathComponent == "Tinycast-Universal-1.0.0.zip.sig",
            "and the universal zip carries the universal one")

        let unsigned = feed(entry(tag: "v1.0.0", prerelease: false, assets: ["Tinycast-1.0.0.zip"]))
        let release = ReleaseFeed.newest(from: unsigned, channel: .stable, architecture: .appleSilicon)
        expect(
            release != nil && release?.signatureURL == nil,
            "a release without a signature is still offered, for the identity path to judge")
    }

    static func refusesWhatNeitherTrustPathVouchesFor() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            BundleSignature.developerID as CFString, [], &requirement)
        expect(
            status == errSecSuccess && requirement != nil,
            "the Developer ID requirement compiles, or the release key would trust nothing")

        let apple = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        expect(
            BundleSignature.trustedHash(of: apple, releaseSigned: true) == nil,
            "the release key alone never trusts a bundle outside Developer ID")
        expect(
            BundleSignature.trustedHash(of: apple, releaseSigned: false) == nil,
            "without the key, a bundle signed by another identity is refused")
        expect(
            BundleSignature.trustedHash(of: URL(fileURLWithPath: "/nonexistent.app"), releaseSigned: true)
                == nil,
            "and nothing is trusted without a seal to check")
    }

    static func verifiesTheReleaseSignature() {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("an update archive".utf8)
        guard let raw = try? key.signature(for: archive) else {
            expect(false, "a fresh key signs")
            return
        }
        let signature = Data(raw.base64EncodedString().utf8)
        let verify = { (data: Data, signature: Data, key: Curve25519.Signing.PublicKey) in
            UpdateSignature.isSigned(data, by: signature, key: key)
        }

        expect(verify(archive, signature, key.publicKey), "a matching signature verifies")
        expect(
            verify(archive, signature + Data("\n".utf8), key.publicKey),
            "a trailing newline in the .sig asset is tolerated")
        expect(
            !verify(Data("a tampered archive".utf8), signature, key.publicKey),
            "an altered archive fails")
        expect(
            !verify(archive, signature, Curve25519.Signing.PrivateKey().publicKey),
            "another key fails")
        expect(!verify(archive, Data("not base64".utf8), key.publicKey), "a garbled signature fails")
    }

    // MARK: - UpdateReadiness

    static func blocksWhileBusy() {
        expect(UpdateReadiness.evaluate(UpdateActivity()) == nil, "an idle app can be interrupted")

        var busy = UpdateActivity()
        busy.isPaletteVisible = true
        expect(UpdateReadiness.evaluate(busy) == .paletteOpen, "an open palette blocks an interruption")

        busy = UpdateActivity()
        busy.isShowingDialog = true
        expect(UpdateReadiness.evaluate(busy) == .dialogOpen, "an open dialog blocks an interruption")

        busy = UpdateActivity()
        busy.isRecordingHotKey = true
        expect(UpdateReadiness.evaluate(busy) == .recordingHotKey, "a live recorder blocks an interruption")

        busy = UpdateActivity()
        busy.isUninstalling = true
        expect(UpdateReadiness.evaluate(busy) == .uninstalling, "a running uninstall blocks an interruption")

        busy = UpdateActivity()
        busy.isRunningExtension = true
        expect(
            UpdateReadiness.evaluate(busy) == .runningExtension,
            "a running extension command blocks an interruption")

        busy = UpdateActivity()
        busy.isExpandingSnippet = true
        expect(
            UpdateReadiness.evaluate(busy) == .expandingSnippet,
            "a snippet mid-expansion blocks an interruption")

        // Everything at once: the report names the one that would lose work, not the topmost panel.
        busy = UpdateActivity()
        busy.isPaletteVisible = true
        busy.isShowingDialog = true
        busy.isExpandingSnippet = true
        expect(
            UpdateReadiness.evaluate(busy) == .expandingSnippet,
            "the costliest interruption is the one reported")
    }
}
