import AppKit
import OSLog

/// Confirms removing saved clipboard entries, because the removal cannot be undone.
///
/// A sheet on the launcher panel, not a free-standing alert: a sheet keeps the panel open (the controller
/// ignores resign-key while one is attached) and ties the question to the window the user is looking at.
enum ClipboardRemovalPrompt {
    /// Makes a failed shortcut setup diagnosable without including any clipboard data.
    private static let logger = Logger(subsystem: LogSubsystem.name, category: "clipboard-confirmation")

    /// Binds the removal to the clip ID named when the sheet opens, since live capture can reorder results.
    static func present(_ removal: ClipboardManager.HistoryRemoval, for model: LauncherModel, over window: NSWindow?) {
        guard model.isPresented, model.mode == .clipboard, let window, window.attachedSheet == nil else { return }
        switch removal {
        case let .item(id):
            // A second prompt cannot change a removal the user has already confirmed.
            guard !model.clips.departingIDs.contains(id) else { return }
            presentSingleClip(id, for: model, over: window)
        case .all:
            presentClearHistory(for: model, over: window)
        }
    }

    /// One focused action keeps keyboard deletion quick and uses the system's default button contrast.
    private static func presentSingleClip(_ id: UUID, for model: LauncherModel, over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = DesignTokens.Copy.deleteClipTitle
        alert.informativeText = DesignTokens.Copy.deleteClipExplanation
        let delete = alert.addButton(withTitle: DesignTokens.Copy.deleteClip)
        let sheet = alert.window
        sheet.initialFirstResponder = delete
        // A buttonless Cancel needs its own Escape handling. Keep the monitor scoped to this sheet.
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak sheet] event in
            guard let sheet, event.window === sheet, let parent = sheet.sheetParent else { return event }
            switch event.keyCode {
            case LauncherKeyCode.escape:
                parent.endSheet(sheet, returnCode: .cancel)
                return nil
            case LauncherKeyCode.returnKey, LauncherKeyCode.keypadEnter:
                // A Return held before opening the sheet must not confirm it.
                return event.isARepeat ? nil : event
            default:
                return event
            }
        }) else {
            logger.error("Could not install the keyboard monitor for single-clip confirmation")
            return
        }
        alert.beginSheetModal(for: window) { [weak model] response in
            NSEvent.removeMonitor(monitor)
            guard response == .alertFirstButtonReturn else { return }
            model?.removeClips(.item(id))
        }
    }

    /// Clearing the whole archive keeps Cancel as the safe default for a destructive bulk action.
    private static func presentClearHistory(for model: LauncherModel, over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = DesignTokens.Copy.clearHistoryTitle
        alert.informativeText = DesignTokens.Copy.clearHistoryExplanation
        let cancel = alert.addButton(withTitle: DesignTokens.Copy.cancel)
        alert.addButton(withTitle: DesignTokens.Copy.clearHistoryButton).hasDestructiveAction = true
        // Escape cancels explicitly. Return also targets Cancel so it cannot confirm by default.
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = DesignTokens.Keys.cancelKeyEquivalent
        alert.beginSheetModal(for: window) { [weak model] response in
            guard response == .alertSecondButtonReturn else { return }
            model?.removeClips(.all)
        }
    }

    /// The launcher panel, found by type because SwiftUI menu actions have no handle to their window.
    @MainActor
    static var launcherWindow: NSWindow? {
        NSApp.windows.first { $0 is LauncherPanel }
    }
}
