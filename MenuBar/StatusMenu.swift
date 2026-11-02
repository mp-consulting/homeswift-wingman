import AppKit
import Darwin

/// Catalyst owns HomeKit; this AppKit bundle owns the anchored menu-bar panel.
/// AppKit controls avoid loading a second (macOS) SwiftUI runtime into the Catalyst process.
@MainActor
@objc(WingmanStatusMenu)
public final class WingmanStatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = WingmanPopoverController()
    #if !APP_STORE
    private let updater = Updater()
    #endif
    private var window: MenuPanel?
    private var outsideClick: Any?
    private var localClick: Any?
    @objc public var actionHandler: ((String) -> Void)?
    @objc public var model: [String: Any] = [:] {
        didSet { refreshPanel() }
    }

    override public init() {
        super.init()
        item.button?.image = WingmanIcon.image()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        #if !APP_STORE
        updater.automaticChecks = { UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true }
        updater.onChange = { [weak self] in self?.refreshPanel() }
        panel.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case "checkUpdate": Task { await self.updater.check() }
            case "installUpdate":
                if let release = self.updater.availableRelease { Task { await self.updater.install(release) } }
            case "releaseNotes":
                if let release = self.updater.availableRelease { NSWorkspace.shared.open(release.pageURL) }
            case let value where value.hasPrefix("setting:automaticUpdateChecks:"):
                UserDefaults.standard.set(value.hasSuffix(":1"), forKey: "automaticUpdateChecks")
                self.refreshPanel()
            default: self.actionHandler?(action)
            }
        }
        updater.start()
        #else
        panel.perform = { [weak self] action in self?.actionHandler?(action) }
        #endif
        refreshPanel()
        // Catalyst opens an empty host window at launch and whenever the app is activated with
        // none visible, e.g. after the HomeKit permission prompt. It must stay on screen: HomeKit
        // refuses accessory writes (HMErrorDomain 80) from an app with no window on screen. So it is
        // made invisible just before AppKit first shows it, and on every update pass after that.
        HostWindow.concealBeforeOrdering()
        for name in [NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(hideHostWindows), name: name, object: nil)
        }
        DispatchQueue.main.async { [weak self] in self?.hideHostWindows() }
    }

    @objc private func hideHostWindows() {
        for window in NSApp.windows { HostWindow.conceal(window) }
    }


    private func refreshPanel() {
        var value = model
        #if !APP_STORE
        value["automaticUpdateChecks"] = updater.automaticChecks()
        value["updateEnabled"] = updater.isEnabled
        value["updateBlocker"] = updater.installBlocker
        switch updater.state {
        case .idle: value["updateStatus"] = "Check for a newer version."
        case .checking: value["updateStatus"] = "Checking for updates…"; value["updateBusy"] = true
        case .upToDate: value["updateStatus"] = "Wingman is up to date."
        case .available(let release):
            value["updateStatus"] = "Version \(release.version) is available."
            value["updateAvailable"] = true
        case .installing:
            value["updateStatus"] = updater.installProgress?.step ?? "Installing…"
            value["updateProgress"] = updater.installProgress?.fraction ?? 0
            value["updateBusy"] = true
        case .failed(let message): value["updateStatus"] = message
        }
        #else
        value["appStoreDistribution"] = true
        #endif
        panel.model = value
    }

    @objc public func showPanel() {
        guard let button = item.button, let anchorWindow = button.window else { return }
        if window == nil {
            let window = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.contentViewController = panel
            window.setContentSize(NSSize(width: 380, height: 520))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.transient, .fullScreenAuxiliary]
            window.dismiss = { [weak self] in self?.closePanel() }
            self.window = window
        }
        guard let window else { return }
        panel.render()
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen?.visibleFrame ?? anchor
        // Align the leading edge with the menu-bar item; clamp at the screen edge.
        let x = min(max(anchor.minX, screen.minX + 6), screen.maxX - window.frame.width - 6)
        // Leave breathing room below the menu bar, like a native MenuBarExtra window.
        let menuBarGap: CGFloat = 6
        window.setFrameOrigin(NSPoint(x: x, y: anchor.minY - menuBarGap - window.frame.height))
        window.makeKeyAndOrderFront(nil)
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePanel() }
            }
            localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window !== self.window, event.window !== self.item.button?.window { self.closePanel() }
                }
                return event
            }
        }
    }

    private func closePanel() {
        panel.cancelRemoval()
        window?.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
        if let localClick { NSEvent.removeMonitor(localClick); self.localClick = nil }
    }

    @objc private func toggle() {
        if window?.isVisible == true { closePanel() } else { showPanel() }
    }
}

@MainActor
private final class MenuPanel: NSPanel {
    var dismiss: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss() }
}

@MainActor
private final class BrandBadge: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let size = min(32, min(bounds.width, bounds.height))
        let square = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        WingmanIcon.badge(in: square)
    }
}

@MainActor
private final class PanelMaterial: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            border.lineWidth = 1
            border.stroke()
        }
    }
}

@MainActor
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WingmanPopoverController: NSViewController, NSTextFieldDelegate {
    var perform: (String) -> Void = { _ in }
    var model: [String: Any] = [:] { didSet { if isViewLoaded { render() } } }
    private let heading = NSTextField(labelWithString: "Homeswift Wingman")
    private let status = NSTextField(wrappingLabelWithString: "Starting…")
    private var selectedTab = 0
    private var pendingRemoval: String?
    private weak var pairingCopyFeedback: NSTextField?
    private var pairingCopyReset: Task<Void, Never>?
    private var tabButtons: [PillTab] = []
    private let portError = NSTextField(wrappingLabelWithString: "")
    private let statusDot = NSImageView()
    private let footerText = NSTextField(labelWithString: "")
    private let body = FlippedStack()
    private var expandedRooms: Set<String> = []
    private var port: NSTextField?
    private var applyPort: NSButton?
    private var portCheck: Task<Void, Never>?
    private var renderedBody: NSDictionary?

    override func loadView() {
        let root: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            root = NSView()
            glass.contentView = root
            view = glass
        } else {
            let material = PanelMaterial()
            material.material = .popover
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 12
            material.layer?.masksToBounds = true
            root = material
            view = material
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        func full(_ child: NSView) {
            stack.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .panelSecondary
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let state = NSStackView(views: [statusDot, status])
        state.spacing = 6
        let titles = NSStackView(views: [heading, state])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let icon = BrandBadge()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let header = NSStackView(views: [icon, titles, NSView()])
        header.spacing = 12
        header.alignment = .centerY
        full(padded(header, x: 16, top: 12, bottom: 10))
        let tabs = PillTrack()
        let segments = NSStackView()
        segments.distribution = .fillEqually
        segments.spacing = 2
        segments.translatesAutoresizingMaskIntoConstraints = false
        tabs.addSubview(segments)
        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: tabs.leadingAnchor, constant: 2),
            segments.trailingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: -2),
            segments.topAnchor.constraint(equalTo: tabs.topAnchor, constant: 2),
            segments.bottomAnchor.constraint(equalTo: tabs.bottomAnchor, constant: -2),
        ])
        for (index, title) in ["Home", "Bridges", "Settings"].enumerated() {
            let tab = PillTab(title: title, target: self, action: #selector(selectTab(_:)))
            tab.tag = index
            tab.isBordered = false
            tab.heightAnchor.constraint(equalToConstant: 26).isActive = true
            segments.addArrangedSubview(tab)
            tabButtons.append(tab)
        }
        full(padded(tabs, x: 12, top: 0, bottom: 6))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = body
        full(scroll)
        body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        let divider = NSBox()
        divider.boxType = .separator
        full(divider)
        footerText.font = .systemFont(ofSize: 11)
        footerText.textColor = .panelSecondary
        footerText.lineBreakMode = .byTruncatingTail
        let quit = button("", "quit")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Homeswift Wingman")
        quit.isBordered = false
        quit.toolTip = "Quit Homeswift Wingman"
        let footer = NSStackView(views: [footerText, NSView(), quit])
        full(padded(footer, x: 12, top: 8, bottom: 8))
        render()
    }

    private func padded(_ child: NSView, x: CGFloat = 16, top: CGFloat = 6, bottom: CGFloat = 6) -> NSView {
        let wrapper = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: x),
            child.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -x),
            child.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            child.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom),
        ])
        return wrapper
    }

    @objc private func selectTab(_ sender: NSButton) { pendingRemoval = nil; selectedTab = sender.tag; render(); body.enclosingScrollView?.contentView.scroll(to: .zero) }

    func render() {
        guard isViewLoaded else { return }
        status.stringValue = model["headline"] as? String ?? "Starting…"
        statusDot.contentTintColor = model["level"] as? String == "ok" ? .systemGreen : model["level"] as? String == "error" ? .systemRed : .systemOrange
        for tab in tabButtons {
            tab.selected = tab.tag == selectedTab
            tab.setAccessibilityValue(tab.selected ? "Selected" : "")
            tab.needsDisplay = true
        }
        footerText.stringValue = selectedTab == 0 ? model["summary"] as? String ?? "" : selectedTab == 1 ? "Port \(model["port"] as? Int ?? 8619)" : "Version \(model["version"] as? String ?? "")"
        // Live HomeKit events must not replace a port field while someone is typing.
        if selectedTab == 2, let editor = port?.currentEditor(), view.window?.firstResponder === editor { return }
        // Value events update the header/footer without replacing rows under the pointer.
        let keys: [String]
        switch selectedTab {
        case 1: keys = ["pairingCode", "pairingUntil", "serving", "bridges", "fingerprint", "pairingError", "demo", "demoLog", "demoBusy", "demoPaired"]
        case 2: keys = ["advertise", "allowChanges", "allowSecurity", "allowStructure", "launchAtLogin", "demo", "port", "listening", "settingsError", "automaticUpdateChecks", "updateEnabled", "updateBlocker", "updateStatus", "updateBusy", "updateAvailable", "updateProgress"]
        default: keys = ["homes", "lastRead", "demo", "offerDemo"]
        }
        let content = model.filter { keys.contains($0.key) }
        let signature = NSDictionary(dictionary: ["tab": selectedTab, "rooms": expandedRooms.sorted(), "removal": pendingRemoval ?? "", "content": content])
        if let renderedBody, renderedBody.isEqual(signature) { return }
        renderedBody = signature
        let origin = body.enclosingScrollView?.contentView.bounds.origin ?? .zero
        body.arrangedSubviews.forEach { body.removeArrangedSubview($0); $0.removeFromSuperview() }
        port = nil
        switch selectedTab {
        case 1: bridges()
        case 2: settings()
        default: homes()
        }
        body.layoutSubtreeIfNeeded()
        body.enclosingScrollView?.contentView.scroll(to: origin)
    }

    private func label(_ text: String, small: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: small ? 11 : 13)
        if small { field.textColor = .panelSecondary }
        return field
    }

    private func button(_ title: String, _ action: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(run(_:)))
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        else { button.bezelStyle = .rounded }
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(action)
        return button
    }

    private func add(_ view: NSView, verticalPadding: CGFloat = 6) {
        let wrapper = padded(view, top: verticalPadding, bottom: verticalPadding)
        body.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func section(_ text: String) {
        if !body.arrangedSubviews.isEmpty {
            let divider = NSBox()
            divider.boxType = .separator
            add(divider)
        }
        let title = label(text.uppercased(), small: true)
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        add(title)
    }

    private func detailRow(_ title: String, detail: String, symbol: String, control: NSView? = nil) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .panelSecondary
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let texts = NSStackView(views: [label(title), label(detail, small: true)])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts, NSView()] + (control.map { [$0] } ?? []))
        row.spacing = 12
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        add(row)
    }

    private func row(_ title: String, _ control: NSView) {
        let text = label(title)
        let row = NSStackView(views: [text, NSView(), control])
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        add(row)
    }

    /// A tinted box that marks synthetic data, so a screenshot of demo mode cannot pass for a real home.
    private func demoBanner(_ text: String, actions: [NSButton]) {
        let title = label("DEMO MODE", small: true)
        title.font = .systemFont(ofSize: 10, weight: .bold)
        title.textColor = .systemOrange
        let body = label(text, small: true)
        let stack = NSStackView(views: [title, body] + (actions.isEmpty ? [] : [NSStackView(views: actions + [NSView()])]))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let box = DemoBox()
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("Demo mode")
        add(box)
    }

    private func homes() {
        if model["demo"] as? Bool == true {
            demoBanner("This home and its accessories are synthetic, for trying Wingman without HomeKit devices. Paired bridges see this home instead of yours, and nothing in HomeKit is read or changed.",
                       actions: [button("Exit Demo Mode", "setting:demoMode:0")])
        } else if model["offerDemo"] as? Bool == true {
            add(label("No homes to show. Allow Home access in System Settings › Privacy & Security › Home, or try Wingman with a synthetic home.", small: true))
            add(button("Try Demo Mode", "setting:demoMode:1"))
        }
        row("Accessories", button("Refresh", "read"))
        if let read = model["lastRead"] as? String { add(label(read, small: true)) }
        for home in model["homes"] as? [[String: Any]] ?? [] {
            section(home["name"] as? String ?? "Home")
            for room in home["rooms"] as? [[String: Any]] ?? [] {
                guard let key = room["id"] as? String else { continue }
                let accessories = room["accessories"] as? [[String: Any]] ?? []
                let open = expandedRooms.contains(key)
                let unavailable = accessories.filter { $0["reachable"] as? Bool == false }.count
                let expand = RoomButton(title: room["name"] as? String ?? "Room", target: self, action: #selector(run(_:)))
                expand.identifier = NSUserInterfaceItemIdentifier("room:\(key)")
                expand.count = accessories.count
                expand.expanded = open
                expand.unavailable = unavailable
                expand.isBordered = false
                expand.setAccessibilityLabel("\(expand.title), \(accessories.count) accessories\(unavailable > 0 ? ", \(unavailable) not responding" : "")")
                expand.setAccessibilityHelp(open ? "Collapse room" : "Expand room")
                expand.heightAnchor.constraint(equalToConstant: 30).isActive = true
                add(expand, verticalPadding: 3)
                if open {
                    if accessories.isEmpty { add(label("No accessories in this room", small: true)) }
                    for accessory in accessories {
                        let reachable = accessory["reachable"] as? Bool ?? true
                        let title = label(accessory["name"] as? String ?? "Accessory")
                        title.maximumNumberOfLines = 2
                        let detail = label(reachable ? accessory["detail"] as? String ?? "Accessory" : "No response", small: true)
                        if !reachable { detail.textColor = .systemOrange }
                        let text = NSStackView(views: [title, detail])
                        text.orientation = .vertical
                        text.alignment = .leading
                        text.spacing = 2
                        let symbol = accessory["symbol"] as? String ?? "square.stack.3d.up"
                        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)!
                        let icon = NSImageView(image: image)
                        icon.contentTintColor = reachable ? .panelSecondary : .systemOrange
                        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                        let entry = NSStackView(views: [icon, text, NSView()])
                        entry.spacing = 10
                        add(padded(entry, x: 22, top: 0, bottom: 0), verticalPadding: 3)
                    }
                }
            }
        }
    }

    private func bridges() {
        if let error = model["pairingError"] as? String {
            let message = label(error, small: true)
            message.textColor = .systemRed
            add(message)
        }
        if model["demo"] as? Bool == true {
            let busy = model["demoBusy"] as? Bool == true
            let run = button(busy ? "Running…" : model["demoPaired"] as? Bool == true ? "Run Demo Bridge Again" : "Pair Demo Bridge", "demoBridge")
            run.isEnabled = !busy && model["pairingCode"] == nil
            demoBanner("The demo bridge is part of Wingman. It pairs over TLS with a fresh code, reads the demo home, switches a light and is refused a lock change, as a Homeswift bridge would.",
                       actions: [run])
            for line in model["demoLog"] as? [String] ?? [] { add(label("• \(line)", small: true), verticalPadding: 2) }
        }
        section("Pair a bridge")
        if let code = model["pairingCode"] as? String {
            add(label("PAIRING CODE", small: true))
            let codeLabel = button("\(code.prefix(3)) \(code.suffix(3))", "copyPairingCode")
            codeLabel.isBordered = false
            codeLabel.font = .monospacedDigitSystemFont(ofSize: 32, weight: .semibold)
            codeLabel.contentTintColor = .labelColor
            codeLabel.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            codeLabel.imagePosition = .imageTrailing
            codeLabel.toolTip = "Click to copy pairing code"
            codeLabel.setAccessibilityLabel("Copy pairing code")
            let feedback = label("Copied", small: true)
            feedback.textColor = .systemGreen
            feedback.alphaValue = 0
            pairingCopyFeedback = feedback
            let codeRow = NSStackView(views: [codeLabel, feedback, NSView()])
            codeRow.spacing = 10
            codeRow.alignment = .centerY
            add(codeRow)
            add(label("Enter this code in Homeswift. Pairing closes automatically after ten minutes.", small: true))
            add(button("Cancel Pairing", "cancelPairing"))
        } else if model["serving"] as? Bool == true {
            add(button("Pair a Homeswift Bridge…", "pair"))
        }
        section("Paired bridges")
        for bridge in model["bridges"] as? [[String: Any]] ?? [] {
            let id = bridge["id"] as? String ?? ""
            if pendingRemoval == id {
                detailRow(bridge["name"] as? String ?? "Bridge", detail: "Remove this bridge? It will lose access until you pair it again.", symbol: "exclamationmark.triangle")
                let remove = button("Remove Bridge", "confirmRemoval:\(id)")
                remove.contentTintColor = .systemRed
                add(NSStackView(views: [NSView(), button("Cancel", "cancelRemoval"), remove]))
            } else {
                detailRow(bridge["name"] as? String ?? "Bridge", detail: "Paired with Wingman", symbol: "network", control: button("Remove…", "unpair:\(id)"))
            }
        }
        if let fingerprint = model["fingerprint"] as? String, !fingerprint.isEmpty {
            add(label("Certificate fingerprint", small: true))
            let value = label(fingerprint, small: true)
            value.isSelectable = true
            add(value)
            add(button("Copy fingerprint", "copyFingerprint"))
        }
    }

    private func settings() {
        portCheck?.cancel()
        section("Connection & access")
        for (key, title) in [("advertise", "Advertise over Bonjour"), ("allowChanges", "Let bridges change accessories"),
                             ("allowSecurity", "Let bridges operate locks and doors"),
                             ("allowStructure", "Let bridges edit rooms, scenes and automations"), ("launchAtLogin", "Open at login")] {
            let control = NSSwitch()
            control.controlSize = .small
            control.setAccessibilityLabel(title)
            control.state = model[key] as? Bool == true ? .on : .off
            control.identifier = NSUserInterfaceItemIdentifier(key)
            control.target = self
            control.action = #selector(setting(_:))
            row(title, control)
        }
        let field = NSTextField(string: "\(model["port"] as? Int ?? 8619)")
        field.placeholderString = "Port"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.setAccessibilityLabel("Port")
        port = field
        field.delegate = self
        let apply = button("Apply", "port")
        applyPort = apply
        row("Port", NSStackView(views: [field, apply]))
        portError.stringValue = ""
        portError.textColor = .systemRed
        portError.font = .systemFont(ofSize: 11)
        portError.isHidden = true
        add(portError)
        _ = checkPort()
        add(label("Without Bonjour, bridges need this Mac’s address. Disabling changes stops bridges changing accessories, running scenes and editing the home. Locks, garage doors and alarms are changed only while bridges may operate locks and doors. Editing rooms, scenes and automations changes your home on every device, and needs you to administer the home.", small: true))
        if let error = model["settingsError"] as? String { add(label(error, small: true)) }
        section("Demo")
        let demo = NSSwitch()
        demo.controlSize = .small
        demo.state = model["demo"] as? Bool == true ? .on : .off
        demo.identifier = NSUserInterfaceItemIdentifier("demoMode")
        demo.setAccessibilityLabel("Demo mode")
        demo.target = self
        demo.action = #selector(setting(_:))
        row("Demo mode", demo)
        add(label("Serves a synthetic home instead of yours, to try Wingman without HomeKit devices or a Homeswift bridge. Turning it off removes the demo bridge.", small: true))
        section("Privacy")
        add(label("Wingman shares your Home data only with bridges you explicitly pair. A bridge may forward data to services you configure, including AI providers. Remove a bridge to revoke its access; disable changes for read-only access. Wingman does not send analytics to its developer.", small: true))
        section("Updates")
        #if APP_STORE
        add(label("Updates are delivered by the App Store or TestFlight.", small: true))
        #else
        let automatic = NSSwitch()
        automatic.controlSize = .small
        automatic.state = model["automaticUpdateChecks"] as? Bool == false ? .off : .on
        automatic.identifier = NSUserInterfaceItemIdentifier("automaticUpdateChecks")
        automatic.setAccessibilityLabel("Check automatically every day")
        automatic.target = self
        automatic.action = #selector(setting(_:))
        row("Check automatically every day", automatic)
        let enabled = model["updateEnabled"] as? Bool == true
        let busy = model["updateBusy"] as? Bool == true
        add(label(enabled ? model["updateStatus"] as? String ?? "Check for a newer version." : "Updates require a build signed by Wingman’s developer.", small: true))
        if let progress = model["updateProgress"] as? Double {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = progress
            bar.setAccessibilityLabel("Update installation progress")
            add(bar)
        }
        if model["updateAvailable"] as? Bool == true {
            let install = button("Install & Relaunch", "installUpdate")
            install.isEnabled = enabled && !busy && model["updateBlocker"] == nil
            add(NSStackView(views: [install, button("Release Notes", "releaseNotes")]))
            if let blocker = model["updateBlocker"] as? String { add(label(blocker, small: true)) }
        } else {
            let check = button("Check for Updates…", "checkUpdate")
            check.isEnabled = enabled && !busy
            add(check)
        }
        #endif
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === port else { return }
        portCheck?.cancel()
        applyPort?.isEnabled = false
        portError.isHidden = false
        guard portValue != nil else {
            portError.textColor = .systemRed
            portError.stringValue = "Enter a port between 1 and 65535."
            return
        }
        portError.textColor = .panelSecondary
        portError.stringValue = "Checking port…"
        portCheck = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = self.checkPort()
        }
    }

    private var portValue: UInt16? {
        guard let text = port?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    @discardableResult private func checkPort() -> Bool {
        portError.isHidden = false
        applyPort?.isEnabled = false
        guard let value = portValue else {
            portError.textColor = .systemRed
            portError.stringValue = "Enter a port between 1 and 65535."
            return false
        }
        if Int(value) == model["port"] as? Int, model["listening"] as? Bool == true {
            portError.textColor = .panelSecondary
            portError.stringValue = "Port \(value) is currently used by Wingman."
            return false
        }
        if let error = PortAvailability.problem(value) {
            portError.textColor = .systemRed
            portError.stringValue = error
            return false
        }
        portError.textColor = .systemGreen
        portError.stringValue = "Port \(value) is available."
        applyPort?.isEnabled = true
        return true
    }

    @objc private func setting(_ sender: NSSwitch) {
        guard let key = sender.identifier?.rawValue else { return }
        perform("setting:\(key):\(sender.state == .on ? "1" : "0")")
    }

    func cancelRemoval() {
        guard pendingRemoval != nil else { return }
        pendingRemoval = nil
        render()
    }

    @objc private func run(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue else { return }
        if action.hasPrefix("room:") {
            let key = String(action.dropFirst(5))
            if !expandedRooms.insert(key).inserted { expandedRooms.remove(key) }
            render()
        } else if action == "copyPairingCode" {
            guard let code = model["pairingCode"] as? String else { return }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(code, forType: .string) else { return }
            sender.toolTip = "Copied"
            pairingCopyFeedback?.alphaValue = 1
            pairingCopyReset?.cancel()
            pairingCopyReset = Task { @MainActor [weak feedback = pairingCopyFeedback, weak sender] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                feedback?.alphaValue = 0
                sender?.toolTip = "Click to copy pairing code"
            }
        } else if action == "copyFingerprint" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model["fingerprint"] as? String ?? "", forType: .string)
        } else if action == "port" {
            portCheck?.cancel()
            guard checkPort(), let value = port?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            view.window?.makeFirstResponder(nil)
            perform("port:\(value)")
        } else if action == "cancelRemoval" {
            cancelRemoval()
        } else if action.hasPrefix("confirmRemoval:") {
            let id = String(action.dropFirst("confirmRemoval:".count))
            guard pendingRemoval == id,
                  (model["bridges"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == id }) else { return }
            pendingRemoval = nil
            perform("unpair:\(id)")
            render()
        } else if action.hasPrefix("unpair:") {
            pendingRemoval = String(action.dropFirst("unpair:".count))
            render()
        } else { perform(action) }
    }
}

private extension NSColor {
    static var panelSecondary: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.28, alpha: 1)
        }
    }
}

/// Catalyst's empty host window, kept on screen for HomeKit but transparent, click-through and out of the way.
@MainActor
private enum HostWindow {
    static func conceal(_ window: NSWindow) {
        guard window.alphaValue != 0, NSStringFromClass(type(of: window)).contains("UINSWindow") else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        window.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
    }

    private static var installed = false

    /// Wraps `-[NSWindow orderWindow:relativeTo:]`, which every way of showing a window goes through, so the host
    /// window is transparent before its first frame reaches the screen.
    static func concealBeforeOrdering() {
        guard !installed, let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))) else { return }
        installed = true
        typealias Order = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Order.self)
        let selector = #selector(NSWindow.order(_:relativeTo:))
        let replacement: @convention(block) (NSWindow, Int, Int) -> Void = { window, mode, other in
            if mode != NSWindow.OrderingMode.out.rawValue { MainActor.assumeIsolated { conceal(window) } }
            original(window, selector, mode, other)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

/// The orange outline and tint that mark demo mode, redrawn for light and dark appearances.
@MainActor
private final class DemoBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.systemOrange.withAlphaComponent(0.1).setFill()
        shape.fill()
        NSColor.systemOrange.withAlphaComponent(0.6).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// The entire room header is a button; counts and disclosure stay aligned as names grow.
@MainActor
private final class RoomButton: NSButton {
    var count = 0
    var unavailable = 0
    var expanded = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        // Seed state after a real list change, even when the pointer has not moved.
        let inside = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        if hovering != inside { hovering = inside; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25) : hovering ? NSColor.quaternaryLabelColor : NSColor.controlBackgroundColor.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let symbol = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        symbol?.draw(in: NSRect(x: 12, y: bounds.midY - 5, width: 10, height: 10))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 32, y: bounds.midY - 8, width: bounds.width - 100, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        let countText = unavailable > 0 ? "\(count) · !" : String(count)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: unavailable > 0 ? NSColor.systemOrange : NSColor.panelSecondary]
        let width = (countText as NSString).size(withAttributes: attributes).width
        (countText as NSString).draw(at: NSPoint(x: bounds.width - width - 12, y: bounds.midY - 7), withAttributes: attributes)
    }
}

/// Mirrors apple-mail-mcp's TabBar: 9-point track, 7-point selection, no dividers.
@MainActor
private final class PillTrack: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
private final class PillTab: NSButton {
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.20 : 0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Probe both address families without accepting connections or changing the running listener.
private enum PortAvailability {
    static func problem(_ port: UInt16) -> String? {
        var descriptors: [Int32] = []
        defer { descriptors.forEach { Darwin.close($0) } }
        for family in [AF_INET6, AF_INET] {
            let descriptor = socket(family, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return "Unable to check port \(port)." }
            descriptors.append(descriptor)
            let result: Int32
            if family == AF_INET6 {
                var onlyIPv6: Int32 = 1
                guard setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIPv6, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return "Unable to check port \(port)." }
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            } else {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if result != 0 {
                return errno == EADDRINUSE ? "Port \(port) is already in use." : errno == EACCES ? "Permission denied for port \(port)." : "Unable to check port \(port)."
            }
        }
        return nil
    }
}
