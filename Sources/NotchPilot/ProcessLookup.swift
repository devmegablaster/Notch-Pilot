import Foundation
import Darwin

/// Thin wrappers over `libproc` (`proc_listpids`, `proc_name`, `proc_pidpath`,
/// `proc_pidinfo`) shared by ClaudeMonitor and TerminalJumper. macOS has no
/// `/proc` — these are the only reliable way to enumerate processes and read
/// their name / executable path / parent PID / current working directory.
enum ProcessLookup {

    /// Every process visible to the current user, as an array of pids.
    static func allPIDs() -> [Int32] {
        let buffer = UnsafeMutablePointer<pid_t>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        let sizeBytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, buffer,
            Int32(4096 * MemoryLayout<pid_t>.size)
        )
        guard sizeBytes > 0 else { return [] }
        let count = Int(sizeBytes) / MemoryLayout<pid_t>.size
        var result: [Int32] = []
        result.reserveCapacity(count)
        for i in 0..<count { result.append(buffer[i]) }
        return result
    }

    /// `p_comm` — the 16-character accounting name. For most executables this
    /// matches what `ps -o comm=` reports.
    static func name(of pid: Int32) -> String? {
        let cap = Int(MAXPATHLEN)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { buffer.deallocate() }
        let r = proc_name(pid, buffer, UInt32(cap))
        guard r > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Full filesystem path of the binary backing the process.
    static func path(of pid: Int32) -> String? {
        let cap = Int(MAXPATHLEN) * 4  // PROC_PIDPATHINFO_MAXSIZE
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { buffer.deallocate() }
        let r = proc_pidpath(pid, buffer, UInt32(cap))
        guard r > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Parent pid via `PROC_PIDTBSDINFO`. Used to walk up to a terminal app.
    static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard r > 0 else { return nil }
        return Int32(info.pbi_ppid)
    }

    /// The process's current working directory via `PROC_PIDVNODEPATHINFO`.
    /// Returns nil if the call fails (permissions, process exited, etc.).
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard r > 0 else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuplePtr -> String? in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cstr in
                let s = String(cString: cstr)
                return s.isEmpty ? nil : s
            }
        }
    }

    /// Strip trailing slashes and the `/private` prefix so cwds from libproc
    /// and from jsonl `cwd` fields compare equal.
    static func normalize(_ p: String) -> String {
        var s = p
        if s.hasPrefix("/private/") { s = String(s.dropFirst(8)) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
