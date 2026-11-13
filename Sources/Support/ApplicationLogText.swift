import Foundation

public enum ApplicationLogText {
    private static let mirrorTimestamp = try? NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3,9}(?:[+-]\d{4})? (?=[^\s\[]+\[\d+:[^\]]+\] )"#,
        options: .anchorsMatchLines
    )

    public static func forBuildLog(_ text: String, stripMirrorTimestamp: Bool) -> String {
        var message = text
        if stripMirrorTimestamp, let mirrorTimestamp {
            message = mirrorTimestamp.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        if message.hasSuffix("\n") { message.removeLast() }
        return message
    }
}
