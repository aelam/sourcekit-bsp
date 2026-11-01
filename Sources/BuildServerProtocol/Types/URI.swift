// ===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// ===----------------------------------------------------------------------===//

#if compiler(>=6)
public import Foundation
#else
import Foundation
#endif

struct FailedToConstructURIFromStringError: Error, CustomStringConvertible {
    let string: String

    var description: String {
        "Failed to construct URI from '\(string)'"
    }
}

public struct URI: Codable, Hashable, Sendable {
    /// The URL that store the URIs value
    private let storage: URL

    public var description: String {
        storage.description
    }

    public var fileURL: URL? {
        if storage.isFileURL {
            storage
        } else {
            nil
        }
    }

    /// The URL representation of the URI. Note that this URL can have an arbitrary scheme and might
    /// not represent a file URL.
    public var arbitrarySchemeURL: URL {
        storage
    }

    /// The document's URL scheme, if present.
    public var scheme: String? {
        storage.scheme
    }

    /// Returns a filepath if the URI is a URL. If the URI is not a URL, returns
    /// the full URI as a fallback.
    /// This value is intended to be used when interacting with sourcekitd which
    /// expects a file path but is able to handle arbitrary strings as well in a
    /// fallback mode that drops semantic functionality.
    public var pseudoPath: String {
        if storage.isFileURL {
            storage.withUnsafeFileSystemRepresentation {
                String(cString: $0!)
            }
        } else {
            storage.absoluteString
        }
    }

    /// Returns the URI as a string.
    public var stringValue: String {
        storage.absoluteString
    }

    /// Construct a URI from the given URI string, automatically parsing
    ///  it either as a URL or an opaque URI.
    public init(string: String) throws {
        guard let url = URL(string: string) else {
            throw FailedToConstructURIFromStringError(string: string)
        }
        self.init(url)
    }

    public init(_ url: URL) {
        storage = url
        assert(storage.scheme != nil, "Received invalid URI without a scheme '\(storage.absoluteString)'")
    }

    public init(filePath: String, isDirectory: Bool) {
        self.init(URL(fileURLWithPath: filePath, isDirectory: isDirectory))
    }

    public init(from decoder: Decoder) throws {
        try self.init(string: decoder.singleValueContainer().decode(String.self))
    }

    /// Equality check to handle escape sequences in file URLs.
    public static func == (lhs: URI, rhs: URI) -> Bool {
        lhs.storage.scheme == rhs.storage.scheme && lhs.pseudoPath == rhs.pseudoPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.scheme)
        hasher.combine(pseudoPath)
    }

    public func encode(to encoder: Encoder) throws {
        try storage.absoluteString.encode(to: encoder)
    }
}
