//
//  ExpandCollapseAction.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

enum StatusBarActionDispatcher {
    static func afterTracking(commandPressed: Bool = false,
                              isMousePressed: @escaping () -> Bool = { MenuBarInteractionState.isLeftMousePressed },
                              _ action: @escaping () -> Void) {
        // Preserve the initiating click's intent even if Command is released
        // before default mode resumes. A Command-click belongs to rearranging.
        guard !commandPressed else { return }
        // The main dispatch queue also drains inside AppKit's nested tracking
        // loop. Restrict this work to default mode, after the click has ended.
        RunLoop.main.perform(inModes: [.default]) {
            guard isMousePressed() else { return action() }
            // macOS can still report down after leaving tracking mode. Retain
            // either toggle direction until release; never discard this click
            // or temporarily reveal the always-hidden section while waiting.
            Timer.scheduledTimer(withTimeInterval: MenuBarInteractionState.releasePollingInterval, repeats: true) { timer in
                guard !isMousePressed() else { return }
                timer.invalidate()
                action()
            }
        }
    }
}

// What a press on the expand/collapse button should do. Kept as a pure mapping
// so the decision is unit-testable without a live status item or a real NSEvent.
enum ExpandCollapseAction {
    case toggle
    case contextMenu
    case toggleSeparators
}

enum ExpandCollapseActionResolver {
    // A nil event type means there is no real NSEvent behind the press, which is
    // what assistive synthesis (VoiceOver AXPress) produces: treat it as a plain
    // left click so VoiceOver users can toggle the bar at all.
    static func action(eventType: NSEvent.EventType?, optionPressed: Bool) -> ExpandCollapseAction {
        guard let eventType = eventType else { return .toggle }
        if optionPressed { return .toggleSeparators }
        switch eventType {
        case .leftMouseUp: return .toggle
        case .rightMouseUp: return .contextMenu
        default: return .toggleSeparators
        }
    }
}

// Explicit Command shortcuts remain usable while Command is held. A collapse
// waits for key-up; a drag or a Command-click on the item never toggles it.
enum MenuBarToggleAction {
    case ignore, expand, collapse, deferCollapse, cancelDeferredCollapse
}

enum MenuBarToggleActionResolver {
    static func action(state: MenuBarEngineState, isShortcut: Bool,
                       commandPressed: Bool, leftMousePressed: Bool,
                       hasDeferredCollapse: Bool, engineBusy: Bool = false) -> MenuBarToggleAction {
        guard !leftMousePressed, isShortcut || !commandPressed else { return .ignore }
        if hasDeferredCollapse { return .cancelDeferredCollapse }
        if state == .collapsed || state == .calibrating { return .expand }
        return engineBusy || (isShortcut && commandPressed) ? .deferCollapse : .collapse
    }
}
