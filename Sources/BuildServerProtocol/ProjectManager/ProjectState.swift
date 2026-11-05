//
//  ProjectState.swift
//  Core Module
//
//  Copyright © 2024 Wang Lun.
//

import Foundation

public struct ProjectState: Sendable {
    public var projectLoadState: ProjectLoadState = .uninitialized
    public var activeBuildTasks: [String: BuildTask] = [:]
    public var indexState: IndexState = .idle

    public init() {}
}

public enum ProjectLoadState: Sendable {
    case uninitialized
    case loading(projectPath: String)
    case loaded(projectInfo: BSPProject)
    case failed(Error)
}

public enum BuildTargetChangeState: Sendable {
    public struct BuildTargetEvent: Codable, Hashable, Sendable {
        public enum BuildTargetEventKind: Int, Codable, Hashable, Sendable {
            /// The build target is new.
            case created = 1

            /// The build target has changed.
            case changed = 2

            /// The build target has been deleted.
            case deleted = 3
        }

        /// The identifier for the changed build target.
        public var target: String

        /// The kind of change for this build target.
        public var kind: BuildTargetEventKind?

        // Kind of data to expect in the `data` field. If this field is not set, the kind of data is not specified.
        // public var dataKind: BuildTargetEventDataKind?
    }

    case none
    case changed(event: [BuildTargetEvent])
}

public struct BuildTask: Sendable {
    public let target: String
    public let startTime: Date
    public var status: BuildTaskStatus

    public init(target: String) {
        self.target = target
        self.startTime = Date()
        self.status = .running
    }
}

public enum BuildTaskStatus: Sendable {
    case running
    case completed(success: Bool, duration: TimeInterval)
    case failed(Error)
}

public enum IndexState: Sendable {
    case idle
    case preparing
    case indexing(progress: Double, message: String)
    case completed
    case failed(Error)
}

public enum ProjectStateEvent: Sendable {
    case projectLoadStateChanged(from: ProjectLoadState, to: ProjectLoadState)
    case buildStarted(target: String)
    case buildProgress(target: String, progress: Double, message: String)
    case buildCompleted(target: String, success: Bool, duration: TimeInterval)
    case buildFailed(target: String, error: Error)
    case indexStateChanged(from: IndexState, to: IndexState)
}

public protocol ProjectStateObserver: AnyObject, Sendable {
    func onProjectStateChanged(_ event: ProjectStateEvent) async
}

public struct WeakProjectStateObserver {
    public weak var observer: ProjectStateObserver?

    public init(_ observer: ProjectStateObserver) {
        self.observer = observer
    }
}
