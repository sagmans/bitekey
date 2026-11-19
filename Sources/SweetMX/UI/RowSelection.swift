import SwiftUI

/// A row value paired with its list position, which selection, pointer handling and the spoken
/// "n of N" all need.
struct IndexedRow<Row: Identifiable>: Identifiable {
    let index: Int
    let row: Row

    var id: Row.ID {
        row.id
    }
}

/// Pairs rows with their positions once per published result set instead of on every list redraw.
///
/// A plain class held in view state, so storing the result while a body runs triggers no update. The
/// generation is the model's `rowsGeneration`, which changes exactly when the rows are replaced.
final class IndexedRowsMemo<Row: Identifiable> {
    private var generation: Int?
    private var cached: [IndexedRow<Row>] = []

    /// Returns the cached pairs while `generation` is unchanged, so redraws between publishes share one array.
    func rows(_ source: [Row], generation: Int) -> [IndexedRow<Row>] {
        if generation != self.generation {
            cached = source.enumerated().map { IndexedRow(index: $0.offset, row: $0.element) }
            self.generation = generation
        }
        return cached
    }
}

/// Caches section captions per published result set without triggering extra SwiftUI update passes.
///
/// Computed synchronously during `body` instead of in `.onChange`, because deferring the rebuild left
/// captions blank for one frame whenever `rowsGeneration` bumped, causing the list to jump up and back down.
final class SectionHeadersMemo {
    /// Captures every input that can change a result set's captions.
    struct Key: Equatable {
        let mode: SearchMode
        let generation: Int
        let showsSections: Bool
        let referenceDate: Date?
        let timeZone: TimeZone
        let calendarIdentifier: Calendar.Identifier
    }

    private var key: Key?
    private var cached: [String?] = []

    /// Most recently computed captions, for scroll helpers running outside `body`.
    var current: [String?] {
        cached
    }

    /// One pass over the rows per result set, with one calendar and one "now", so every caption in the
    /// set agrees on what today is. Buckets count calendar days while a row's relative time counts elapsed
    /// time, so "13 hr. ago" can sit under "Yesterday"; both are true, and the panel is short-lived, so
    /// neither is re-rendered as the clock moves.
    func headers(
        for key: Key,
        apps: [AppRowData],
        clips: [ClipRowData],
        calendar: Calendar
    ) -> [String?] {
        if key != self.key {
            if !key.showsSections {
                cached = []
            } else {
                switch key.mode {
                case .applications:
                    cached = ListSections.appHeaders(for: apps)
                case .clipboard:
                    var zoned = calendar
                    zoned.timeZone = key.timeZone
                    cached = ListSections.clipHeaders(for: clips, now: key.referenceDate ?? Date(), calendar: zoned)
                }
            }
            self.key = key
        }
        return cached
    }
}

/// Scrolls the list when `LauncherModel.selection` moves.
///
/// A separate view because a view that reads the selection is re-evaluated on every change of it; with
/// the read here, a selection move re-evaluates this empty view and the two affected rows, and the list
/// that builds every row is left alone.
struct SelectionFollower: View {
    let model: LauncherModel
    /// Brings the newly selected position into view; nil means focus went back to the search field.
    let onMove: (Int?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: model.selection) { _, new in
                onMove(new)
            }
            .accessibilityHidden(true)
    }
}

/// Draws the glass selection capsule behind one row and handles pointer selection and activation.
///
/// It reads only its own flag, so a selection move invalidates the row that loses the capsule and the
/// row that gains it, and `matchedGeometryEffect` still glides the capsule between them.
struct SelectableRow<Content: View>: View {
    let flag: RowSelectionFlag
    let selectionFlags: RowSelectionFlags
    let style: SelectionStyle
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onActivate: () -> Void
    /// Draws the row; receives whether it is selected, because row text changes contrast on the capsule.
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        let isSelected = flag.isSelected
        let capsuleAnimation = selectionFlags.shouldAnimate ? style.animation : nil
        content(isSelected)
            .background {
                // Scope selection animation strictly to the capsule so text labels (such as relative timestamps)
                // never cross-fade over themselves, and skip motion on list deletions so the highlight snaps.
                ZStack {
                    if isSelected {
                        Color.clear
                            .launcherGlass(.regular.tint(style.tint.opacity(style.opacity)).interactive(), in: .capsule, snapshotFill: DesignTokens.Palette.snapshotSelection)
                            .matchedGeometryEffect(id: DesignTokens.Glass.selectionID, in: namespace)
                    }
                }
                .animation(capsuleAnimation, value: isSelected)
            }
            .contentShape(Rectangle())
            // With a double-tap gesture present, the single tap waits for the double tap to fail, so selection
            // lands after the system double-click interval; registering the double tap first keeps both working.
            .onTapGesture(count: DesignTokens.Metrics.activationClickCount, perform: onActivate)
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Look of the selection capsule, resolved once by the list from its environment and shared by every row.
struct SelectionStyle {
    let tint: Color
    let opacity: Double
    let animation: Animation?
}
