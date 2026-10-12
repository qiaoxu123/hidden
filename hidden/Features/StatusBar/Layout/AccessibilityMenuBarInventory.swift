//
//  AccessibilityMenuBarInventory.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import ApplicationServices

// Lists other apps' status items through public Accessibility API: every running
// app's AXExtrasMenuBar children, with the owning bundle from the process.
// Needs the Accessibility permission, and does not work inside the App Sandbox
// (the sandbox denies the mach-lookup to com.apple.axserver even when the
// permission is granted), so only the non-sandboxed direct build uses it.
final class AccessibilityMenuBarInventory: MenuBarInventoryProviding {
    private static let messagingTimeout: Float = 0.1

    private var hasRequestedAuthorization = false

    var isAuthorized: Bool {
        return AXIsProcessTrusted()
    }

    // Shows the system prompt once per launch; asking on every collapse would
    // nag while the user is still in System Settings.
    func requestAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Accessibility round-trips to every app take about a second in total, so the
    // walk runs off the main thread.
    func snapshot(completion: @escaping ([MenuBarInventoryItem]?) -> Void) {
        // Only app bundles own status items. Skipping the rest (dozens of WebKit
        // and XPC helpers, each of which would sit out the timeout) cuts the walk
        // from ~2.8s to ~1s.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && $0.bundleURL?.pathExtension == "app" }
            .map { (pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) }
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.parallelStatusItems(of: apps)
            DispatchQueue.main.async { completion(items) }
        }
    }

    typealias AttributeReader = (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    static func parallelStatusItems(of apps: [(pid: pid_t, bundleIdentifier: String?)],
                                    readApp: @escaping ((pid: pid_t, bundleIdentifier: String?)) -> [MenuBarInventoryItem]? = {
                                        AccessibilityMenuBarInventory.statusItems(of: [$0])
                                    }) -> [MenuBarInventoryItem]? {
        let workers = min(3, apps.count)
        guard workers > 0 else { return [] }
        let lock = NSLock()
        var results = [[MenuBarInventoryItem]?](repeating: nil, count: apps.count)
        var cancelled = false
        // A few independent app endpoints can answer concurrently. Keep the
        // bound small so this does not flood AX while macOS handles dragging.
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: apps.count, by: workers) {
                lock.lock()
                let stopped = cancelled
                lock.unlock()
                if stopped { return }
                let partial = readApp(apps[index])
                lock.lock()
                results[index] = partial
                if partial == nil { cancelled = true }
                lock.unlock()
            }
        }
        guard !cancelled else { return nil }
        return results.compactMap { $0 }.flatMap { $0 }
    }

    private static func readAttribute(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (result, value)
    }

    static func statusItems(of apps: [(pid: pid_t, bundleIdentifier: String?)],
                            isInteractionActive: () -> Bool = {
                                CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) ||
                                    MenuBarInteractionState.isLeftMousePressed
                            },
                            read: AttributeReader = AccessibilityMenuBarInventory.readAttribute) -> [MenuBarInventoryItem]? {
        var items: [MenuBarInventoryItem] = []
        for app in apps {
            // Stop querying AX while macOS handles Command-drag rearrangement.
            // Use session input state here because this walk is off the main thread.
            guard !isInteractionActive() else { return nil }
            let element = AXUIElementCreateApplication(app.pid)
            // The default timeout is several seconds per app, and one busy or hung
            // app then stalls the collapse (measured: ~18s on a normal session).
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            let (barResult, barValue) = read(element, "AXExtrasMenuBar" as CFString)
            if barResult == .attributeUnsupported || barResult == .noValue { continue }
            if barResult != .success { NSLog("MenuBarInventory: extras read failed for \(app.bundleIdentifier ?? "unknown"), AX error \(barResult.rawValue)") }
            guard barResult == .success,
                  let bar = barValue, CFGetTypeID(bar) == AXUIElementGetTypeID() else {
                guard let bundle = app.bundleIdentifier else { return nil }
                items.append(MenuBarInventoryItem(bundleIdentifier: bundle, frame: .null, mustKeepVisible: true))
                continue
            }
            let (childrenResult, childrenValue) = read(bar as! AXUIElement, kAXChildrenAttribute as CFString)
            if childrenResult != .success { NSLog("MenuBarInventory: children read failed for \(app.bundleIdentifier ?? "unknown"), AX error \(childrenResult.rawValue)") }
            guard childrenResult == .success,
                  let children = childrenValue as? [AXUIElement] else {
                guard let bundle = app.bundleIdentifier else { return nil }
                items.append(MenuBarInventoryItem(bundleIdentifier: bundle, frame: .null, mustKeepVisible: true))
                continue
            }
            for child in children {
                guard !isInteractionActive() else { return nil }
                guard let frame = frame(of: child, read: read), app.bundleIdentifier != nil else {
                    NSLog("MenuBarInventory: item position unavailable for \(app.bundleIdentifier ?? "unknown")")
                    guard let bundle = app.bundleIdentifier else { return nil }
                    items.append(MenuBarInventoryItem(bundleIdentifier: bundle, frame: .null, mustKeepVisible: true))
                    break
                }
                items.append(MenuBarInventoryItem(bundleIdentifier: app.bundleIdentifier, frame: frame))
            }
        }
        return items
    }

    // Accessibility frames use a top-left origin, AppKit's bottom-left. Only the
    // horizontal position matters for sections, and x is the same in both.
    private static func frame(of element: AXUIElement, read: AttributeReader) -> CGRect? {
        let (positionResult, positionValue) = read(element, kAXPositionAttribute as CFString)
        let (sizeResult, sizeValue) = read(element, kAXSizeAttribute as CFString)
        guard positionResult == .success, sizeResult == .success,
              let positionValue = positionValue, let sizeValue = sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite,
              size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
