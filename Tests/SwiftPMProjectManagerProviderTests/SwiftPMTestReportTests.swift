import BuildServerProtocol
import Foundation
import Testing
@testable import SwiftPMProjectManagerProvider

struct SwiftPMTestReportTests {
    @Test
    func aggregatesParameterizedFailuresAndKeepsKnownIssuesAndSkips() {
        var report = SwiftPMTestReport(module: "Tests")
        // swiftlint:disable line_length
        report.readSwiftTesting(Data("""
        {"version":0,"kind":"test","payload":{"kind":"function","id":"Tests.Outer/values(value:)/File.swift:1:1"}}
        {"version":0,"kind":"test","payload":{"kind":"function","id":"Tests.known()/File.swift:2:1"}}
        {"version":0,"kind":"test","payload":{"kind":"function","id":"Tests.skipped()/File.swift:3:1"}}
        {"version":0,"kind":"event","payload":{"kind":"testStarted","testID":"Tests.Outer/values(value:)/File.swift:1:1"}}
        {"version":0,"kind":"event","payload":{"kind":"testCaseEnded","testID":"Tests.Outer/values(value:)/File.swift:1:1"}}
        {"version":0,"kind":"event","payload":{"kind":"issueRecorded","testID":"Tests.Outer/values(value:)/File.swift:1:1","issue":{"isKnown":false},"messages":[{"text":"Expected 1"}]}}
        {"version":0,"kind":"event","payload":{"kind":"testEnded","testID":"Tests.Outer/values(value:)/File.swift:1:1"}}
        {"version":0,"kind":"event","payload":{"kind":"issueRecorded","testID":"Tests.known()/File.swift:2:1","issue":{"isKnown":true}}}
        {"version":0,"kind":"event","payload":{"kind":"testEnded","testID":"Tests.known()/File.swift:2:1"}}
        {"version":0,"kind":"event","payload":{"kind":"testSkipped","testID":"Tests.skipped()/File.swift:3:1"}}
        """.utf8))
        // swiftlint:enable line_length
        let results = report.finish(selected: nil, cancelled: false)
        #expect(results.map(\.testId) == ["Outer/values(value:)", "known()", "skipped()"])
        #expect(results.map(\.status) == [.failed, .passed, .skipped])
        #expect(results.first?.message == "Expected 1")
        #expect(report.problems.isEmpty)
    }

    @Test
    func parsesDarwinAndCorelibsXCTestWithoutTreatingLogsAsResults() {
        var report = SwiftPMTestReport(module: "Tests")
        report.readXCTest("""
        Test Case '-[Tests.Example testPass]' started.
        Test Case '-[Tests.Example testPass]' passed (0.001 seconds).
        Test Case 'Example.testSkip' skipped (0.0 seconds).
        Test Case 'Example.testFail' failed (0.001 seconds).
        prefix Test Case 'Example.fake' passed (0.001 seconds).
        Test Case '-[Sibling.Example testOther]' passed (0.001 seconds).
        Test Suite 'Example' passed at 2026-11-06 14:00:00.
        """)
        let results = report.finish(selected: nil, cancelled: false)
        #expect(results.map(\.testId) == ["Example/testFail()", "Example/testPass()", "Example/testSkip()"])
        #expect(results.map(\.status) == [.failed, .passed, .skipped])
    }

    @Test
    func reportsMissingAndUnexpectedResultsAndPreservesCompletedCasesOnCancellation() {
        let target = BSPBuildTargetIdentifier(uri: URI(URL(fileURLWithPath: "/Tests")))
        let selected = [SwiftPMTestSelection.Test(target: target, id: "Example/missing()", style: "XCTest")]
        var report = SwiftPMTestReport(module: "Tests")
        report.readXCTest("""
        Test Case 'Example.done' passed (0.001 seconds).
        Test Case 'Example.running' started.
        """)
        var cancelled = report
        let results = cancelled.finish(selected: selected, cancelled: true)
        #expect(results.map(\.status) == [.passed, .cancelled])
        #expect(cancelled.problems.isEmpty)
        _ = report.finish(selected: selected, cancelled: false)
        #expect(report.problems.count == 3)
        var invalid = SwiftPMTestReport(module: "Tests")
        invalid.readSwiftTesting(Data("{invalid\n".utf8))
        #expect(invalid.finish(selected: nil, cancelled: false).isEmpty)
        #expect(invalid.problems.count == 2)
    }

    @Test
    func validatesTargetScopeAndEscapesExactSelectors() throws {
        let target = BSPBuildTargetIdentifier(uri: URI(URL(fileURLWithPath: "/Tests")))
        let other = BSPBuildTargetIdentifier(uri: URI(URL(fileURLWithPath: "/Other")))
        let selection = SwiftPMTestSelection(tests: [
            .init(target: target, id: "Outer/test(value:)", style: "swift-testing"),
            .init(target: target, id: "Example/testExample()", style: "XCTest")
        ])
        try selection.validate(requested: [target])
        #expect(throws: SwiftPMProjectError.self) { try selection.validate(requested: [other]) }
        let extracted = try SwiftPMTestSelection.extract(from: ["--skip-build", selection.encodedArgument()])
        #expect(extracted.arguments == ["--skip-build"])
        #expect(extracted.selection?.tests == selection.tests)
        let pattern = SwiftPMTestSelection.filter(module: "Tests", tests: selection.tests)
        let expression = try NSRegularExpression(pattern: pattern)
        for (id, matches) in [
            ("Tests.Outer/test(value:)/File.swift:1:1", true), ("Tests.Example/testExample", true),
            ("Tests.Example/testExampleExtra", false), ("TestsX.Outer/test(value:)", false),
            ("Other.Outer/test(value:)", false), ("Tests.Outer/testOther(value:)", false)
        ] {
            #expect((expression.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil) == matches)
        }
        for (id, style) in [
            ("Suite", "swift-testing"), ("bad\n()", "swift-testing"), ("test()", "XCTest"),
            ("Case/test()", "unknown"), ("/test()", "swift-testing")
        ] {
            #expect(throws: SwiftPMProjectError.self) {
                try SwiftPMTestSelection(tests: [.init(target: target, id: id, style: style)])
                    .validate(requested: [target])
            }
        }
    }
}
