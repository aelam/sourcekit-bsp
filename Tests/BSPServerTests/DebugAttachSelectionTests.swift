import Foundation
import Support
import Testing

struct DebugAttachSelectionTests {
    let executable = "/simulators/selected/Hello.app/Hello"

    @Test
    func selectsOneProcessAndRejectsMissingAmbiguousOrForeignPIDs() throws {
        let first = HostProcessIdentity(pid: 42, executable: executable, startToken: "one")
        let second = HostProcessIdentity(pid: 43, executable: executable, startToken: "two")
        let other = HostProcessIdentity(pid: 99, executable: "/simulators/other/Hello.app/Hello", startToken: "three")
        #expect(try DebugAttachSelection.select(executable: executable, pid: nil, processes: [first, other]) == first)
        #expect(try DebugAttachSelection.select(executable: executable, pid: 43, processes: [first, second]) == second)
        for (pid, processes): (Int?, [HostProcessIdentity]) in [
            (nil, []),
            (nil, [first, second]),
            (99, [first, other])
        ] {
            #expect(throws: HostAttachError.self) {
                try DebugAttachSelection.select(executable: executable, pid: pid, processes: processes)
            }
        }
    }

    @Test
    func ambiguityTellsTheUserToSetTheExistingPIDField() {
        do {
            _ = try DebugAttachSelection.select(executable: executable, pid: nil, processes: [
                .init(pid: 42, executable: executable, startToken: "one"),
                .init(pid: 43, executable: executable, startToken: "two")
            ])
            Issue.record("Ambiguous attach succeeded")
        } catch {
            #expect(error.localizedDescription.contains("pid in launch.json"))
        }
    }
}
