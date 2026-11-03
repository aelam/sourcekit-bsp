import Foundation
import Support

final class XcodeDestinationLoader: @unchecked Sendable {
    private var destinations: [XcodeDestination] = []
    private(set) var macDestinations: [XcodeDestination] = []
    private(set) var iosDestinations: [XcodeDestination] = []
    private(set) var tvosDestinations: [XcodeDestination] = []
    private(set) var watchosDestinations: [XcodeDestination] = []
    private(set) var visionosDestinations: [XcodeDestination] = []

    enum LoaderError: Error {
        case xcrunNotFound
        case invalidJSONOutput
        case noDestinationsFound
    }

    private struct ParseResult {
        let name: String?
        let version: String?
        let udid: String?
    }

    init() {}

    func loadDestinations(reload: Bool = false) async throws {
        if !destinations.isEmpty, !reload {
            return // Already loaded
        }

        let destinations = try await loadDestinationsFromXctrace()
        self.destinations = destinations + [
            .anyiOSDevice,
            .anyiOSSimulator,
            .anyTVOSSimulator,
            .anyTVOSDevice,
            .anyWatchOSSimulator,
            .anyWatchOSDevice,
            .anyVisionOSSimulator,
            .anyVisionOSDevice,
            .myMac(),
            .anyMac()
        ]
        macDestinations = self.destinations.filter { $0.platform == .macOS }
        iosDestinations = self.destinations.filter { $0.platform == .iOS }
        tvosDestinations = self.destinations.filter { $0.platform == .tvOS }
        watchosDestinations = self.destinations.filter { $0.platform == .watchOS }
        visionosDestinations = self.destinations.filter { $0.platform == .visionOS }
    }

    private func loadDestinationsFromXctrace() async throws -> [XcodeDestination] {
        let result = try await ProcessExecutor().execute(
            executable: "/usr/bin/xcrun", arguments: ["xctrace", "list", "devices"]
        )
        guard result.isSuccess else {
            throw XcodeProjectError.invalidConfig("Failed to list Xcode destinations: \(result.error ?? result.output)")
        }
        let output = result.output

        var destinations: [XcodeDestination] = []
        let lines = output.components(separatedBy: .newlines)
        var currentSection = ""

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Detect section headers
            if trimmedLine.starts(with: "== Devices ==") {
                currentSection = "devices"
                continue
            } else if trimmedLine.starts(with: "== Devices Offline ==") {
                currentSection = "offline"
                continue
            } else if trimmedLine.starts(with: "== Simulators ==") {
                currentSection = "simulators"
                continue
            }

            // Skip empty lines and headers
            if trimmedLine.isEmpty || trimmedLine.starts(with: "==") {
                continue
            }

            // Parse device/simulator lines
            if let destination = parseXctraceDeviceLine(trimmedLine, section: currentSection) {
                destinations.append(destination)
            }
        }

        return destinations
    }

    private func parseXctraceDeviceLine(_ line: String, section: String) -> XcodeDestination? {
        // Handle different line formats:
        // Mac: "DeviceName (UUID)"
        // Device: "iPhone 16 Pro (18.5) (00008140-001E498E0EDB001C)"
        // Simulator: "iPhone 16 Simulator (18.2) (F76DD514-D57D-475E-9C1A-EB230A2FF86B)"

        guard line.contains("("), line.contains(")") else { return nil }

        if section == "devices" {
            // Check if it's a Mac device (no version format or contains Mac keywords)
            let isMacDevice = !line.contains(") (") || isLikelyMacDevice(line)

            if isMacDevice {
                // Mac format: "DeviceName (UUID)"
                return nil // Handled separately
            } else {
                // Real device format: "Device Name (Version) (UDID)"
                return parseRealDevice(line)
            }
        } else if section == "simulators" {
            // Simulator format: "Device Name Simulator (Version) (UDID)"
            return parseSimulator(line)
        } else if section == "offline" {
            // Offline real devices
            return parseRealDevice(line, isAvailable: false)
        }

        return nil
    }

    private func isLikelyMacDevice(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let macIndicators = [
            "mac", "macbook", "imac", "mac pro", "mac mini", "mac studio",
            // Common Mac computer names or identifiers
            "macbook pro", "macbook air", "studio display"
        ]

        return macIndicators.contains { lowercased.contains($0) }
    }

    private func parseRealDevice(_ line: String, isAvailable: Bool = true) -> XcodeDestination? {
        let components = parseDeviceLine(line)
        guard let name = components.name,
              let version = components.version,
              let udid = components.udid else { return nil }

        let platform = determinePlatform(from: name)

        return XcodeDestination(
            name: name,
            id: udid,
            platform: platform,
            type: .device,
            version: version,
            isAvailable: isAvailable
        )
    }

    private func parseSimulator(_ line: String) -> XcodeDestination? {
        // Check if this is a paired device (contains " + ")
        if line.contains(" + ") {
            return parsePairedSimulator(line)
        }

        let components = parseDeviceLine(line)
        guard let name = components.name,
              let version = components.version,
              let udid = components.udid else { return nil }

        // Remove "Simulator" from name and clean up
        let cleanName = cleanDeviceName(name.replacingOccurrences(of: " Simulator", with: ""))
        let platform = determinePlatform(from: cleanName)
        let architecture = determineArchitecture(from: cleanName)

        return XcodeDestination(
            name: cleanName,
            id: udid,
            platform: platform,
            type: .simulator,
            version: version,
            architectures: architecture
        )
    }

    private func cleanDeviceName(_ name: String) -> String {
        // Remove common suffixes and clean up device names
        var cleaned = name

        // Remove generation indicators that might be duplicated
        let cleanupPatterns = [
            " (\\d+st generation)", " (\\d+nd generation)", " (\\d+rd generation)", " (\\d+th generation)",
            " \\(at \\d+p\\)", // For Apple TV resolution indicators
        ]

        for pattern in cleanupPatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    private func determineArchitecture(from deviceName: String) -> [XcodeDestinationArchitecture] {
        let lowercased = deviceName.lowercased()

        // Modern devices are typically arm64
        if lowercased.contains("m1") || lowercased.contains("m2") ||
            lowercased.contains("m3") || lowercased.contains("m4") ||
            lowercased.contains("a14") || lowercased.contains("a15") ||
            lowercased.contains("a16") || lowercased.contains("a17") {
            return [.arm64]
        }

        // Intel-based simulators
        if lowercased.contains("intel") {
            return [.x86_64]
        }

        // Default for simulators - support both architectures
        return [.arm64, .x86_64]
    }

    private func parsePairedSimulator(_ line: String) -> XcodeDestination? {
        // Format: "iPhone 16 Simulator (18.2) + Apple Watch Series 10 (42mm) (11.2) (UUID)"
        guard let plusIndex = line.firstIndex(of: "+") else { return nil }

        let mainDevicePart = String(line[..<plusIndex]).trimmingCharacters(in: .whitespaces)
        let remainingPart = String(line[line.index(after: plusIndex)...]).trimmingCharacters(in: .whitespaces)

        // Parse main device (iPhone part)
        let mainComponents = parseDeviceLine(mainDevicePart + " (dummy-uuid)")
        guard let mainName = mainComponents.name,
              let mainVersion = mainComponents.version else { return nil }

        // Parse paired device and get the actual UUID from the end
        guard let lastOpenParen = remainingPart.lastIndex(of: "("),
              let lastCloseParen = remainingPart.lastIndex(of: ")") else { return nil }

        let actualUUID = String(remainingPart[remainingPart.index(after: lastOpenParen) ..< lastCloseParen])
        let pairedDevicePart = String(remainingPart[..<lastOpenParen]).trimmingCharacters(in: .whitespaces)

        // Parse the paired device info
        let pairedComponents = parseDeviceLine(pairedDevicePart + " (dummy-uuid)")
        guard let pairedName = pairedComponents.name,
              let pairedVersion = pairedComponents.version else { return nil }

        // Create main device with paired device info
        let mainCleanName = mainName.replacingOccurrences(of: " Simulator", with: "")
        let mainPlatform = determinePlatform(from: mainCleanName)

        let pairedDevice = XcodePairedDevice(
            name: pairedName,
            platform: determinePlatform(from: pairedName),
            version: pairedVersion
        )

        return XcodeDestination(
            name: mainCleanName,
            id: actualUUID,
            platform: mainPlatform,
            type: .simulator,
            version: mainVersion,
            pairedDevice: pairedDevice
        )
    }

    private func determinePlatform(from deviceName: String) -> XcodeDestinationPlatform {
        let lowercased = deviceName.lowercased()

        // iOS devices
        let iOSKeywords = ["iphone", "ipad", "ipod", "ios"]
        if iOSKeywords.contains(where: { lowercased.contains($0) }) {
            return .iOS
        }

        // watchOS devices
        let watchOSKeywords = ["watch", "watchos"]
        if watchOSKeywords.contains(where: { lowercased.contains($0) }) {
            return .watchOS
        }

        // tvOS devices
        let tvOSKeywords = ["apple tv", "appletv", "tvos"]
        if tvOSKeywords.contains(where: { lowercased.contains($0) }) {
            return .tvOS
        }

        // visionOS devices
        let visionOSKeywords = ["vision", "visionos", "apple vision"]
        if visionOSKeywords.contains(where: { lowercased.contains($0) }) {
            return .visionOS
        }

        // macOS devices
        let macOSKeywords = ["mac", "macos", "macbook", "imac", "mac pro", "mac mini", "mac studio"]
        if macOSKeywords.contains(where: { lowercased.contains($0) }) {
            return .macOS
        }

        // Default fallback
        return .iOS
    }

    private func parseDeviceLine(_ line: String) -> ParseResult {
        // Parse format: "Device Name (Version) (UDID)"

        // Find all parentheses positions
        let openParens = line.enumerated().compactMap { $0.element == "(" ? $0.offset : nil }
        let closeParens = line.enumerated().compactMap { $0.element == ")" ? $0.offset : nil }

        guard openParens.count >= 2, closeParens.count >= 2 else {
            return ParseResult(name: nil, version: nil, udid: nil)
        }

        // Get the UDID (between last pair of parentheses - this is most reliable)
        let lastOpenParen = line.index(line.startIndex, offsetBy: openParens.last!)
        let lastCloseParen = line.index(line.startIndex, offsetBy: closeParens.last!)
        let udidStart = line.index(after: lastOpenParen)
        let udid = String(line[udidStart ..< lastCloseParen]).trimmingCharacters(in: .whitespaces)

        // Find the version by looking for the parentheses pair just before the UDID
        var version: String?
        var name: String?

        if openParens.count >= 2 {
            // Try to find version in the second-to-last parentheses pair
            let versionOpenIdx = openParens.count >= 3 ? openParens[openParens.count - 2] : openParens[0]
            let versionCloseIdx = closeParens.count >= 3 ? closeParens[closeParens.count - 2] : closeParens[0]

            let versionOpenParen = line.index(line.startIndex, offsetBy: versionOpenIdx)
            let versionCloseParen = line.index(line.startIndex, offsetBy: versionCloseIdx)
            let versionStart = line.index(after: versionOpenParen)
            let potentialVersion = String(line[versionStart ..< versionCloseParen]).trimmingCharacters(in: .whitespaces)

            // Validate if this looks like a version number
            if isValidVersion(potentialVersion) {
                version = potentialVersion
                // Name is everything before the version parentheses
                name = String(line[..<versionOpenParen]).trimmingCharacters(in: .whitespaces)
            } else {
                // No valid version found, treat as part of device name
                let beforeUDID = line.index(line.startIndex, offsetBy: openParens.last!)
                name = String(line[..<beforeUDID]).trimmingCharacters(in: .whitespaces)
            }
        }

        return ParseResult(
            name: name?.isEmpty == false ? name : nil,
            version: version?.isEmpty == false ? version : nil,
            udid: udid.isEmpty ? nil : udid
        )
    }

    private func isValidVersion(_ version: String) -> Bool {
        // Check if version looks like a system version (e.g., "18.2", "11.5")
        // Should contain digits and dots, not contain mm, generation, etc.
        let lowercased = version.lowercased()

        // Quick exclusions
        if lowercased.contains("mm") ||
            lowercased.contains("generation") ||
            lowercased.contains("gen") {
            return false
        }

        // Check if it's a valid version pattern: digits separated by dots
        let components = version.components(separatedBy: ".")
        guard !components.isEmpty else { return false }

        // All components should be numeric
        for component in components {
            if component.isEmpty || !component.allSatisfy(\.isNumber) {
                return false
            }
        }

        // Should have at least one component and reasonable version format
        return components.count >= 1 && components.count <= 4
    }
}
