import SwiftUI
import AppKit

enum SortKey: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "MEMORY"
    case energy = "ENERGY"
    var id: String { rawValue }
}

struct UsageRow: Identifiable {
    enum Kind { case app, process }

    let id: pid_t
    let kind: Kind
    let name: String
    let detail: String
    let path: String
    let bundleURL: URL?
    var cpu: Double
    var memory: UInt64
    var energy: Double
    var children: [UsageRow]
    let needsAdmin: Bool
    let isProtected: Bool

    func value(_ key: SortKey) -> Double {
        switch key {
        case .cpu: return cpu
        case .memory: return Double(memory)
        case .energy: return energy
        }
    }
}

final class Monitor: ObservableObject {
    @Published private(set) var apps: [UsageRow] = []
    @Published private(set) var background: [UsageRow] = []
    @Published private(set) var system = SystemStats()
    @Published private(set) var thermal = ThermalReading()
    @Published private(set) var battery: BatteryReading?
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 40)
    @Published var toast: String?

    @Published var interval: Double = 2 {
        didSet {
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            reschedule(immediate: false)
        }
    }

    /// Fast refresh while the panel is open, slow and cheap while it's closed.
    var isVisible = false {
        didSet { if isVisible != oldValue { reschedule(immediate: isVisible) } }
    }

    private let queue = DispatchQueue(label: "pulse.sampler", qos: .utility)
    private let procSampler = ProcessSampler()
    private let sysSampler = SystemSampler()
    private let sensors = Sensors()
    private var timer: DispatchSourceTimer?
    private var userNames: [uid_t: String] = [:]
    private let myUID = getuid()
    private let myPID = getpid()

    private static let critical: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "opendirectoryd", "configd", "logd", "UserEventAgent"
    ]

    init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = saved > 0 ? saved : 2

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.sampleNow() }
        timer = t
        reschedule(immediate: true)
        t.resume()
    }

    private func reschedule(immediate: Bool) {
        let every = isVisible ? interval : 8
        timer?.schedule(deadline: immediate ? .now() : .now() + every,
                        repeating: every,
                        leeway: .milliseconds(250))
    }

    /// Runs on the sampler queue.
    private func sampleNow() {
        let procs = procSampler.sample()
        let sys = sysSampler.sample()
        let therm = sensors.readThermal()
        let batt = sensors.readBattery()
        DispatchQueue.main.async { [weak self] in
            self?.apply(procs: procs, sys: sys, therm: therm, batt: batt)
        }
    }

    func refreshSoon() {
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.sampleNow() }
    }

    // MARK: Grouping (main thread)

    private func apply(procs: [ProcInfo], sys: SystemStats, therm: ThermalReading, batt: BatteryReading?) {
        system = sys
        thermal = therm
        battery = batt
        var hist = cpuHistory
        hist.append(sys.cpu)
        if hist.count > 40 { hist.removeFirst(hist.count - 40) }
        cpuHistory = hist

        var regular: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            regular[app.processIdentifier] = app
        }

        var byPid: [pid_t: ProcInfo] = [:]
        for p in procs { byPid[p.pid] = p }

        func owner(of p: ProcInfo) -> pid_t? {
            if regular[p.pid] != nil { return p.pid }
            if regular[p.responsible] != nil { return p.responsible }
            var cur = p.ppid
            var hops = 0
            while cur > 1 && hops < 8 {
                if regular[cur] != nil { return cur }
                cur = byPid[cur]?.ppid ?? 0
                hops += 1
            }
            return nil
        }

        var grouped: [pid_t: [ProcInfo]] = [:]
        var loose: [ProcInfo] = []
        for p in procs {
            if let o = owner(of: p) {
                grouped[o, default: []].append(p)
            } else {
                loose.append(p)
            }
        }

        var appRows: [UsageRow] = []
        appRows.reserveCapacity(regular.count)
        for (pid, app) in regular {
            let members = grouped[pid] ?? []
            let cpu = members.reduce(0.0) { $0 + $1.cpu }
            let mem = members.reduce(UInt64(0)) { $0 + $1.memory }
            let energy = members.reduce(0.0) { $0 + $1.energy }
            let detail = members.count > 1 ? "\(members.count) processes" : (app.bundleIdentifier ?? "PID \(pid)")
            appRows.append(UsageRow(
                id: pid,
                kind: .app,
                name: app.localizedName ?? byPid[pid]?.name ?? "App \(pid)",
                detail: detail,
                path: app.bundleURL?.path ?? "",
                bundleURL: app.bundleURL,
                cpu: cpu,
                memory: mem,
                energy: energy,
                children: members.count > 1 ? members.map(processRow) : [],
                needsAdmin: false,
                isProtected: pid == myPID
            ))
        }

        apps = appRows
        background = loose.map(processRow)
    }

    private func processRow(_ p: ProcInfo) -> UsageRow {
        let foreign = p.uid != myUID
        var detail = "PID \(p.pid)"
        if foreign { detail += "  ·  \(userName(p.uid))" }
        return UsageRow(
            id: p.pid,
            kind: .process,
            name: p.name,
            detail: detail,
            path: p.path,
            bundleURL: nil,
            cpu: p.cpu,
            memory: p.memory,
            energy: p.energy,
            children: [],
            needsAdmin: foreign,
            isProtected: p.pid <= 1 || p.pid == myPID || Self.critical.contains(p.name)
        )
    }

    private func userName(_ uid: uid_t) -> String {
        if let n = userNames[uid] { return n }
        var name = "uid \(uid)"
        if let pw = getpwuid(uid), let cstr = pw.pointee.pw_name {
            name = String(cString: cstr)
        }
        userNames[uid] = name
        return name
    }

    // MARK: Actions

    func terminate(_ row: UsageRow, force: Bool) {
        guard !row.isProtected else { flash("\(row.name) is protected"); return }

        if row.kind == .app, let app = NSRunningApplication(processIdentifier: row.id) {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok {
                flash(force ? "Force quit \(row.name)" : "Asked \(row.name) to quit")
            } else {
                flash("Couldn't quit \(row.name)")
            }
        } else {
            if Darwin.kill(row.id, force ? SIGKILL : SIGTERM) == 0 {
                flash(force ? "Killed \(row.name)" : "Sent quit signal to \(row.name)")
            } else if errno == EPERM {
                flash("\(row.name) needs admin rights")
            } else {
                flash("Couldn't stop \(row.name)")
            }
        }
        refreshSoon()
    }

    func killAsAdmin(_ row: UsageRow) {
        guard !row.isProtected else { flash("\(row.name) is protected"); return }
        let source = "do shell script \"kill -9 \(row.id)\" with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        flash(error == nil ? "Killed \(row.name)" : "Cancelled")
        refreshSoon()
    }

    func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self = self, self.toast == text else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
    }
}

// MARK: - Icons

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for row: UsageRow) -> NSImage? {
        let key: String
        if let url = row.bundleURL {
            key = url.path
        } else if let r = row.path.range(of: ".app/") {
            key = String(row.path[..<r.lowerBound]) + ".app"
        } else {
            return nil
        }
        if let img = cache[key] { return img }
        let img = NSWorkspace.shared.icon(forFile: key)
        img.size = NSSize(width: 32, height: 32)
        cache[key] = img
        return img
    }
}
