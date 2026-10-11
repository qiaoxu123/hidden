//
//  ExpandCollapseActionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

final class ExpandCollapseActionTests: XCTestCase {

    // Assistive synthesis (VoiceOver AXPress) produces no NSEvent; a nil event
    // must still toggle the bar, matching a plain left click.
    func testNilEventToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: nil, optionPressed: false), .toggle)
    }

    func testLeftClickToggles() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, optionPressed: false), .toggle)
    }

    func testRightClickShowsContextMenu() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, optionPressed: false), .contextMenu)
    }

    func testOptionLeftTogglesSeparators() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .leftMouseUp, optionPressed: true), .toggleSeparators)
    }

    func testOptionRightTogglesSeparators() {
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .rightMouseUp, optionPressed: true), .toggleSeparators)
    }

    func testOtherMouseEventTogglesSeparators() {
        // Preserves the old else-branch: any non-left/right click lands on the
        // separators toggle.
        XCTAssertEqual(ExpandCollapseActionResolver.action(eventType: .otherMouseUp, optionPressed: false), .toggleSeparators)
    }
}

final class MenuBarToggleActionTests: XCTestCase {
    func testCommandShortcutExpandsCollapsedBar() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .collapsed, isShortcut: true,
            commandPressed: true, leftMousePressed: false, hasDeferredCollapse: false), .expand)
    }

    func testCommandShortcutCollapseWaitsForKeyUp() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .expanded, isShortcut: true,
            commandPressed: true, leftMousePressed: false, hasDeferredCollapse: false), .deferCollapse)
    }

    func testCommandDragDoesNotToggle() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .collapsed, isShortcut: true,
            commandPressed: true, leftMousePressed: true, hasDeferredCollapse: false), .ignore)
    }

    func testNormalClickCancelsInFlightCollapse() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .calibrating, isShortcut: false,
            commandPressed: false, leftMousePressed: false, hasDeferredCollapse: false), .expand)
    }

    func testSecondShortcutCancelsDeferredCollapse() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .expanded, isShortcut: true,
            commandPressed: true, leftMousePressed: false, hasDeferredCollapse: true), .cancelDeferredCollapse)
    }
}

final class BusyMenuBarToggleTests: XCTestCase {
    func testArrowClickQueuesWhileExpandedLayoutIsBusy() {
        XCTAssertEqual(MenuBarToggleActionResolver.action(state: .expanded, isShortcut: false,
            commandPressed: false, leftMousePressed: false, hasDeferredCollapse: false,
            engineBusy: true), .deferCollapse)
    }
}
