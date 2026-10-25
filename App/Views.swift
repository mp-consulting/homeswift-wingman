import SwiftUI

// Wingman's window, after apple-mail-mcp's menu bar panel: one surface, sections and rows, three tabs. The pairing
// code is the only emphasized block.

// MARK: Building blocks

struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// A list row: icon, title, detail, trailing control.
struct Row<Trailing: View>: View {
    let systemImage: String
    var iconColor: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(iconColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

extension Row where Trailing == EmptyView {
    init(systemImage: String, iconColor: Color = .secondary, title: String, detail: String) {
        self.init(systemImage: systemImage, iconColor: iconColor, title: title, detail: detail) { EmptyView() }
    }
}

struct SectionDivider: View {
    var body: some View { Divider().padding(.horizontal, 16).padding(.top, 6) }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            control.toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 34)
    }
}

extension PanelModel.Level {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// "just now", "5 min ago".
func ago(_ date: Date) -> String {
    Date().timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
}

// MARK: The panel

enum PanelTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case bridges = "Bridges"
    case settings = "Settings"

    var id: String { rawValue }
}

struct PanelView: View {
    @Bindable var model: PanelModel
    /// Fixes the tab (snapshots); nil follows the model.
    var fixedTab: PanelTab?

    private var tab: PanelTab { fixedTab ?? model.tab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TabBar(selected: tab, pairing: model.pairingCode != nil) { model.tab = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .home: HomeTab(model: model)
                    case .bridges: BridgesTab(model: model)
                    case .settings: SettingsTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bird.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text("Homeswift Wingman").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(model.level.color).frame(width: 7, height: 7)
                    Text(model.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch tab {
            case .home:
                Text(model.summary).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            case .bridges:
                Text("Port \(String(model.port)) · Bonjour \(UserDefaults.standard.bool(forKey: Settings.advertiseKey) ? "on" : "off")")
                    .font(.caption).foregroundStyle(.tertiary)
            case .settings:
                Text("Version \(model.version)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { model.perform("quit") } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Homeswift Wingman")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Segmented tab bar, with a dot on Bridges while a pairing code is showing.
struct TabBar: View {
    let selected: PanelTab
    let pairing: Bool
    let select: (PanelTab) -> Void
    /// One selection pill that slides from tab to tab, like a segmented control.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button { select(tab) } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        if tab == .bridges, pairing { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                    }
                    .font(.callout.weight(selected == tab ? .semibold : .regular))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .contentShape(Rectangle())
                    .background {
                        if selected == tab {
                            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selected == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
        .animatesChanges(of: selected)
    }
}

// MARK: Home

struct HomeTab: View {
    let model: PanelModel
    @State private var reading = false

    var body: some View {
        SectionHeader("Apple Home")
        Row(systemImage: "house", iconColor: .accentColor, title: model.summary, detail: eventsLine) {
            Button {
                reading = true
                model.perform("read")
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    reading = false
                }
            } label: {
                if reading { ProgressView().controlSize(.mini) } else { Text("Read All") }
            }
            .glassButton()
            .controlSize(.small)
            .disabled(reading)
            .help("Reads every value from the accessories now")
        }
        let homes = model.homes
        ForEach(homes) { home in
            SectionDivider()
            SectionHeader(homes.count > 1 ? home.name : "Rooms")
            ForEach(home.rooms) { room in RoomRow(room: room) }
        }
    }

    private var eventsLine: String {
        var parts = ["\(model.events.formatted()) value changes received"]
        if let last = model.lastEventAt { parts[0] += ", the last \(ago(last))" }
        if let read = model.lastRead { parts.append(read) }
        return parts.joined(separator: " · ")
    }
}

struct RoomRow: View {
    let room: PanelModel.Room
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 20)
                    Text(room.name).font(.callout)
                    Spacer()
                    if room.unreachable > 0 {
                        Label("\(room.unreachable)", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .help("\(room.unreachable) not responding")
                    }
                    Text("\(room.accessories.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            if open {
                ForEach(room.accessories) { accessory in
                    HStack(spacing: 8) {
                        StatusDot(color: accessory.reachable ? .green : .orange)
                        Text(accessory.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(accessory.reachable ? accessory.detail : "No Response").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 48)
                    .padding(.trailing, 16)
                    .frame(minHeight: 22)
                }
                .padding(.bottom, 4)
            }
        }
        .animatesChanges(of: open)
    }
}

// MARK: Bridges

struct BridgesTab: View {
    let model: PanelModel
    @State private var removing: String?

    var body: some View {
        if !model.serving {
            Row(systemImage: "exclamationmark.triangle.fill", iconColor: .red, title: "Not serving", detail: model.headline)
        } else if let code = model.pairingCode, let until = model.pairingUntil {
            PairingCode(code: code, until: until) { model.perform("cancelPairing") }
                .padding(.horizontal, 12)
                .padding(.top, 8)
        } else {
            Row(systemImage: "link.badge.plus", iconColor: .accentColor, title: "Pair a Homeswift bridge",
                detail: "Shows a code for ten minutes. Enter it where the bridge finds Wingman.") {
                Button("Pair") { model.perform("pair") }.glassButton(prominent: true).controlSize(.small)
            }
            .padding(.top, 4)
        }
        SectionDivider()
        SectionHeader("Paired bridges")
        let bridges = model.bridges
        if bridges.isEmpty {
            Text("None yet. A bridge finds Wingman over Bonjour, then asks for the code.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
        ForEach(bridges) { bridge in
            Row(systemImage: "server.rack", title: bridge.name,
                detail: bridge.lastSeenAt.map { "Last seen \(ago($0))" } ?? "Paired \(ago(bridge.pairedAt)), not seen since") {
                if removing == bridge.id {
                    HStack(spacing: 6) {
                        Button("Cancel") { removing = nil }.glassButton()
                        Button("Remove") {
                            removing = nil
                            model.perform("unpair:\(bridge.id)")
                        }
                        .glassButton(prominent: true)
                        .tint(.red)
                    }
                    .controlSize(.small)
                } else {
                    Button { removing = bridge.id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove \(bridge.name): it can no longer read or change anything")
                }
            }
        }
        .animatesChanges(of: removing)
        if model.serving {
            SectionDivider()
            SectionHeader("Certificate")
            Row(systemImage: "lock.shield", title: "SHA-256 \(model.formattedFingerprint(bytes: 6))…",
                detail: "Bridges pin it when they pair. Compare it with the one Homeswift shows.") {
                CopyButton(text: model.formattedFingerprint()) { model.copy($0) }
            }
        }
    }
}

/// The open pairing: the code large, how long it stays open, and Cancel. Tinted glass, the panel's one emphasized block.
struct PairingCode: View {
    let code: String
    let until: Date
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("PAIRING CODE").font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text("\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .textSelection(.enabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            HStack(spacing: 4) {
                Text("Enter it in Homeswift. Closes in")
                Text(timerInterval: Date()...max(until, Date()), countsDown: true).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Cancel", action: cancel).glassButton().controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 16, tint: .accentColor)
    }
}

struct CopyButton: View {
    let text: String
    let copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
        }
        .glassButton()
        .controlSize(.small)
        .help("Copy the whole fingerprint")
    }
}

// MARK: Settings tab

struct SettingsTab: View {
    @Bindable var model: PanelModel
    @AppStorage(Settings.advertiseKey) private var advertise = true
    @AppStorage(Settings.allowChangesKey) private var allowChanges = true
    @AppStorage(Settings.portKey) private var port = Int(LocalServer.defaultPort)
    @State private var portText = ""

    var body: some View {
        SectionHeader("Network")
        SettingRow("Advertise over Bonjour") { Toggle("", isOn: $advertise).labelsHidden() }
        SettingRow("Port") {
            HStack(spacing: 6) {
                TextField("Port", text: $portText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .onSubmit(applyPort)
                if portText != String(port) {
                    Button("Apply", action: applyPort).glassButton(prominent: true).disabled(!portIsValid)
                }
            }
        }
        Text("Bridges find Wingman as _homeswift-wingman._tcp. Without Bonjour, a bridge needs this Mac's address and the port.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 4)
        SectionDivider()
        SectionHeader("Bridges")
        SettingRow("Let bridges change accessories") { Toggle("", isOn: $allowChanges).labelsHidden() }
        Text("Off, bridges read homes and values but switch nothing. Locks, garage doors and alarms are never changed through Wingman.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 4)
        SectionDivider()
        SectionHeader("Startup")
        SettingRow("Open at login") {
            Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).labelsHidden()
        }
        if let error = model.launchAtLoginError {
            Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16)
        }
        Color.clear.frame(height: 0)
            .onAppear { portText = String(port) }
            .onChange(of: advertise) { model.perform("settings") }
            .onChange(of: allowChanges) { model.perform("settings") }
    }

    private var portIsValid: Bool { Int(portText).map { (1024...65535).contains($0) } ?? false }

    private func applyPort() {
        guard portIsValid, let value = Int(portText) else {
            portText = String(port)
            return
        }
        port = value
        model.perform("settings")
    }
}
