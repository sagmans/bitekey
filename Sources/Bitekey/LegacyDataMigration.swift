import Foundation

/// Carries a user's data over from the app's former names, so a rename does not look like data loss.
///
/// Runs once, first thing in `AppDelegate.startServices()`, before any store loads its files or
/// reads its preferences. Legacy folders and legacy defaults domains are only ever read: previous
/// installs stay intact, so a user can roll back and a failed migration loses nothing.
nonisolated struct LegacyDataMigration {
    /// Outcome of one migration step.
    enum StepResult: Equatable {
        case done
        case skipped
        case failed(Failure)
    }

    /// A failure with its error domain and code kept apart from the free text, so the boundary log
    /// can show the stable fields publicly and keep the text, which may hold paths, private.
    struct Failure: Equatable, ExpressibleByStringLiteral {
        let detail: String
        let domain: String
        let code: Int

        init(stringLiteral value: String) {
            detail = value
            domain = LegacyDataMigration.logicDomain
            code = 0
        }

        init(_ error: Error) {
            let bridged = error as NSError
            detail = String(describing: error)
            domain = bridged.domain
            code = bridged.code
        }

        fileprivate init(detail: String, domain: String, code: Int) {
            self.detail = detail
            self.domain = domain
            self.code = code
        }
    }

    /// Steps are reported separately because they fail independently: a folder failure must still
    /// let the preferences move over, and a stale-temp failure must not block either.
    struct Report: Equatable {
        let staleTemps: StepResult
        let folder: StepResult
        let preferences: StepResult
    }

    /// Raised for outcomes that are not a thrown system error, so they still carry a cause chain.
    private enum MigrationError: Error {
        case copyIsNotDirectory
    }

    /// One former name: where its data folder and its preferences lived.
    struct LegacySource: Equatable {
        let bundleID: String
        let folderName: String
    }

    /// Newest name first. A user may have run several former names; the newest one that left data
    /// holds their latest data. Each step picks on its own: the folder comes from the newest name
    /// that left anything at its folder path, the preferences from the newest domain that holds an
    /// allowlisted key, so a name that left only one of the two does not block the other.
    /// Keep in step with `LEGACY_BUNDLE_IDS` in the Makefile, which guards installs. No entry may
    /// equal the current bundle ID or `AppDataLocation.folderName`: the app's own domain cannot be
    /// opened as a suite and is dropped, and its own folder would always look like legacy data.
    static let legacySources = [
        LegacySource(bundleID: "com.assagman.applebox", folderName: "AppleBox"),
    ]
    /// Allowlist, not denylist: the legacy domain also reports global-domain keys and keys of
    /// unrelated features, which must not leak into the new domain.
    static let allowedKeyPrefixes = ["GlobalShortcut."]
    static let allowedKeys = ["ClipboardCapturePaused"]
    /// Set only after a completed pass, so a user's later changes in the new domain are never
    /// overwritten by a second run.
    static let markerKey = "LegacyDataMigration.preferencesDone"
    /// Marks half-copied folders; a crash mid-copy leaves one behind, and the next run removes it.
    static let tempPrefix = ".bitekey-migration-"
    /// Marks a finished or intentionally skipped folder step. A failed folder step leaves it unset,
    /// because the stores create the new folder right after, and without it the next launch would
    /// see "new folder exists" and silently never retry or report.
    static let folderMarkerKey = "LegacyDataMigration.folderDone"
    /// Error domain for failures that do not come from a system error.
    static let logicDomain = "LegacyDataMigration"
    private static let newFolderExistsDetail = "new data folder exists; legacy data not copied"
    private static let legacyNotDirectoryDetail = "legacy data folder is not a plain directory; not copied"
    private static let cleanupFailedSeparator = "; temp cleanup failed: "
    private static let detailSeparator = "; "
    /// Bounds the sibling listing used to find stale temp folders.
    private static let siblingListingLimit = 1000

    private let fileSystem: FileSystemProtocol
    private let preferences: UserDefaults
    /// Same order as `legacySources`, newest first. A domain that cannot be opened is dropped for
    /// good: `UserDefaults(suiteName:)` fails only for an invalid name, which no retry fixes.
    private let legacyPreferences: [UserDefaults]

    init(
        fileSystem: FileSystemProtocol = SystemFileManager(),
        preferences: UserDefaults = .standard,
        legacyPreferences: [UserDefaults] = LegacyDataMigration.legacySources.compactMap { UserDefaults(suiteName: $0.bundleID) }
    ) {
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.legacyPreferences = legacyPreferences
    }

    /// Never throws: a failed migration must not stop the launch. The caller logs the report once.
    func run() -> Report {
        // The sweep runs first and on every run: a crash leaves temp folders behind even when no
        // folder step is due, and they hold a full copy of the user's data.
        let staleTemps = sweepStaleTemps()
        return Report(staleTemps: staleTemps, folder: migrateFolder(), preferences: migratePreferences())
    }

    // MARK: - Folder

    private var appSupportURL: URL {
        fileSystem.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileSystem.homeDirectoryForCurrentUser
    }

    private func migrateFolder() -> StepResult {
        guard !preferences.bool(forKey: Self.folderMarkerKey) else { return .skipped }

        let appSupport = appSupportURL
        let newFolder = appSupport.appendingPathComponent(AppDataLocation.folderName, isDirectory: true)

        let legacyFolder: URL
        do {
            switch try newestLegacyFolder(in: appSupport) {
            case .none:
                preferences.set(true, forKey: Self.folderMarkerKey)
                return .skipped
            case .notDirectory:
                return .failed(Failure(stringLiteral: Self.legacyNotDirectoryDetail))
            case let .directory(folder):
                legacyFolder = folder
            }
        } catch {
            // A read error is retried next launch, never remembered as "nothing to migrate".
            return .failed(Failure(error))
        }
        // Merging into existing new data could overwrite it, so report it on every launch instead.
        guard !fileSystem.fileExists(atPath: newFolder.path) else {
            return .failed(Failure(stringLiteral: Self.newFolderExistsDetail))
        }

        // A temp folder is a sibling of the target so the final move stays on one volume and is atomic.
        let temp = appSupport.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try fileSystem.copyItem(at: legacyFolder, to: temp)
            // A copy that is not a real directory must not be published as the user's data.
            guard try fileSystem.itemKind(at: temp) == .directory else { throw MigrationError.copyIsNotDirectory }
            try fileSystem.moveItem(at: temp, to: newFolder)
            preferences.set(true, forKey: Self.folderMarkerKey)
            return .done
        } catch {
            return .failed(failure(for: error, cleaning: temp))
        }
    }

    /// What the newest former name left at its folder path.
    private enum LegacyFolder {
        case none
        case directory(URL)
        case notDirectory
    }

    /// The first former name that left anything at its folder path decides, so the newest data
    /// wins. A legacy symlink could point anywhere and is never followed; it shows as a failure
    /// rather than being skipped silently, and an older name is not tried in its place.
    private func newestLegacyFolder(in appSupport: URL) throws -> LegacyFolder {
        for source in Self.legacySources {
            let folder = appSupport.appendingPathComponent(source.folderName, isDirectory: true)
            switch try fileSystem.itemKind(at: folder) {
            case .missing:
                continue
            case .directory:
                return .directory(folder)
            case .symbolicLink, .other:
                return .notDirectory
            }
        }
        return .none
    }

    /// Never leave a partial copy that a later run could mistake for real data; a cleanup error
    /// is appended so an orphaned copy shows up in the log.
    private func failure(for error: Error, cleaning temp: URL) -> Failure {
        var failure = Failure(error)
        do {
            try fileSystem.removeItem(at: temp)
        } catch {
            failure = Failure(
                detail: failure.detail + Self.cleanupFailedSeparator + String(describing: error),
                domain: failure.domain,
                code: failure.code
            )
        }
        return failure
    }

    private func sweepStaleTemps() -> StepResult {
        let entries: [URL]
        do {
            entries = try fileSystem.contentsOfDirectory(
                at: appSupportURL,
                includingPropertiesForKeys: nil,
                options: [],
                limit: Self.siblingListingLimit
            )
        } catch {
            return .failed(Failure(error))
        }

        var removed = false
        var failures: [Failure] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.tempPrefix) {
            do {
                try fileSystem.removeItem(at: entry)
                removed = true
            } catch {
                // Keep going: one stuck folder must not hide the others.
                failures.append(Failure(error))
            }
        }
        guard let first = failures.first else { return removed ? .done : .skipped }
        let detail = failures.map(\.detail).joined(separator: Self.detailSeparator)
        return .failed(Failure(detail: detail, domain: first.domain, code: first.code))
    }

    // MARK: - Preferences

    private func migratePreferences() -> StepResult {
        guard !preferences.bool(forKey: Self.markerKey) else { return .skipped }
        // Empty only when no former name is configured or tests inject none; nothing to read, so
        // the marker stays unset and a later build that adds a source still runs this step.
        guard !legacyPreferences.isEmpty else { return .skipped }

        // Only the newest domain that holds any allowlisted key is used, never a mix: shortcut
        // presets must be unique, and keys merged from two names could clash in a set the user
        // never chose. Keys already set under the current name are never overwritten.
        let source = legacyPreferences.lazy
            .map { $0.dictionaryRepresentation().filter { isAllowed($0.key) } }
            .first { !$0.isEmpty } ?? [:]
        var copied = false
        for (key, value) in source where preferences.object(forKey: key) == nil {
            preferences.set(value, forKey: key)
            copied = true
        }
        preferences.set(true, forKey: Self.markerKey)
        return copied ? .done : .skipped
    }

    private func isAllowed(_ key: String) -> Bool {
        Self.allowedKeys.contains(key) || Self.allowedKeyPrefixes.contains { key.hasPrefix($0) }
    }
}
