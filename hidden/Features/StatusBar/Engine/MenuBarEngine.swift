//
//  MenuBarEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

enum MenuBarInteractionState {
    // macOS 27 status-item tracking can leave NSEvent.pressedMouseButtons at
    // mouse-down even after mouse-up and a main-queue hop. Read live session
    // input so ordinary clicks are not mistaken for an ongoing drag.
    static var isLeftMousePressed: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
}

// StatusBarController decides WHAT the user wants (collapsed or expanded, which
// sections exist); an engine decides HOW the menu bar is made to do it. Keeping
// the mechanics here lets an OS release that changes menu-bar layout (#360) get
// its own engine without version checks spreading through the controller.
protocol MenuBarEngine: AnyObject {
    var state: MenuBarEngineState { get }
    var isBusy: Bool { get }
    var failureReason: MenuBarFailureReason? { get }

    func collapse(completion: @escaping (CollapseResult) -> Void)
    func expand()
    func revealForRearrangement()

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool)

    // Whether the user's ⌘-drag arrangement lets the engine hide anything: its
    // hiding boundary must sit on the hidden side of the arrow. The controller
    // does not collapse otherwise.
    var isArrangementValid: Bool { get }

    // Whether the always-hidden separator sits beyond the regular hidden section.
    var isAlwaysHiddenSeparatorPlaced: Bool { get }

    // Display geometry changed. Re-applies the collapse to the live items when
    // collapsed, so a hot-plug does not leave a stale length behind (PR #354).
    func invalidateLayout()
}

extension MenuBarEngine {
    var failureReason: MenuBarFailureReason? { nil }
    var isBusy: Bool { state == .calibrating }
    func revealForRearrangement() { expand() }
}

enum MenuBarFailureReason {
    case accessibilityPermission, unavailableAPI, layoutUnavailable, activationFailed
}

// Keep explicit shortcut intent until asynchronous layout recovery is ready.
final class DeferredCollapseRequest {
    private(set) var isPending = false

    func request() { isPending = true }
    func cancel() { isPending = false }

    func performIfReady(isInteractionActive: Bool, engine: MenuBarEngine, action: () -> Void) {
        guard isPending, !isInteractionActive, !engine.isBusy else { return }
        isPending = false
        action()
    }
}

enum MenuBarEngineState {
    case expanded
    case calibrating
    case collapsed
    case unavailable
}

enum CollapseResult {
    case collapsed
    case unavailable
}

enum MenuBarOrder {
    // True when `item` sits on the hidden side of `boundary`: to its left in a
    // left-to-right layout, to its right otherwise. False when either is not on
    // screen, since nothing can be judged then.
    static func isItem(_ item: NSStatusItem?, onHiddenSideOf boundary: NSStatusItem?) -> Bool {
        guard let itemX = item?.button?.window?.frame.origin.x,
              let boundaryX = boundary?.button?.window?.frame.origin.x else { return false }
        return Constant.isUsingLTRLanguage ? boundaryX >= itemX : boundaryX <= itemX
    }
}

// The controller owns and recreates the status items; engines only borrow them.
protocol MenuBarItemProvider: AnyObject {
    var toggleItem: NSStatusItem { get }
    var separatorItem: NSStatusItem { get }
    var alwaysHiddenItem: NSStatusItem? { get }
}
