import Foundation
import Support
import Testing
@testable import XcodeProjectManagement

struct XcodeDebugAttachTests {
    @Test
    func helloSimulatorUsesTheSelectedDeviceAndInstalledExecutable() async throws {
        let queries = CrossPlatformLock(initialState: 0)
        let executable = "/simulators/selected/Applications/Hello.app/Hello"
        let expected = HostProcessIdentity(pid: 42, executable: executable, startToken: "one")
        let identity = try await XcodeDebugAttachResolver.identity(
            product: .init(
                platform: .iOSSimulator,
                binaryPath: "/build/Hello.app",
                bundleId: "test.Hello",
                simulatorUDID: "selected"
            ),
            pid: nil,
            simulatorExecutable: { device, bundle in
                #expect(device == "selected")
                #expect(bundle == "test.Hello")
                queries.withLock { $0 += 1 }
                return executable
            },
            processes: { path in
                #expect(path == executable)
                return [
                    expected,
                    .init(pid: 99, executable: "/simulators/other/Applications/Hello.app/Hello", startToken: "two")
                ]
            }
        )
        #expect(identity == expected)
        #expect(queries.withLock { $0 } == 1)
    }

    @Test
    func macHostDoesNotQueryASimulator() async throws {
        let identity = try await XcodeDebugAttachResolver.identity(
            product: .init(
                platform: .macOS,
                binaryPath: "/Applications/Hello.app/Contents/MacOS/Hello",
                bundleId: "test.Hello",
                simulatorUDID: nil
            ),
            pid: 42,
            simulatorExecutable: { _, _ in throw HostAttachError.invalid("Unexpected simulator query") },
            processes: { path in [.init(pid: 42, executable: path, startToken: "one")] }
        )
        #expect(identity.pid == 42)
    }

    @Test(arguments: [Platform.iOS, .tvSimulator, .watchSimulator, .visionSimulator])
    func unsupportedAttachDoesNotStartAnAdapterOrQueryProcesses(platform: Platform) async throws {
        await #expect(throws: HostAttachError.self) {
            try await XcodeDebugAttachResolver.identity(
                product: .init(
                    platform: platform,
                    binaryPath: "/build/Hello.app",
                    bundleId: "test.Hello",
                    simulatorUDID: "device"
                ),
                pid: nil,
                simulatorExecutable: { _, _ in
                    Issue.record("Unsupported attach queried a simulator")
                    return ""
                },
                processes: { _ in
                    Issue.record("Unsupported attach queried processes")
                    return []
                }
            )
        }
    }
}
