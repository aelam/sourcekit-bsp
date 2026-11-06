import BuildServerProtocol
import Foundation

extension XcodeDestination {
    var buildContextMetadata: BuildContextDestination {
        let kind: String = if !isRunnable {
            "generic"
        } else if platform == .macOS, id.split(separator: ",").contains("platform=macOS") {
            "host"
        } else {
            type == .simulator ? "simulator" : "device"
        }
        // The inventory's architecture list includes inferred values. Use only an explicit selection.
        let selectedArchitectures = id.split(separator: ",").compactMap { component -> String? in
            guard component.hasPrefix("arch=") else { return nil }
            let value = String(component.dropFirst("arch=".count))
            return value.isEmpty ? nil : value
        }
        let architecture = selectedArchitectures.count == 1 ? selectedArchitectures[0] : nil
        let osVersion: String?
        if kind == "generic" {
            osVersion = nil
        } else if kind == "host", version == nil {
            let current = ProcessInfo.processInfo.operatingSystemVersion
            osVersion = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        } else {
            osVersion = version
        }
        return BuildContextDestination(
            kind: kind,
            platform: BuildContextPlatform(id: platform.rawValue.lowercased(), label: platform.rawValue),
            osVersion: osVersion,
            architecture: architecture,
            state: kind == "generic" ? nil : state,
            identifier: kind == "device" || kind == "simulator" ? .init(label: "UDID", value: id) : nil
        )
    }
}
