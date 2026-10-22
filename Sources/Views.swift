import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Design tokens

enum Palette {
    static let good = Color(red: 0.27, green: 0.76, blue: 0.53)
    static let warn = Color(red: 0.97, green: 0.68, blue: 0.24)
    static let hot  = Color(red: 0.95, green: 0.36, blue: 0.36)

    static func tint(_ severity: Double) -> Color {
        severity < 0.6 ? good : (severity < 0.85 ? warn : hot)
    }
}

enum Fmt {
    static func mem(_ bytes: UInt64) -> String {
        if bytes == 0 { return "·" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    static func num(_ v: Double) -> String {
        if v < 0.05 { return "0" }
        return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    static func duration(minutes m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func uptime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(mm)m" }
        return "\(mm)m"
    }

    static func thermalWord(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    static func thermalSeverity(_ s: ProcessInfo.ThermalState) -> Double {
        switch s {
        case .nominal: return 0.2
        case .fair: return 0.65
        case .serious: return 0.88
        case .critical: return 1
        @unknown default: return 0.2
        }
    }
}

enum ListTab: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case background = "Background"
    var id: String { rawValue }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @State private var tab: ListTab = .apps
    @State private var sort: SortKey = .cpu
    @State private var query = ""
    @State private var expanded: Set<pid_t> = []

    private var rows: [UsageRow] {
        let base = tab == .apps ? monitor.apps : monitor.background
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered: [UsageRow]
        if q.isEmpty {
            filtered = base
        } else {
            filtered = base.filter { row in
                row.name.lowercased().contains(q)
                    || String(row.id) == q
                    || row.children.contains { $0.name.lowercased().contains(q) }
            }
        }
        let key = sort
        return filtered.sorted { $0.value(key) > $1.value(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PulseHeader(monitor: monitor)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            StatsStrip(monitor: monitor)
                .padding(.horizontal, 12)

            controls
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)

            columnHeader
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            PulseFooter(monitor: monitor)
        }
        .frame(width: 430, height: 640)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { monitor.isVisible = true }
        .onDisappear { monitor.isVisible = false }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                Text("Apps  \(monitor.apps.count)").tag(ListTab.apps)
                Text("Background  \(monitor.background.count)").tag(ListTab.background)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search by name or PID", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.055)))
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(tab == .apps ? "APP" : "PROCESS")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
            sortHeader(.cpu, width: RowMetrics.cpu)
            sortHeader(.memory, width: RowMetrics.memory)
            sortHeader(.energy, width: RowMetrics.energy)
            Color.clear.frame(width: RowMetrics.action, height: 1)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func sortHeader(_ key: SortKey, width: CGFloat) -> some View {
        Button { sort = key } label: {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                Text(key.rawValue)
                if sort == key {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .frame(width: width)
            .foregroundStyle(sort == key ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private var list: some View {
        let items = rows
        let top = max(items.first?.value(sort) ?? 0, 0.0001)
        let key = sort
        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { row in
                    VStack(spacing: 1) {
                        RowView(row: row, sort: key, maxValue: top, depth: 0,
                                isExpanded: expanded.contains(row.id), monitor: monitor) {
                            toggle(row)
                        }
                        if expanded.contains(row.id) {
                            ForEach(row.children.sorted { $0.value(key) > $1.value(key) }) { child in
                                RowView(row: child, sort: key, maxValue: top, depth: 1,
                                        isExpanded: false, monitor: monitor, onToggle: nil)
                            }
                        }
                    }
                }
                if items.isEmpty {
                    Text(query.isEmpty ? "Collecting data" : "Nothing matches \u{201C}\(query)\u{201D}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func toggle(_ row: UsageRow) {
        guard !row.children.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = monitor.toast {
            Text(t)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.bottom, 52)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

enum RowMetrics {
    static let cpu: CGFloat = 46
    static let memory: CGFloat = 62
    static let energy: CGFloat = 50
    static let action: CGFloat = 20
}

// MARK: - Header

struct PulseHeader: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.48, blue: 1.0),
                                                  Color(red: 0.55, green: 0.33, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 24, height: 24)

            Text("Pulse")
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            Spacer()

            Text("Up \(Fmt.uptime(ProcessInfo.processInfo.systemUptime))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stat tiles

struct StatsStrip: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        let sys = monitor.system
        let therm = monitor.thermal
        let memFrac = sys.memTotal > 0 ? Double(sys.memUsed) / Double(sys.memTotal) : 0

        HStack(spacing: 8) {
            StatTile(title: "CPU",
                     value: "\(Int(sys.cpu.rounded()))%",
                     caption: "\(sys.cores) cores",
                     fraction: sys.cpu / 100,
                     history: monitor.cpuHistory)
                .help("Total CPU load across all cores")

            StatTile(title: "Memory",
                     value: Fmt.gb(sys.memUsed),
                     caption: "of \(Int((Double(sys.memTotal) / 1_073_741_824).rounded())) GB",
                     fraction: memFrac,
                     severity: max(sys.pressure / 100, memFrac * 0.7))
                .help("Pressure \(Int(sys.pressure))%, swap \(Fmt.mem(sys.swapUsed))")

            temperatureTile(therm)

            if let b = monitor.battery {
                batteryTile(b)
            }
        }
    }

    private func temperatureTile(_ t: ThermalReading) -> some View {
        let stateSev = Fmt.thermalSeverity(t.state)
        var help = "Thermal state: \(Fmt.thermalWord(t.state))"
        if let g = t.gpu { help += ", GPU \(Int(g.rounded()))°" }
        if let s = t.ssd { help += ", SSD \(Int(s.rounded()))°" }
        if let b = t.battery { help += ", battery \(Int(b.rounded()))°" }
        if let h = t.hottest { help += ", hottest sensor \(Int(h.rounded()))°" }

        if let c = t.cpu {
            let frac = (c - 30) / 70
            return StatTile(title: "Temp",
                            value: "\(Int(c.rounded()))°C",
                            caption: Fmt.thermalWord(t.state),
                            fraction: frac,
                            severity: max(frac, stateSev))
                .help(help)
        } else {
            return StatTile(title: "Thermal",
                            value: Fmt.thermalWord(t.state),
                            caption: "No sensor access",
                            fraction: stateSev,
                            severity: stateSev)
                .help(help)
        }
    }

    private func batteryTile(_ b: BatteryReading) -> some View {
        var caption: String
        if b.charging {
            caption = b.watts.map { String(format: "Charging, %.0f W", $0) } ?? "Charging"
        } else if b.onAC {
            caption = "Plugged in"
        } else if let w = b.watts {
            caption = String(format: "%.1f W draw", w)
        } else if let m = b.minutesLeft {
            caption = "\(Fmt.duration(minutes: m)) left"
        } else {
            caption = "On battery"
        }
        if b.charging == false, b.onAC == false, b.watts != nil, let m = b.minutesLeft, m > 0 {
            caption = String(format: "%.1f W, ", b.watts ?? 0) + Fmt.duration(minutes: m)
        }

        var help = "Battery"
        if let h = b.health { help += ", health \(h)%" }
        if let c = b.cycles { help += ", \(c) cycles" }
        if let t = b.temperature { help += String(format: ", %.1f°C", t) }
        if let m = b.minutesLeft { help += ", \(Fmt.duration(minutes: m)) remaining" }

        let sev = b.onAC ? 0.1 : Double(100 - b.percent) / 100
        return StatTile(title: "Battery",
                        value: "\(b.percent)%",
                        caption: caption,
                        fraction: Double(b.percent) / 100,
                        severity: sev)
            .help(help)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String
    let fraction: Double
    var severity: Double? = nil
    var history: [Double]? = nil

    var body: some View {
        let tint = Palette.tint(severity ?? fraction)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            ProgressBar(fraction: fraction, color: tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .leading)
        .background {
            if let h = history {
                Sparkline(values: h)
                    .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .padding(.top, 40)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(3, g.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 4)
    }
}

struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let clamped = min(max(v, 0), 100) / 100
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step,
                             y: rect.maxY - CGFloat(clamped) * rect.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Row

struct RowView: View {
    let row: UsageRow
    let sort: SortKey
    let maxValue: Double
    let depth: Int
    let isExpanded: Bool
    @ObservedObject var monitor: Monitor
    var onToggle: (() -> Void)?

    @State private var hovering = false

    private var fraction: Double { min(1, max(0, row.value(sort) / maxValue)) }

    private var heat: Color {
        switch sort {
        case .cpu: return Palette.tint(row.cpu / 100)
        case .energy: return Palette.tint(row.energy / 100)
        case .memory: return Palette.tint(Double(row.memory) / 4_294_967_296)   // 4 GB is "a lot"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if !row.children.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)

            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: depth == 0 ? 12.5 : 11.5, weight: depth == 0 ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            metric(Fmt.num(row.cpu) + "%", key: .cpu, width: RowMetrics.cpu)
            metric(Fmt.mem(row.memory), key: .memory, width: RowMetrics.memory)
            metric(Fmt.num(row.energy), key: .energy, width: RowMetrics.energy)

            killControl.frame(width: RowMetrics.action)
        }
        .padding(.leading, depth == 0 ? 6 : 22)
        .padding(.trailing, 6)
        .padding(.vertical, depth == 0 ? 6 : 4)
        .background(alignment: .leading) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(heat.opacity(0.10))
                    .frame(width: max(0, g.size.width * CGFloat(fraction)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onToggle?() }
        .contextMenu { actions }
    }

    @ViewBuilder private var icon: some View {
        let size: CGFloat = depth == 0 ? 22 : 16
        if let img = IconCache.shared.icon(for: row) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: row.needsAdmin ? "gearshape.2.fill" : "gearshape.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
    }

    private func metric(_ text: String, key: SortKey, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: key == sort ? .semibold : .regular, design: .rounded))
            .monospacedDigit()
            .foregroundColor(key == sort ? .primary : .secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder private var killControl: some View {
        if row.isProtected {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .opacity(hovering ? 0.8 : 0)
                .help("System critical, Pulse won't stop this one")
        } else {
            Menu {
                actions
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help(row.kind == .app ? "Quit app" : "Stop process")
        }
    }

    @ViewBuilder private var actions: some View {
        if !row.isProtected {
            if row.needsAdmin {
                Button("Force Quit as Administrator\u{2026}") { monitor.killAsAdmin(row) }
            } else {
                Button(row.kind == .app ? "Quit" : "Terminate") { monitor.terminate(row, force: false) }
                Button("Force Quit") { monitor.terminate(row, force: true) }
            }
            Divider()
        }
        Button("Copy PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.id), forType: .string)
        }
        if !row.path.isEmpty {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
            }
        }
    }
}

// MARK: - Footer

struct PulseFooter: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("menuBarStyle") private var menuBarStyle: String = "both"
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Palette.tint(monitor.system.pressure / 100))
                .frame(width: 6, height: 6)
            Text("Memory pressure \(Int(monitor.system.pressure))%   Swap \(Fmt.mem(monitor.system.swapUsed))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Menu {
                Picker("Refresh every", selection: $monitor.interval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Picker("Menu bar shows", selection: $menuBarStyle) {
                    Text("CPU and temperature").tag("both")
                    Text("CPU").tag("cpu")
                    Text("Temperature").tag("temp")
                    Text("Icon only").tag("icon")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                Divider()
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Button("Quit Pulse") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .onChange(of: launchAtLogin) { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                monitor.flash("Couldn't update login item")
            }
        }
    }
}
