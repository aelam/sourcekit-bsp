//
//  SourceKitBSP.swift
//
//  Copyright © 2024 Wang Lun.

import BSPServer
import BuildServerProtocol
import Foundation
import JSONRPCConnection
import Logger
import SwiftyBeaver
#if os(macOS)
import XcodeProjectManagerProvider
#endif
import SwiftPMProjectManagerProvider

@main
struct SourceKitBSP {
    static func main() async {
        // 获取环境信息
        let processID = ProcessInfo.processInfo.processIdentifier
        let environment = ProcessInfo.processInfo.environment["BSP_ENVIRONMENT"] ?? "development"

        // Log startup message
        logger.info(
            "sourcekit-bsp started successfully - PID: \(processID) - Environment: \(environment)"
        )

        let arguments = CommandLine.arguments

        // Parse command line arguments before starting the BSP server.
        if arguments.count > 1 {
            let firstArg = arguments[1]
            if firstArg == "--help" || firstArg == "-h" {
                printUsage()
                exit(0)
            } else if firstArg == "--version" {
                print(SourceKitBSPVersion.current)
                exit(0)
            } else if firstArg == "xcode-project" {
                #if os(macOS)
                await XcodeProjectCommand.main(Array(arguments.dropFirst(2)))
                #else
                print("The xcode-project command is only available on macOS.")
                #endif
                exit(0)
            }
        }

        // Check for debug mode from environment variable
        let isDebugMode = ProcessInfo.processInfo.environment["BSP_DEBUG"] != nil ||
            arguments.contains("--debug")

        if isDebugMode {
            logger.debug("🔧 BSP Debug Mode Enabled - PID: \(processID)")
        }

        // 使用清晰的分层架构 - BSPServerService 作为服务层
        // 使用工厂来管理多个项目管理器提供者
        let factory = await ProjectManagerProviderRegistry.createFactory()
        let bspService = BSPServerService.createStdioService(projectManagerProvider: factory)

        // Monitor parent process at a reasonable interval using Task
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                killSelfIfParentIsNull()
            }
        }

        // 获取当前工作目录作为项目路径
        let projectURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        logger.info("Project directory: \(projectURL.path)")

        do {
            try await bspService.start()
        } catch {
            // Log error
            let errorMsg = "BSP Server failed to start: \(error)"
            logger.error(errorMsg)
            exit(1)
        }
    }

    private static func printUsage() {
        print("Usage: sourcekit-bsp")
        print("")
        print("Description:")
        print("  Starts an sourcekit-bsp Protocol (BSP) server that communicates")
        print("  via JSON-RPC over stdin/stdout. The server waits for BSP requests")
        print("  from compatible IDEs or tools.")
        print("")
        print("  Project discovery happens when the client sends a 'build/initialize'")
        print("  request with the workspace root URI.")
        print("")
        print("Options:")
        print("  -h, --help      Show this help message and exit")
        print("  --version       Show the version and exit")
        print("  xcode-project   Inspect or compile Xcode projects")
        print("")
        print("BSP Protocol:")
        print("  The server implements the Build Server Protocol specification.")
        print("  See: https://build-server-protocol.github.io/")
        print("")
        print("Examples:")
        print("  sourcekit-bsp                    # Start BSP server")
        print("  sourcekit-bsp xcode-project --help")
        print("  sourcekit-bsp xcode-project resolve-project --workspace-folder /path/to/project")
        print("  echo '{\"id\":1,\"method\":\"build/initialize\"...}' | sourcekit-bsp")
    }

    private static func killSelfIfParentIsNull() {
        let parentPID = getppid()

        // Exit if parent became init (original parent died)
        if parentPID == 1 {
            logger.warning("🔴 Parent process died, terminating...")
            exit(0)
        }

        // Exit if parent process no longer exists
        if kill(parentPID, 0) == -1, errno == ESRCH {
            logger.warning("🔴 Parent process (PID \(parentPID)) not found, terminating...")
            exit(0)
        }
    }
}
