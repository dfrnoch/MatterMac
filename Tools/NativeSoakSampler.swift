// Development-only sampler for the real app, outside the XCUITest runner (which
// receives EPERM from proc_pid_rusage). Redirect stdout to an explicit test artifact.
import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 3, let requested = Double(CommandLine.arguments[2]) else {
    fatalError("Usage: swift Tools/NativeSoakSampler.swift /exact/MatterMac.app maximum-seconds")
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let maximum = min(22_200, max(30, requested))
var timebase = mach_timebase_info_data_t()
precondition(mach_timebase_info(&timebase) == KERN_SUCCESS)
// task POWER_INFO / proc rusage CPU times are Mach absolute ticks, not nanoseconds.
let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
let bundle = "org.mattermac.MatterMac"
let home = FileManager.default.homeDirectoryForCurrentUser

func persistenceMetadata(_ phase: String) {
    let roots = ["Library", "Library/Containers/\(bundle)/Data/Library"]
    let paths = ["Caches/\(bundle)", "Preferences/\(bundle).plist", "Saved Application State/\(bundle).savedState", "HTTPStorages/\(bundle)"]
    for (rootIndex, root) in roots.enumerated() {
        for (pathIndex, path) in paths.enumerated() {
            let url = home.appendingPathComponent(root).appendingPathComponent(path)
            var files = 0, bytes = 0, errors = 0, truncated = 0
            var modified: TimeInterval = 0
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            func count(_ item: URL) {
                do {
                    let value = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                    guard value.isRegularFile == true else { return }
                    files += 1
                    bytes += value.fileSize ?? 0
                    modified = max(modified, value.contentModificationDate?.timeIntervalSince1970 ?? 0)
                } catch { errors += 1 }
            }
            if exists {
                count(url)
                if directory.boolValue, let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [], errorHandler: { _, _ in errors += 1; return false }) {
                    var visited = 0
                    for case let item as URL in entries {
                        guard visited < 10_000 else { truncated = 1; break }
                        visited += 1
                        count(item)
                    }
                }
            }
            print("# persistence,\(phase),root=\(rootIndex),path=\(pathIndex),exists=\(exists ? 1 : 0),files=\(files),bytes=\(bytes),modified=\(modified),errors=\(errors),truncated=\(truncated)")
        }
    }
}

persistenceMetadata("before")
defer { persistenceMetadata("after") }
var process: NSRunningApplication?
let launchDeadline = ProcessInfo.processInfo.systemUptime + 180
while process == nil, ProcessInfo.processInfo.systemUptime < launchDeadline {
    process = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == appURL }
    if process == nil { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
}
guard let process else { fatalError("The exact test application did not launch within 180 seconds.") }
let pid = process.processIdentifier
let deadline = ProcessInfo.processInfo.systemUptime + maximum
print("uptime_seconds,pid,physical_footprint_bytes,resident_bytes,cpu_seconds,file_descriptor_estimate")
while ProcessInfo.processInfo.systemUptime < deadline {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard result == 0 else {
        print("# sampler_stopped,error=\(errno)")
        break
    }
    let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    let descriptors = descriptorBytes > 0 ? Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride : -1
    let cpu = (Double(info.ri_user_time) + Double(info.ri_system_time)) * secondsPerTick
    print("\(ProcessInfo.processInfo.systemUptime),\(pid),\(info.ri_phys_footprint),\(info.ri_resident_size),\(cpu),\(descriptors)")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 10)
}
