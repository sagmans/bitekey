import AppKit
import Darwin

/// Keep local installs separate from release packaging and the user's saved history.
private enum LocalInstall {
    private enum Action: String {
        /// Runs every install guard and changes nothing. `make install` calls it before it
        /// stops the running copy, so a refusal never leaves the user without SweetMX.
        /// Prints the running copy's bundle path, which `make install` reopens if the
        /// install fails after the stop.
        case check
        case install, uninstall
    }

    private enum Failure: LocalizedError {
        case invalidArguments
        case unexpectedBundle(URL)
        case running
        case legacyRunning(String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Expected check, install or uninstall, source bundle, destination bundle, bundle identifier, and one or more legacy bundle identifiers."
            case let .unexpectedBundle(url): "Refusing to replace or remove an unexpected item at \(url.path)."
            case .running: "Quit SweetMX from its menu before installing, updating, or uninstalling."
            case let .legacyRunning(name): "Quit \(name) and turn off its login item before you install SweetMX."
            }
        }
    }

    private static let fileManager = FileManager.default
    private static let stagingPrefix = ".sweetmx-install-"
    private static let privateDirectoryMode = 0o700
    /// Program, action, source, destination and identifier come first; legacy identifiers follow.
    private static let legacyIdentifiersStart = 5
    /// At least one legacy identifier, so the running-app guard can never be skipped by accident.
    private static let minimumArgumentCount = legacyIdentifiersStart + 1

    static func run(_ arguments: [String]) throws {
        guard arguments.count >= minimumArgumentCount, let action = Action(rawValue: arguments[1]) else {
            throw Failure.invalidArguments
        }
        let source = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let identifier = arguments[4]
        let legacyIdentifiers = Array(arguments[legacyIdentifiersStart...])
        // An empty or equal ID would make the guard test the wrong app, so fail closed.
        guard legacyIdentifiers.allSatisfy({ !$0.isEmpty && $0 != identifier }) else {
            throw Failure.invalidArguments
        }
        switch action {
        case .check:
            // The current copy may still run here: `make install` stops it only after this
            // check passes, and the install action checks again once it has stopped.
            try validateInstallPreconditions(source: source, destination: destination, identifier: identifier, legacyIdentifiers: legacyIdentifiers)
            // The bundle URL comes from Launch Services, so no process path is parsed.
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.bundleURL {
                print(running.path)
            }
        case .install:
            try requireNotRunning(identifier)
            let installed = try validateInstallPreconditions(source: source, destination: destination, identifier: identifier, legacyIdentifiers: legacyIdentifiers)
            try install(source, to: destination, replacing: installed)
            print("Installed \(destination.path)")
        case .uninstall:
            // Uninstall skips the legacy-app guard: it neither registers shortcuts nor
            // copies data, so it must work while the old app runs.
            try requireNotRunning(identifier)
            if try validateInstalledBundle(at: destination, identifier: identifier) {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
                print("Moved \(destination.path) to Trash. Saved history and preferences are kept.")
            }
        }
    }

    /// Replacing or trashing the bundle under a live process would leave it running stale code.
    private static func requireNotRunning(_ identifier: String) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw Failure.running
        }
    }

    /// Shared by `check` and `install`, so the preflight can never drift from the real guard.
    /// Returns whether a SweetMX bundle already sits at the destination; install needs it
    /// to swap rather than create, and check has no use for it.
    @discardableResult
    private static func validateInstallPreconditions(source: URL, destination: URL, identifier: String, legacyIdentifiers: [String]) throws -> Bool {
        let installed = try validateInstalledBundle(at: destination, identifier: identifier)
        // An old app would register the same global shortcuts, and it could write data
        // after the first SweetMX launch copies it. Every former name clashes the same way.
        for legacyIdentifier in legacyIdentifiers {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyIdentifier).first {
                // The app name is what the user sees in the menu bar; the ID is the fallback.
                throw Failure.legacyRunning(running.localizedName ?? legacyIdentifier)
            }
        }
        guard try validateInstalledBundle(at: source, identifier: identifier) else {
            throw Failure.unexpectedBundle(source)
        }
        return installed
    }

    private static func validateInstalledBundle(at url: URL, identifier: String) throws -> Bool {
        // Inspect the entry itself so an unrelated directory or symlink is never replaced.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              Bundle(url: url)?.bundleIdentifier == identifier
        else { throw Failure.unexpectedBundle(url) }
        return true
    }

    private static func install(_ source: URL, to destination: URL, replacing: Bool) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: privateDirectoryMode])
        defer {
            do {
                // This is the unique directory created above, including an old bundle after a swap.
                print("Cleaning staging directory \(staging.path)")
                try fileManager.removeItem(at: staging)
            } catch {
                fputs("Could not clean staging directory \(staging.path): \(error)\n", stderr)
            }
        }
        let stagedBundle = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: source, to: stagedBundle)

        // A same-volume swap keeps a usable bundle in place if copying or replacing fails.
        let flags = UInt32(replacing ? RENAME_SWAP : RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, stagedBundle.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

do {
    try LocalInstall.run(CommandLine.arguments)
} catch {
    fputs("Local install failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
