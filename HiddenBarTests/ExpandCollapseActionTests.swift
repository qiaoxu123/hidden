//
//  ExpandCollapseActionTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

final class StatusBarActionDispatcherTests: XCTestCase {
    func testCompletedClickWaitsForLaggingInputThenExecutesOnce() {
        var pressed = true
        var count = 0
        StatusBarActionDispatcher.afterTracking(isMousePressed: { pressed }) { count += 1 }
        let deadline = Date(timeIntervalSinceNow: 0.08)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
        XCTAssertEqual(count, 0, "Keep the current visibility restriction while input still reports down")
        pressed = false
        let releasedDeadline = Date(timeIntervalSinceNow: 0.15)
        while Date() < releasedDeadline { RunLoop.main.run(mode: .default, before: releasedDeadline) }
        XCTAssertEqual(count, 1, "A completed click must be retained and executed exactly once")
    }
    func testCommandClickIsIgnoredAfterCommandIsReleased() {
        var commandPressed = true
        var invoked = false
        StatusBarActionDispatcher.afterTracking(commandPressed: commandPressed) { invoked = true }
        commandPressed = false
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        XCTAssertFalse(commandPressed)
        XCTAssertFalse(invoked)
        timer.invalidate()
    }

    func testToggleWaitsUntilMouseTrackingModeEnds() {
        XCTAssertTrue(Thread.isMainThread)
        var invoked = false
        StatusBarActionDispatcher.afterTracking(isMousePressed: { false }) { invoked = true }
        // Keep this nested tracking loop alive, as NSStatusBarButton does while
        // dispatching mouse-up. A main-queue hop can run in this same loop.
        let trackingTimer = Timer(timeInterval: 0.02, repeats: false) { _ in }
        RunLoop.main.add(trackingTimer, forMode: .eventTracking)
        RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.02))
        XCTAssertFalse(invoked, "A toggle must not execute while AppKit still tracks the click")
        let deadline = Date(timeIntervalSinceNow: 0.2)
        while !invoked && Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
        XCTAssertTrue(invoked, "The toggle must execute once normal event processing resumes")
        trackingTimer.invalidate()
    }
}

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
