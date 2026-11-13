import Testing
@testable import Logger

struct LoggerConfigurationTests {
    @Test(arguments: [
        ([String](), false),
        (["sourcekit-bsp"], false),
        (["sourcekit-bsp", "--debug"], true),
        (["sourcekit-bsp", "--enable-build-target-prepare", "--debug"], true),
        (["sourcekit-bsp", "--debugger"], false)
    ])
    func debugLoggingRequiresTheLaunchFlag(arguments: [String], expected: Bool) {
        #expect(SwiftyBeaverLogger.debugEnabled(arguments: arguments) == expected)
    }
}
