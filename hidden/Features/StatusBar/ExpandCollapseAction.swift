//
//  ExpandCollapseAction.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

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
