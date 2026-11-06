import BuildServerProtocol
import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeDestinationMetadataTests {
    @Test
    func concurrentReadersObserveCompletePublishedInventories() async throws {
        let source = DestinationInventorySource()
        let loader = XcodeDestinationLoader { await source.discover() }
        try await loader.loadDestinations()
        let initialSnapshot = loader.allDestinations
        let initialDevices = initialSnapshot.filter { $0.state == "connected" }
        #expect(Set(initialDevices.map(\.version)) == ["1.0"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0 ..< 50 {
                    try await loader.loadDestinations(reload: true)
                    await Task.yield()
                }
            }
            for _ in 0 ..< 4 {
                group.addTask {
                    for _ in 0 ..< 100 {
                        let snapshot = loader.allDestinations
                        let devices = snapshot.filter { $0.state == "connected" }
                        #expect(devices.count == 4)
                        #expect(Set(devices.map(\.version)).count == 1)
                        #expect(Set(devices.map(\.platform)) == [.iOS, .tvOS, .watchOS, .visionOS])
                        #expect(snapshot.count == initialSnapshot.count)
                        for platform in [
                            loader.iosDestinations,
                            loader.tvosDestinations,
                            loader.watchosDestinations,
                            loader.visionosDestinations
                        ] {
                            #expect(platform.count { $0.state == "connected" } == 1)
                        }
                        await Task.yield()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(Set(loader.allDestinations.filter { $0.state == "connected" }.map(\.version)) == ["51.0"])
        #expect(Set(initialSnapshot.filter { $0.state == "connected" }.map(\.version)) == ["1.0"])
    }

    @Test
    func cancelledDiscoveryCannotPublishAResultAfterItReturns() async throws {
        let gate = DestinationDiscoveryGate()
        let loader = XcodeDestinationLoader { await gate.discover() }
        let discovery = Task { try await loader.loadDestinations(reload: true) }
        await gate.waitUntilStarted()
        discovery.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await discovery.value }
        #expect(loader.iosDestinations.isEmpty)
        #expect(loader.macDestinations.isEmpty)
    }

    @Test
    func preservesObservedConnectionStatesAndOmitsUnknownSimulatorState() throws {
        let destinations = XcodeDestinationLoader().parseXctraceDestinations("""
        == Devices ==
        iPhone 16 Pro (18.5) (ONLINE-DEVICE)
        == Devices Offline ==
        iPad Air (18.4) (OFFLINE-DEVICE)
        == Simulators ==
        iPhone M1 Simulator (18.2) (SIMULATOR)
        """)
        let online = try #require(destinations.first { $0.id == "ONLINE-DEVICE" })
        #expect(online.isAvailable)
        #expect(online.buildContextMetadata == BuildContextDestination(
            kind: "device", platform: .init(id: "ios", label: "iOS"), osVersion: "18.5", state: "connected"
        ))
        let offline = try #require(destinations.first { $0.id == "OFFLINE-DEVICE" })
        #expect(!offline.isAvailable)
        #expect(offline.buildContextMetadata.state == "disconnected")
        let simulator = try #require(destinations.first { $0.id == "SIMULATOR" })
        #expect(simulator.buildContextMetadata == BuildContextDestination(
            kind: "simulator", platform: .init(id: "ios", label: "iOS"), osVersion: "18.2"
        ))
        #expect(simulator.buildContextMetadata.state == nil)
        #expect(simulator.buildContextMetadata.architecture == nil)
    }

    @Test
    func distinguishesGenericDestinationsFromHostAndAvoidsInferredArchitecture() {
        for destination in [XcodeDestination.anyiOSDevice, .anyiOSSimulator, .anyMac()] {
            let metadata = destination.buildContextMetadata
            #expect(metadata.kind == "generic")
            #expect(metadata.osVersion == nil)
            #expect(metadata.architecture == nil)
            #expect(metadata.state == nil)
        }
        let host = XcodeDestination.myMac().buildContextMetadata
        #expect(host.kind == "host")
        #expect(host.platform == .init(id: "macos", label: "macOS"))
        #expect(host.architecture == "arm64")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(host.osVersion == "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        let unknown = XcodeDestination(
            name: "Simulator", id: "SIMULATOR", platform: .visionOS, type: .simulator, architectures: [.arm64]
        ).buildContextMetadata
        #expect(unknown.platform == .init(id: "visionos", label: "visionOS"))
        #expect(unknown.architecture == nil)
        #expect(unknown.osVersion == nil)
        #expect(unknown.state == nil)
    }
}

private actor DestinationInventorySource {
    private var generation = 0

    func discover() -> String {
        generation += 1
        return """
        == Devices ==
        iPhone 16 Pro (\(generation).0) (IPHONE-\(generation))
        Apple TV (\(generation).0) (TV-\(generation))
        Apple Watch (\(generation).0) (WATCH-\(generation))
        Apple Vision Pro (\(generation).0) (VISION-\(generation))
        """
    }
}

private actor DestinationDiscoveryGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func discover() async -> String {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        return "== Devices ==\niPhone 16 Pro (18.5) (DEVICE)"
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
