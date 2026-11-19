import AppKit
import Darwin

/// Measures what the running SweetMX costs the Mac: CPU, idle wakeups, memory, disk I/O and disk
/// space. The benchmarks gate fixed inputs before a push; this reads the real app on real data, for
/// checking a build in daily use and for the numbers in docs/PERFORMANCE.md.
///
/// Read-only: it samples kernel counters of a process the user owns and sizes two folders. It sends
/// nothing to the app and changes nothing.
private enum ProfileApp {
    private enum Failure: LocalizedError {
        case invalidArguments
        case notRunning(String)
        case counters(pid_t, Int32)

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Usage: profile-app.swift <bundle-id> <seconds> <data-folder-name>; seconds is \(minimumSeconds)...\(maximumSeconds)."
            case let .notRunning(bundleID): "No running app with bundle id \(bundleID). Start it with `make run` or open the installed copy."
            case let .counters(pid, code): "Cannot read counters of pid \(pid): errno \(code)."
            }
        }
    }

    /// Below this the window holds too few 0.5 s clipboard polls for a wakeup rate to mean anything.
    private static let minimumSeconds: UInt32 = 2
    private static let maximumSeconds: UInt32 = 600
    private static let nanosecondsPerMillisecond = 1_000_000.0
    private static let bytesPerKibibyte = 1024.0
    private static let bytesPerMebibyte = bytesPerKibibyte * bytesPerKibibyte

    /// One reading of the kernel's per-process counters.
    private struct Counters {
        let cpuNanoseconds: Double
        let idleWakeups: UInt64
        let interruptWakeups: UInt64
        let footprint: UInt64
        let peakFootprint: UInt64
        let diskRead: UInt64
        let diskWritten: UInt64
    }

    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("profile-app: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ arguments: [String]) throws {
        // The Makefile passes all three, so the bundle id, window and folder name each have one source.
        guard arguments.count == 3, let seconds = UInt32(arguments[1]), (minimumSeconds ... maximumSeconds).contains(seconds),
              !arguments[2].isEmpty, !arguments[2].contains("/") else { throw Failure.invalidArguments }
        let bundleID = arguments[0]
        let folderName = arguments[2]

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw Failure.notRunning(bundleID)
        }
        let pid = app.processIdentifier
        let start = try counters(of: pid)
        sleep(seconds)
        let end = try counters(of: pid)
        let window = Double(seconds)

        let cpuMilliseconds = (end.cpuNanoseconds - start.cpuNanoseconds) / nanosecondsPerMillisecond
        let wakeups = Double((end.idleWakeups - start.idleWakeups) + (end.interruptWakeups - start.interruptWakeups))
        let rows: [(String, String)] = [
            ("process", "\(app.bundleURL?.path ?? "?") (pid \(pid))"),
            ("window", "\(seconds) s, app idle unless you used it"),
            ("cpu", String(format: "%.2f ms/s (%.3f%% of one core)", cpuMilliseconds / window, cpuMilliseconds / window / 10)),
            ("wakeups", String(format: "%.2f /s (idle and interrupt)", wakeups / window)),
            ("threads", threadCount(of: pid).map(String.init) ?? "?"),
            ("memory footprint", String(format: "%.1f MiB (peak %.1f MiB since launch)", Double(end.footprint) / bytesPerMebibyte, Double(end.peakFootprint) / bytesPerMebibyte)),
            ("disk read", String(format: "%.1f KiB in window", Double(end.diskRead - start.diskRead) / bytesPerKibibyte)),
            ("disk written", String(format: "%.1f KiB in window", Double(end.diskWritten - start.diskWritten) / bytesPerKibibyte)),
            ("data on disk", String(format: "%.1f KiB", folderBytes(dataFolder(named: folderName)) / bytesPerKibibyte)),
            ("app bundle", app.bundleURL.map { String(format: "%.1f MiB", folderBytes($0) / bytesPerMebibyte) } ?? "?"),
        ]
        for (label, value) in rows {
            print(label.padding(toLength: 18, withPad: " ", startingAt: 0) + value)
        }
    }

    private static func counters(of pid: pid_t) throws -> Counters {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard status == 0 else { throw Failure.counters(pid, errno) }
        // CPU times are in Mach absolute time units on Apple silicon, so they are scaled by the timebase.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom)
        return Counters(
            cpuNanoseconds: Double(info.ri_user_time + info.ri_system_time) * scale,
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            footprint: info.ri_phys_footprint,
            peakFootprint: info.ri_lifetime_max_phys_footprint,
            diskRead: info.ri_diskio_bytesread,
            diskWritten: info.ri_diskio_byteswritten
        )
    }

    private static func threadCount(of pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info.pti_threadnum : nil
    }

    private static func dataFolder(named name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Allocated size, not logical size, because that is what the files take from the disk.
    private static func folderBytes(_ folder: URL) -> Double {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += values.totalFileAllocatedSize ?? 0
        }
        return Double(total)
    }
}

ProfileApp.main()
