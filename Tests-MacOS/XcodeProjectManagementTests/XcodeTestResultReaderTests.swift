import BuildServerProtocol
import Foundation
import Testing
@testable import XcodeProjectManagement

struct XcodeTestResultReaderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BSP_TEST_RESULT_BUNDLE"] != nil))
    func readsAnExistingResultBundleWithTheSelectedXcode() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BSP_TEST_RESULT_BUNDLE"])
        let bundle = URL(fileURLWithPath: path)
        let toolchain = XcodeToolchain(workingDirectory: bundle.deletingLastPathComponent())
        try await toolchain.initialize()
        let report = try await XcodeTestResultReader.read(bundle: bundle, toolchain: toolchain)
        #expect(!report.tests.isEmpty)
        #expect(report.tests.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test
    func readsCasesWithoutDoubleCountingParallelRunsOrParameters() throws {
        let json = #"""
        {"testNodes":[{"nodeType":"Test Plan","name":"Plan","durationInSeconds":1.25,"children":[
          {"nodeType":"Unit test bundle","name":"Tests","children":[
            {"nodeType":"Test Case","name":"example()","nodeIdentifier":"Suite/example()","result":"Passed",
             "children":[{"nodeType":"Test Case Run","name":"Device 1","result":"Passed"},
                         {"nodeType":"Test Case Run","name":"Device 2","result":"Passed"}]},
            {"nodeType":"Test Case","name":"failure","result":"Failed","children":[
              {"nodeType":"Repetition","name":"Attempt 1","children":[
                {"nodeType":"Failure Message","name":"Expected 1, got 2"}]}]},
            {"nodeType":"Test Case","name":"skip","result":"Skipped"},
            {"nodeType":"Test Case","name":"knownIssue","result":"Expected Failure"}
          ]}]}]}
        """#
        let report = try XcodeTestResultReader.decode(Data(json.utf8))
        #expect(report.tests.count == 4)
        #expect(report.tests.map(\.status) == [.passed, .failed, .skipped, .passed])
        #expect(report.tests[0].displayName == "Suite/example()")
        #expect(report.tests[1].message == "Expected 1, got 2")
        #expect(report.tests[3].message == "Expected failure")
        #expect(report.time == 1250)
    }

    @Test
    func rejectsUnknownResultsInsteadOfReportingSuccess() throws {
        let json = #"{"testNodes":[{"nodeType":"Test Case","name":"unknown","result":"unknown"}]}"#
        #expect(throws: (any Error).self) { try XcodeTestResultReader.decode(Data(json.utf8)) }
        #expect(throws: (any Error).self) { try XcodeTestResultReader.decode(Data("{}".utf8)) }
        let empty = try XcodeTestResultReader.decode(Data(#"{"testNodes":[]}"#.utf8))
        #expect(empty.tests.isEmpty)
        #expect(empty.time == nil)
    }
}
