import OSLog

/// Named intervals around the work a user waits on, so a trace of the real app (`make profile-trace`,
/// or Instruments) shows each search, scan and save on the Points of Interest
/// track next to the CPU samples it caused. The benchmarks in `Tests/SweetMXBenchmarks` gate the same
/// paths with fixed inputs; these intervals explain a slow path on real data.
///
/// A signpost costs a few nanoseconds when no trace is recording, so they stay on in release builds.
/// They carry names only, never queries or clip text.
nonisolated enum PerformanceSignposts {
    /// One name per path, kept together so the trace vocabulary is reviewed in one place.
    enum Name {
        static let startup: StaticString = "Startup"
        static let appScan: StaticString = "App scan"
        static let appSearch: StaticString = "App search"
        static let clipSearch: StaticString = "Clip search"
        static let historyLoad: StaticString = "History load"
        static let historySave: StaticString = "History save"
    }

    /// Points of Interest is the track Instruments shows by default in every template.
    private static let signposter = OSSignposter(subsystem: LogSubsystem.name, category: .pointsOfInterest)

    /// An open interval; call `end()` exactly once, usually from a `defer`.
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState

        func end() {
            PerformanceSignposts.signposter.endInterval(name, state)
        }
    }

    /// Each interval gets its own ID, because searches on different queues can overlap and an
    /// exclusive ID would pair the wrong begin and end.
    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }
}
