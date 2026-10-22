import Foundation
import Darwin

// MARK: - Per process sampling (libproc)

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let responsible: pid_t
    let name: String
    let path: String
    var cpu: Double        // percent of one core, like Activity Monitor
    var memory: UInt64     // physical footprint in bytes
    var wakeups: Double    // idle + interrupt wakeups per second

    /// Rough energy impact estimate: CPU time plus a penalty for waking the CPU.
    var energy: Double { cpu + wakeups * 0.02 }
}

final class ProcessSampler {
    private struct Prev {
        let start: UInt64
        let cpuNs: UInt64
        let wakeups: UInt64
    }

    private struct Meta {
        let start: UInt64
        let name: String
        let path: String
    }

    private var prev: [pid_t: Prev] = [:]
    private var meta: [pid_t: Meta] = [:]
    private var lastTime: UInt64 = 0
    private let numer: UInt64
    private let denom: UInt64
    private let responsibleFn: ResponsibleFn?

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(max(tb.numer, 1))
        denom = UInt64(max(tb.denom, 1))

        // Private libsystem call Activity Monitor uses to group helper processes under their app.
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            responsibleFn = unsafeBitCast(sym, to: ResponsibleFn.self)
        } else {
            responsibleFn = nil
        }
    }

    func sample() -> [ProcInfo] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastTime == 0 ? 0 : Double(now &- lastTime)
        lastTime = now

        let pids = listPids()
        var nextPrev: [pid_t: Prev] = [:]
        var nextMeta: [pid_t: Meta] = [:]
        nextPrev.reserveCapacity(pids.count)
        nextMeta.reserveCapacity(pids.count)

        var out: [ProcInfo] = []
        out.reserveCapacity(pids.count)
        var restrictedIdx: [Int] = []

        for pid in pids where pid >= 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) > 0

            let start: UInt64 = hasBSD
                ? UInt64(bsd.pbi_start_tvsec) &* 1_000_000 &+ UInt64(bsd.pbi_start_tvusec)
                : 0

            let m: Meta
            if let cached = meta[pid], cached.start == start {
                m = cached
            } else {
                m = makeMeta(pid: pid, bsd: hasBSD ? bsd : nil, start: start)
            }
            nextMeta[pid] = m

            let ppid: pid_t = hasBSD ? pid_t(truncatingIfNeeded: bsd.pbi_ppid) : 0
            let uid: uid_t = hasBSD ? bsd.pbi_uid : 0

            var responsible = pid
            if let fn = responsibleFn {
                let r = fn(pid)
                if r > 0 { responsible = r }
            }

            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }

            if rc == 0 {
                let cpuNs = (ri.ri_user_time &+ ri.ri_system_time) &* numer / denom
                let wake = ri.ri_pkg_idle_wkups &+ ri.ri_interrupt_wkups
                var cpu = 0.0
                var wps = 0.0
                if elapsed > 0, let p = prev[pid], p.start == start {
                    if cpuNs >= p.cpuNs { cpu = Double(cpuNs - p.cpuNs) / elapsed * 100 }
                    if wake >= p.wakeups { wps = Double(wake - p.wakeups) / (elapsed / 1e9) }
                }
                nextPrev[pid] = Prev(start: start, cpuNs: cpuNs, wakeups: wake)
                out.append(ProcInfo(pid: pid, ppid: ppid, uid: uid, responsible: responsible,
                                    name: m.name, path: m.path,
                                    cpu: cpu, memory: ri.ri_phys_footprint, wakeups: wps))
            } else {
                // Owned by another user (root, system daemons). Filled from ps below.
                restrictedIdx.append(out.count)
                out.append(ProcInfo(pid: pid, ppid: ppid, uid: uid, responsible: responsible,
                                    name: m.name, path: m.path,
                                    cpu: 0, memory: 0, wakeups: 0))
            }
        }

        if !restrictedIdx.isEmpty {
            let ps = psSnapshot()
            for i in restrictedIdx {
                if let v = ps[out[i].pid] {
                    out[i].cpu = v.cpu
                    out[i].memory = v.rss
                }
            }
        }

        prev = nextPrev
        meta = nextMeta
        return out
    }

    // MARK: Helpers

    private func listPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got)))
    }

    private func makeMeta(pid: pid_t, bsd: proc_bsdinfo?, start: UInt64) -> Meta {
        if pid == 0 { return Meta(start: start, name: "kernel_task", path: "") }

        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        var path = ""
        if len > 0 {
            path = String(decoding: buf[0..<Int(len)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        var name = ""
        if !path.isEmpty {
            name = (path as NSString).lastPathComponent
        } else if let b = bsd {
            name = tupleString(b.pbi_name)
            if name.isEmpty { name = tupleString(b.pbi_comm) }
        }
        if name.isEmpty {
            var nbuf = [CChar](repeating: 0, count: 256)
            let nlen = proc_name(pid, &nbuf, UInt32(nbuf.count))
            if nlen > 0 {
                name = String(decoding: nbuf[0..<Int(nlen)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        if name.isEmpty { name = "Process \(pid)" }
        return Meta(start: start, name: name, path: path)
    }

    private func tupleString<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafeBytes(of: &t) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// /bin/ps is setuid root, so it can read CPU and RSS for system processes we cannot.
    private func psSnapshot() -> [pid_t: (cpu: Double, rss: UInt64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,pcpu=,rss="]
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        var result: [pid_t: (cpu: Double, rss: UInt64)] = [:]
        guard let text = String(data: data, encoding: .utf8) else { return result }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2]) else { continue }
            result[pid] = (cpu, rss * 1024)
        }
        return result
    }
}

// MARK: - System wide CPU and memory

struct SystemStats {
    var cpu: Double = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var pressure: Double = 0
    var swapUsed: UInt64 = 0
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount
}

final class SystemSampler {
    private let host = mach_host_self()
    private var lastTicks: [UInt64]?
    private var lastCPU: Double = 0

    func sample() -> SystemStats {
        var s = SystemStats()
        s.cpu = cpuUsage()
        let mem = memory()
        s.memUsed = mem.used
        s.swapUsed = mem.swap
        s.pressure = mem.pressure
        return s
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(self.host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return lastCPU }

        let t = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                 UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { lastTicks = t }
        guard let l = lastTicks, zip(t, l).allSatisfy({ pair in pair.0 >= pair.1 }) else { return lastCPU }

        let user = t[0] - l[0], sys = t[1] - l[1], idle = t[2] - l[2], nice = t[3] - l[3]
        let total = user + sys + idle + nice
        guard total > 0 else { return lastCPU }
        lastCPU = Double(user + sys + nice) / Double(total) * 100
        return lastCPU
    }

    private func memory() -> (used: UInt64, swap: UInt64, pressure: Double) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(self.host, HOST_VM_INFO64, $0, &count)
            }
        }

        var used: UInt64 = 0
        if kr == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let internalPages = UInt64(vm.internal_page_count)
            let purgeablePages = UInt64(vm.purgeable_count)
            let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
            // Same formula as Activity Monitor's "Memory Used": app + wired + compressed
            used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }

        var swap: UInt64 = 0
        var xsw = xsw_usage()
        var xsize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xsize, nil, 0) == 0 {
            swap = xsw.xsu_used
        }

        var pressure = 0.0
        var level: Int32 = 0
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &lsize, nil, 0) == 0 {
            pressure = Double(max(0, min(100, 100 - level)))
        }

        return (used, swap, pressure)
    }
}
