import Foundation
import Sparkle
import Testing
@testable import CmuxUpdater

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6292: tagged DEV and
/// staging builds are produced from local source and are not on the public release train, so
/// they must never surface Sparkle's "Update Available" pill from the public appcast.
@MainActor
@Suite struct DevStagingUpdateGatingTests {
    /// The bug: `didFindValidUpdate` recorded the update for every bundle id, surfacing the pill
    /// on DEV/staging builds. A DEV/staging-gated driver must clear the detected update instead.
    @Test func devLikeBundleClearsDetectedUpdateInsteadOfRecording() throws {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: true
        )

        let item = try #require(makeAppcastItem(version: "0.64.99"))
        driver.handleDidFindValidUpdate(item)

        #expect(model.detectedUpdateVersion == nil)
        #expect(!model.showsPill)
    }

    /// The public release train still records the detected update so the passive pill works.
    @Test func publicBundleRecordsDetectedUpdate() throws {
        let model = UpdateStateModel()
        let driver = UpdateDriver(
            model: model,
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            isDevLikeBundle: false
        )

        let item = try #require(makeAppcastItem(version: "0.64.99"))
        driver.handleDidFindValidUpdate(item)

        #expect(model.detectedUpdateVersion == "0.64.99")
        #expect(model.showsPill)
    }

    @Test func classifiesDebugAndStagingBundlesAsDevLike() {
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debug.my-tag"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging"))
        #expect(UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.staging.my-tag"))
    }

    @Test func doesNotClassifyPublicOrNightlyOrNilAsDevLike() {
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app"))
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.nightly"))
        // RC is on the public release train: it must keep auto-update on.
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.rc"))
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.rc.candidate1"))
        #expect(!UpdateController.isDevLikeBundleIdentifier(nil))
        // A look-alike that is neither the exact base id nor a dotted suffix must not match.
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.debugger"))
        #expect(!UpdateController.isDevLikeBundleIdentifier("com.cmuxterm.app.stagingx"))
    }

    /// A manual "Check for Updates" on a DEV/staging build must not query the public appcast or
    /// offer the public release for install — it short-circuits to "No Updates Available" before
    /// starting Sparkle. (Manual checks are the path that survived the passive-pill gating.)
    @Test func devLikeBundleManualCheckIsSuppressed() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: true
        )
        controller.checkForUpdates()

        // No query / no checking state — the manual check resolves to notFound synchronously.
        guard case .notFound = controller.model.state else {
            Issue.record("dev/staging manual check should surface .notFound, got \(controller.model.state)")
            return
        }
    }

    /// `DisableAutoUpdate` (MDM): the updater never starts and a manual check is a no-op that
    /// leaves the model idle, whichever build is running.
    @Test func managedPolicyKeepsTheUpdaterOffAndSuppressesManualChecks() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: false,
            isDisabledByPolicy: { true }
        )
        #expect(!controller.startUpdaterIfNeeded())
        controller.checkForUpdates()
        guard case .idle = controller.model.state else {
            Issue.record("managed-policy manual check should leave the model idle, got \(controller.model.state)")
            return
        }
    }

    /// A DEV/staging build disables Sparkle's automatic checks so its scheduler never queries the
    /// public appcast. (The override is also re-asserted before `start()`, so the DEBUG
    /// permission-reset path cannot undo it.)
    @Test func devLikeBundleDisablesAutomaticChecks() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: true
        )
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == false)
    }

    /// The public release train keeps automatic checks enabled.
    @Test func publicBundleLeavesAutomaticChecksEnabled() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: .main,
            defaults: defaults,
            isDevLikeBundle: false
        )
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == true)
    }

    /// roma's fork (bazilio91/cmux) ships under the public bundle id with
    /// `CMUXDisableUpdates = true` in its Info.plist, so the first upstream
    /// release can never replace it: the key makes the bundle dev-like.
    @Test func disableUpdatesInfoKeyMakesTheBundleDevLike() {
        #expect(UpdateController.disablesUpdates(infoDictionary: ["CMUXDisableUpdates": true]))
        #expect(UpdateController.disablesUpdates(infoDictionary: ["CMUXDisableUpdates": NSNumber(value: true)]))
        #expect(!UpdateController.disablesUpdates(infoDictionary: ["CMUXDisableUpdates": false]))
        #expect(!UpdateController.disablesUpdates(infoDictionary: ["CMUXDisableUpdates": "YES"]))
        #expect(!UpdateController.disablesUpdates(infoDictionary: [:]))
        #expect(!UpdateController.disablesUpdates(infoDictionary: nil))
    }

    @Test func disableUpdatesBundleTurnsOffAutomaticChecksAndManualChecks() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bundle = try makeBundle(info: ["CFBundleIdentifier": "com.cmuxterm.app", "CMUXDisableUpdates": true])

        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: bundle,
            defaults: defaults
        )
        #expect(controller.isDevLikeBundle)
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == false)
        controller.checkForUpdates()
        guard case .notFound = controller.model.state else {
            Issue.record("CMUXDisableUpdates manual check should surface .notFound, got \(controller.model.state)")
            return
        }
    }

    @Test func publicBundleWithoutTheKeyIsNotDevLike() throws {
        let suiteName = "com.cmuxterm.updatertests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let bundle = try makeBundle(info: ["CFBundleIdentifier": "com.cmuxterm.app"])

        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: SystemUpdateClock(),
            hostBundle: bundle,
            defaults: defaults
        )
        #expect(!controller.isDevLikeBundle)
        #expect(defaults.bool(forKey: UpdateSettings.automaticChecksKey) == true)
    }

    /// A throwaway `.bundle` on disk with the given Info.plist (nested helper, not API).
    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-updater-\(UUID().uuidString).bundle")
        let contents = dir.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: dir))
    }

    /// Builds a minimal valid `SUAppcastItem` for a version string (nested helper, not API).
    private func makeAppcastItem(version: String) -> SUAppcastItem? {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": version,
            "sparkle:shortVersionString": version,
        ]
        let dictionary: [String: Any] = [
            "title": "cmux \(version)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dictionary)
    }
}
