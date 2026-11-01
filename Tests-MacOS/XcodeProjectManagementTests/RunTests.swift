import Foundation
import Testing
@testable import XcodeProjectManagement

struct RunTests {
    private func makeManager() -> XcodeProjectManager {
        let root = FileManager.default.temporaryDirectory
        let toolchain = XcodeToolchain(workingDirectory: root)
        return XcodeProjectManager(
            rootURL: root, toolchain: toolchain, projectLocator: XcodeProjectLocator(),
            settingsLoader: XcodeSettingsLoader(commandBuilder: XcodeBuildCommandBuilder(), toolchain: toolchain)
        )
    }

    @Test
    func usesResolvedProductPaths() async {
        let manager = makeManager()
        let simulator = await manager.getOutputPath(buildSettings: [
            "TARGET_BUILD_DIR": "/tmp/Custom/Debug-iphonesimulator",
            "FULL_PRODUCT_NAME": "Renamed.app",
            "CONFIGURATION_BUILD_DIR": "/tmp/Old",
            "PRODUCT_NAME": "OldName"
        ], productType: .application, isMacApp: false)
        #expect(simulator == "/tmp/Custom/Debug-iphonesimulator/Renamed.app")
        let mac = await manager.getOutputPath(buildSettings: [
            "TARGET_BUILD_DIR": "/tmp/Custom/Debug",
            "EXECUTABLE_PATH": "Renamed.app/Contents/MacOS/CustomExecutable"
        ], productType: .application, isMacApp: true)
        #expect(mac == "/tmp/Custom/Debug/Renamed.app/Contents/MacOS/CustomExecutable")
    }

    @Test
    func resolvesConcreteDestination() async {
        let manager = makeManager()
        let composite = await manager.getDestination(
            from: ["-destination", "platform=iOS Simulator, id=SIM-UDID,OS=latest"],
            buildSettings: ["TARGET_DEVICE_IDENTIFIER": "OTHER"]
        )
        #expect(composite == "SIM-UDID")
        let named = await manager.getDestination(
            from: ["-destination", "platform=iOS Simulator,name=iPhone"],
            buildSettings: ["TARGET_DEVICE_IDENTIFIER": "RESOLVED-UDID"]
        )
        #expect(named == "RESOLVED-UDID")
        let generic = await manager.getDestination(
            from: ["-destination", "generic/platform=iOS Simulator"],
            buildSettings: ["TARGET_DEVICE_IDENTIFIER": "simulator:placeholder"]
        )
        #expect(generic == nil)
    }

    @Test
    func preservesBuildSettingsErrorMessage() {
        let error = XcodeProjectError.invalidConfig("Unable to find destination BSP-NOT-A-DEVICE")
        #expect(error.localizedDescription.contains("Unable to find destination BSP-NOT-A-DEVICE"))
    }
}
