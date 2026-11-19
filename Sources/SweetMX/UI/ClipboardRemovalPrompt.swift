import AppKit

/// Confirms removing saved clipboard entries, because the removal cannot be undone.
///
/// A sheet on the launcher panel, not a free-standing alert: a sheet keeps the panel open (the controller
/// ignores resign-key while one is attached) and ties the question to the window the user is looking at.
enum ClipboardRemovalPrompt {
    /// Binds the removal to the clip ID named when the sheet opens, since live capture can reorder results.
    static func present(_ removal: ClipboardManager.HistoryRemoval, for model: LauncherModel, over window: NSWindow?) {
        guard model.isPresented, model.mode == .clipboard, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        let buttonTitle: String
        switch removal {
        case let .item(id):
            // A second prompt cannot change a removal the user has already confirmed.
            guard !model.clips.departingIDs.contains(id) else { return }
            alert.messageText = DesignTokens.Copy.deleteClipTitle
            alert.informativeText = DesignTokens.Copy.deleteClipExplanation
            buttonTitle = DesignTokens.Copy.deleteClip
        case .all:
            alert.messageText = DesignTokens.Copy.clearHistoryTitle
            alert.informativeText = DesignTokens.Copy.clearHistoryExplanation
            buttonTitle = DesignTokens.Copy.clearHistoryButton
        }
        let cancel = alert.addButton(withTitle: DesignTokens.Copy.cancel)
        alert.addButton(withTitle: buttonTitle).hasDestructiveAction = true
        // Escape cancels explicitly. Return also targets Cancel so it cannot confirm by default.
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = DesignTokens.Keys.cancelKeyEquivalent
        alert.beginSheetModal(for: window) { [weak model] response in
            guard response == .alertSecondButtonReturn else { return }
            model?.removeClips(removal)
        }
    }

    /// The launcher panel, found by type because SwiftUI menu actions have no handle to their window.
    @MainActor
    static var launcherWindow: NSWindow? {
        NSApp.windows.first { $0 is LauncherPanel }
    }
}
