//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit

class StatusBarController: MenuBarItemProvider {
    
    //MARK: - Variables
    private var timer:Timer? = nil

    //MARK: - BarItems

    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil

    //MARK: - Notch Overflow
    private var notchOverflowController = NotchOverflowController()
    
    var toggleItem: NSStatusItem { btnExpandCollapse }
    var separatorItem: NSStatusItem { btnSeparate }
    var alwaysHiddenItem: NSStatusItem? { btnAlwaysHidden }
    
    // How hiding is achieved (separator lengths) lives in the engine; this class
    // owns the items, the UI, and when to collapse or expand.
    private lazy var menuBarEngine: MenuBarEngine = MenuBarEngineFactory.make(items: self)
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        return menuBarEngine.state == .collapsed
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        return menuBarEngine.isAlwaysHiddenSeparatorPlaced
    }
    
    private var isToggle = false

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?
    private var rearrangementMonitor: Any?
    private var localRearrangementMonitor: Any?
    private var rearrangementActive = false
    private var rearrangementEnd: DispatchWorkItem?
    private var shortcutCollapseTimer: Timer?
    private let deferredCollapse = DeferredCollapseRequest()
    private var loggedInvalidArrangement = false
    private var isPresentingFailure = false

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        let wc = PreferencesWindowController.shared
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
    }
    
    //MARK: - Methods
    init() {
        setupUI()
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupRearrangementMonitoring()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }

        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        shortcutCollapseTimer?.invalidate()
        rearrangementEnd?.cancel()
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = rearrangementMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localRearrangementMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func setupRearrangementMonitoring() {
        guard menuBarEngine is NativeVisibilityEngine else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        rearrangementMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MenuBarInteractionState.observe(event.type, at: event.timestamp)
            self?.handleRearrangementInput()
        }
        localRearrangementMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MenuBarInteractionState.observe(event.type, at: event.timestamp)
            self?.handleRearrangementInput()
            return event
        }
    }

    private func handleRearrangementInput() {
        let commandPressed = NSEvent.modifierFlags.contains(.command)
        guard commandPressed || rearrangementActive else { return }
        let mousePressed = MenuBarInteractionState.isLeftMousePressed
        if commandPressed && isMouseInMenuBar && !mousePressed && !isCollapsed {
            beginRearrangement()
        }
        guard rearrangementActive else { return }
        if commandPressed || mousePressed {
            rearrangementEnd?.cancel()
            rearrangementEnd = nil
            return
        }
        guard rearrangementEnd == nil else { return }
        // Let macOS finish reflowing after a drop before reading positions.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.rearrangementEnd = nil
            guard !NSEvent.modifierFlags.contains(.command), !MenuBarInteractionState.isLeftMousePressed else { return }
            self.rearrangementActive = false
            self.menuBarEngine.expand()
            self.autoCollapseIfNeeded()
        }
        rearrangementEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func beginRearrangement() {
        guard !rearrangementActive else { return }
        rearrangementActive = true
        timer?.invalidate()
        menuBarEngine.revealForRearrangement()
        didFailToCollapseMenuBar()
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCollapsed && self.isMouseInMenuBar &&
                    !NSEvent.modifierFlags.contains(.command) && !MenuBarInteractionState.isLeftMousePressed else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if self.isCollapsed && self.isMouseInMenuBar &&
                    !NSEvent.modifierFlags.contains(.command) && !MenuBarInteractionState.isLeftMousePressed {
                    self.expandMenubar()
                }
            }
        }
    }
    
    @objc private func handleScreenParametersChanged() {
        // Re-apply the recomputed length to the LIVE item when collapsed, or a
        // display hot-plug leaves the separator at a stale length (PR #354).
        let wasCollapsed = isCollapsed
        menuBarEngine.invalidateLayout()
        if wasCollapsed && Preferences.areSeparatorsHidden {
            menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: true)
        }
    }
    
    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
        // Create the engine now so the separator has its engine's normal width.
        _ = menuBarEngine
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
            button.target = self
            button.action = #selector(self.showContextMenuFromSeparator(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = menuBarEngine is NativeVisibilityEngine
                ? "Menu bar separator; drag the arrow to choose hidden icons".localized
                : "Command-drag this divider to choose which icons are hidden".localized
            button.setAccessibilityLabel("Hidden area divider".localized)
        }

        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Collapse hidden menu bar icons".localized
            button.setAccessibilityLabel(button.toolTip)
        }
        
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if let event = event {
            MenuBarInteractionState.observe(event.type, at: event.timestamp, nativeVisibility: menuBarEngine is NativeVisibilityEngine)
        }
        NSLog("MenuBar: arrow action event=\(event?.type.rawValue ?? 0) modifiers=\(event?.modifierFlags.rawValue ?? 0) appKitButtons=\(NSEvent.pressedMouseButtons) sessionLeft=\(MenuBarInteractionState.isLeftMousePressed)")
        // AXPress synthesis carries no NSEvent; the resolver maps nil to .toggle
        // so VoiceOver can operate the bar.
        switch ExpandCollapseActionResolver.action(eventType: event?.type, optionPressed: event?.modifierFlags.contains(.option) ?? false) {
        case .toggle:
            // AppKit can still report the button as pressed inside mouse-up.
            // Evaluate drag guards after this event has finished dispatching.
            StatusBarActionDispatcher.afterTracking(commandPressed: event?.modifierFlags.contains(.command) ?? false) {
                [weak self] in self?.expandCollapseIfNeeded()
            }
        case .contextMenu:
            // Right-click opens the same context menu the separator has (#356),
            // making settings reachable from the control everyone clicks.
            // The separators/always-hidden toggle stays on option-click.
            showContextMenu(from: sender)
        case .toggleSeparators:
            // Both option+left and option+right land here: separators toggle.
            self.showHideSeparatorsAndAlwayHideArea()
        }
    }

    @objc private func showContextMenuFromSeparator(sender: NSStatusBarButton) {
        showContextMenu(from: sender)
    }

    // Builds a brand-new NSMenu for every presentation rather than mutating
    // a reused one via a delegate callback (content changes on an
    // already-displayed-before NSMenu instance could leave its backing
    // window at a stale size until an unrelated redraw corrected it).
    //
    // Uses popUp(at:), not performClick(nil): this method is ITSELF called
    // from this same button's own action handler (a real click already in
    // progress). performClick(nil) here re-entered NSStatusBarButtonCell's
    // own sendAction dispatch, recursing into this handler again and
    // stack-overflowing (SIGSEGV, confirmed via crash report) - unlike
    // NotchOverflowController.showOverflowMenuFromSeparator, which is safe
    // because it's invoked from a *different* control's action (a menu
    // item), not from btnExpandCollapse's own click handler.
    //
    // Previously anchored at `button.bounds.maxY + 5` (5pt above the
    // button's TOP edge). For a menu-bar item that's essentially the
    // physical top of the screen, so once "Show Notch Items" made the menu
    // one row taller, that top row landed in the sliver above the visible
    // screen and AppKit showed its standard "content doesn't fit here"
    // scroll-indicator caret instead of rendering it - hovering over the
    // indicator scrolled the whole menu into view, which is what looked
    // like the item "appearing on hover". Anchoring at the button's BOTTOM
    // edge instead (y: 0, not bounds.maxY) keeps the menu entirely within
    // on-screen space, growing downward from below the button.
    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = getContextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
    }
    
    func showHideSeparatorsAndAlwayHideArea() {
        if isCollapsed || menuBarEngine.state == .calibrating { expandMenubar() }
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: false)
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if !self.isCollapsed {
            menuBarEngine.expand()
        }
        menuBarEngine.updateAlwaysHiddenSection(enabled: Preferences.alwaysHiddenSectionEnabled, separatorHidden: true)
    }
    
    func expandCollapseIfNeeded(isShortcut: Bool = false) {
        let commandPressed = NSEvent.modifierFlags.contains(.command)
        let action = MenuBarToggleActionResolver.action(state: menuBarEngine.state, isShortcut: isShortcut,
            commandPressed: commandPressed, leftMousePressed: MenuBarInteractionState.isLeftMousePressed,
            hasDeferredCollapse: deferredCollapse.isPending, engineBusy: menuBarEngine.isBusy)
        NSLog("MenuBar: toggle state=\(menuBarEngine.state) action=\(action) appKitButtons=\(NSEvent.pressedMouseButtons) sessionLeft=\(MenuBarInteractionState.isLeftMousePressed) command=\(commandPressed) locked=\(isToggle)")
        guard action != .ignore else { return }
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        switch action {
        case .expand:
            expandMenubar()
            if isShortcut && commandPressed && menuBarEngine is NativeVisibilityEngine { beginRearrangement() }
        case .collapse:
            collapseMenuBar(userInitiated: true)
        case .deferCollapse:
            timer?.invalidate()
            deferredCollapse.request()
            shortcutCollapseTimer = Timer.scheduledTimer(withTimeInterval: MenuBarInteractionState.releasePollingInterval, repeats: true) { [weak self] timer in
                guard let self = self else { return timer.invalidate() }
                let interactionActive = NSEvent.modifierFlags.contains(.command) ||
                    MenuBarInteractionState.isLeftMousePressed || self.rearrangementActive
                self.deferredCollapse.performIfReady(isInteractionActive: interactionActive, engine: self.menuBarEngine) {
                    timer.invalidate()
                    self.shortcutCollapseTimer = nil
                    self.collapseMenuBar(userInitiated: true)
                }
            }
        case .cancelDeferredCollapse:
            deferredCollapse.cancel()
            shortcutCollapseTimer?.invalidate()
            shortcutCollapseTimer = nil
            autoCollapseIfNeeded()
        case .ignore:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar(userInitiated: Bool = false) {
        guard !isPresentingFailure else { return }
        if userInitiated, let reason = menuBarEngine.failureReason,
           reason == .accessibilityPermission || reason == .unavailableAPI {
            presentHidingFailure(reason)
            return
        }
        guard !rearrangementActive, !NSEvent.modifierFlags.contains(.command), !MenuBarInteractionState.isLeftMousePressed else {
            autoCollapseIfNeeded()
            return
        }
        guard menuBarEngine.isArrangementValid && !self.isCollapsed else {
            if userInitiated && !menuBarEngine.isArrangementValid { presentHidingFailure(.layoutUnavailable) }
            if !menuBarEngine.isArrangementValid && !loggedInvalidArrangement {
                loggedInvalidArrangement = true
                NSLog("MenuBar: move the divider to the hidden side of the arrow; divider=\(String(describing: btnSeparate.button?.window?.frame)), arrow=\(String(describing: btnExpandCollapse.button?.window?.frame))")
            }
            autoCollapseIfNeeded()
            return
        }
        loggedInvalidArrangement = false

        menuBarEngine.collapse { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .collapsed:
                self.didCollapseMenuBar()
            case .unavailable:
                self.didFailToCollapseMenuBar()
                if userInitiated && !self.rearrangementActive &&
                    !NSEvent.modifierFlags.contains(.command) && !MenuBarInteractionState.isLeftMousePressed {
                    self.presentHidingFailure(self.menuBarEngine.failureReason ?? .layoutUnavailable)
                }
            }
        }
    }

    func showPermissionHelpIfNeeded() {
        guard menuBarEngine.failureReason == .accessibilityPermission else { return }
        presentHidingFailure(.accessibilityPermission)
    }

    private func presentHidingFailure(_ reason: MenuBarFailureReason) {
        guard !isPresentingFailure else { return }
        isPresentingFailure = true
        timer?.invalidate()
        defer {
            isPresentingFailure = false
            autoCollapseIfNeeded()
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        if reason == .accessibilityPermission {
            alert.messageText = "Hidden Bar needs permission".localized
            let location = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                ? "Privacy & Security → Device Control and Data Access".localized
                : "Privacy & Security → Accessibility".localized
            alert.informativeText = String(format: "Permission help message".localized, location)
            alert.addButton(withTitle: "Open System Settings".localized)
            alert.addButton(withTitle: "Later".localized)
        } else {
            alert.messageText = "Hidden Bar could not collapse the menu bar".localized
            alert.informativeText = reason == .unavailableAPI
                ? "Native hiding unavailable message".localized
                : "Menu bar layout unavailable message".localized
            alert.addButton(withTitle: "OK".localized)
        }
        NSLog("MenuBar: presenting user feedback for \(reason)")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if reason == .accessibilityPermission && response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // Nothing was hidden (the engine cannot hide on this system, or is waiting for
    // a permission), so show the bar as expanded, and restore the activation
    // policy in case the UI had already switched to collapsed.
    private func didFailToCollapseMenuBar() {
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.toolTip = "Collapse hidden menu bar icons".localized
            button.setAccessibilityLabel(button.toolTip)
        }
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
        }
        autoCollapseIfNeeded()
    }

    private func didCollapseMenuBar() {
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
            button.toolTip = "Expand hidden menu bar icons".localized
            button.setAccessibilityLabel(button.toolTip)
        }
        timer?.invalidate()
        timer = nil
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
    }

    private func expandMenubar() {
        guard isCollapsed || menuBarEngine.state == .calibrating else {return}
        timer?.invalidate()
        menuBarEngine.expand()
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.toolTip = "Collapse hidden menu bar icons".localized
            button.setAccessibilityLabel(button.toolTip)
        }
        autoCollapseIfNeeded()
        
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
        }
    }
    
    private func autoCollapseIfNeeded() {
        timer?.invalidate()
        timer = nil
        guard !rearrangementActive, !deferredCollapse.isPending else { return }
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers.
            if self.isMouseInMenuBar || self.isPreferencesWindowVisible ||
                NSEvent.modifierFlags.contains(.command) || MenuBarInteractionState.isLeftMousePressed {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }
    
    // Built fresh on every call (see showContextMenu(from:)), so every field
    // below reflects state as of THIS presentation - no separate "patch the
    // title after the fact" step is needed for the auto-collapse item.
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()

        // Notch overflow menu item (only on notch Macs, and only when enabled)
        if NotchOverflowController.hasNotch && Preferences.notchOverflowEnabled {
            let overflowItem = NSMenuItem(title: "Show Notch Items".localized, action: #selector(showNotchOverflow), keyEquivalent: "")
            overflowItem.target = self
            menu.addItem(overflowItem)
            menu.addItem(NSMenuItem.separator())
        }

        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)

        let toggleAutoHideTitle = Preferences.isAutoHide ? "Disable Auto Collapse" : "Enable Auto Collapse"
        let toggleAutoHideItem = NSMenuItem(title: toggleAutoHideTitle.localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc func updateAutoHide() {
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }

    @objc func showNotchOverflow() {
        notchOverflowController.showOverflowMenuFromSeparator(near: btnExpandCollapse)
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        if isCollapsed || menuBarEngine.state == .calibrating { expandMenubar() }
        if Preferences.alwaysHiddenSectionEnabled {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = NSStatusBar.system.statusItem(withLength: 0)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
            }
            self.btnAlwaysHidden?.autosaveName = "hiddenbar_terminate"
            self.btnAlwaysHidden?.isVisible = true
            menuBarEngine.updateAlwaysHiddenSection(enabled: true, separatorHidden: Preferences.areSeparatorsHidden)
        } else {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
            menuBarEngine.updateAlwaysHiddenSection(enabled: false, separatorHidden: Preferences.areSeparatorsHidden)
        }
        autoCollapseIfNeeded()
    }
}
