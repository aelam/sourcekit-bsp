import Foundation
import Testing
@testable import XcodeProjectManagement

struct LanguageStandardProviderTests {
    @Test
    func normalizesXcodeSwiftVersions() {
        let cases = [
            (xcode: "4.0", compiler: "4"),
            (xcode: "4.2", compiler: "4.2"),
            (xcode: "5.0", compiler: "5"),
            (xcode: "5.10", compiler: "5"),
            (xcode: "6.0", compiler: "6"),
            (xcode: "6.1", compiler: "6"),
            (xcode: "6", compiler: "6"),
        ]

        for item in cases {
            let arguments = LanguageStandardProvider().arguments(
                for: context(swiftVersion: item.xcode)
            )
            #expect(arguments == ["-swift-version", item.compiler])
        }
    }

    private func context(swiftVersion: String) -> ArgContext {
        ArgContext(
            buildSettings: ["SWIFT_VERSION": swiftVersion],
            languageDialect: XcodeLanguageDialect(fileExtension: "swift"),
            compiler: .swift,
            fileURL: nil,
            sourceItems: [],
            derivedDataPath: URL(fileURLWithPath: "/tmp/DerivedData/Project"),
            xcodeInstallation: nil
        )
    }
}
