import Foundation

/// Selects a process by its exact executable, including the simulator container path.
public enum DebugAttachSelection {
    public static func select(
        executable: String, pid: Int?, processes: [HostProcessIdentity]
    ) throws -> HostProcessIdentity {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let matches = processes.filter { $0.executable == path && $0.pid > 0 }
        if let pid {
            guard let match = matches.first(where: { $0.pid == pid }) else {
                throw HostAttachError.invalid("PID \(pid) does not belong to the selected target and destination.")
            }
            return match
        }
        guard !matches.isEmpty else {
            throw HostAttachError
                .invalid("No running process matches the selected target and destination. Start the app first.")
        }
        guard matches.count == 1 else {
            throw HostAttachError
                .invalid(
                    "Multiple processes match the selected target and destination. " +
                        "Set pid in launch.json to the required process ID."
                )
        }
        return matches[0]
    }
}
