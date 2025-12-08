import Foundation

/// Progress information from rclone sync operation
/// Parsed from rclone's --stats JSON output
public struct SyncProgress: Sendable, Equatable {
    public let bytesTransferred: Int64
    public let bytesTotal: Int64
    public let filesTransferred: Int64
    public let filesTotal: Int64
    public let speed: Int64          // bytes per second
    public let eta: TimeInterval?    // estimated time remaining in seconds

    public init(
        bytesTransferred: Int64 = 0,
        bytesTotal: Int64 = 0,
        filesTransferred: Int64 = 0,
        filesTotal: Int64 = 0,
        speed: Int64 = 0,
        eta: TimeInterval? = nil
    ) {
        self.bytesTransferred = bytesTransferred
        self.bytesTotal = bytesTotal
        self.filesTransferred = filesTransferred
        self.filesTotal = filesTotal
        self.speed = speed
        self.eta = eta
    }

    /// Completion percentage (0.0 to 100.0)
    public var percentComplete: Double {
        guard bytesTotal > 0 else { return 0.0 }
        return Double(bytesTransferred) / Double(bytesTotal) * 100.0
    }

    /// Format speed as human-readable string
    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: speed))/s"
    }

    /// Format ETA as human-readable string
    public var formattedETA: String {
        guard let eta = eta else { return "calculating..." }
        let hours = Int(eta) / 3600
        let minutes = (Int(eta) % 3600) / 60
        let seconds = Int(eta) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return "\(seconds)s"
        }
    }

    /// Parse progress from rclone JSON stats output
    /// Expected format from rclone --use-json-log:
    /// {"level":"info","msg":"Transferred: ...","stats":{...}}
    public static func parse(from jsonString: String) -> SyncProgress? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // Handle both direct stats object and wrapped format
            let stats: [String: Any]
            if let wrappedStats = json["stats"] as? [String: Any] {
                stats = wrappedStats
            } else {
                stats = json
            }

            // Parse bytes transferred
            let bytesTransferred = parseBytes(stats["bytes"]) ?? 0

            // Parse total bytes (from totalBytes or estimatedBytes)
            let bytesTotal = parseBytes(stats["totalBytes"]) ?? parseBytes(stats["estimatedBytes"]) ?? 0

            // Parse file counts
            let filesTransferred = parseInt64(stats["transfers"]) ?? 0
            let filesTotal = parseInt64(stats["totalTransfers"]) ?? filesTransferred

            // Parse speed (bytes per second)
            let speed = parseBytes(stats["speed"]) ?? 0

            // Parse ETA
            let eta = parseETA(stats["eta"])

            return SyncProgress(
                bytesTransferred: bytesTransferred,
                bytesTotal: bytesTotal,
                filesTransferred: filesTransferred,
                filesTotal: filesTotal,
                speed: speed,
                eta: eta
            )
        } catch {
            return nil
        }
    }

    /// Parse rclone text output line for progress
    /// Format: "Transferred: 1.234 GiB / 10.000 GiB, 12%, 50.000 MiB/s, ETA 2m30s"
    public static func parseTextLine(_ line: String) -> SyncProgress? {
        // Try to extract key information using regex-like parsing
        guard line.contains("Transferred:") else { return nil }

        var bytesTransferred: Int64 = 0
        var bytesTotal: Int64 = 0
        var speed: Int64 = 0
        var eta: TimeInterval? = nil

        // Parse "X / Y" bytes pattern
        if let transferred = extractBytesValue(from: line, before: "/"),
           let total = extractBytesValue(from: line, after: "/", before: ",") {
            bytesTransferred = transferred
            bytesTotal = total
        }

        // Parse speed (e.g., "50.000 MiB/s")
        if let speedMatch = extractSpeedValue(from: line) {
            speed = speedMatch
        }

        // Parse ETA (e.g., "ETA 2m30s")
        if let etaMatch = extractETAValue(from: line) {
            eta = etaMatch
        }

        return SyncProgress(
            bytesTransferred: bytesTransferred,
            bytesTotal: bytesTotal,
            filesTransferred: 0,
            filesTotal: 0,
            speed: speed,
            eta: eta
        )
    }

    // MARK: - Private Parsing Helpers

    private static func parseBytes(_ value: Any?) -> Int64? {
        if let intValue = value as? Int64 {
            return intValue
        }
        if let intValue = value as? Int {
            return Int64(intValue)
        }
        if let doubleValue = value as? Double {
            return Int64(doubleValue)
        }
        return nil
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        if let intValue = value as? Int64 {
            return intValue
        }
        if let intValue = value as? Int {
            return Int64(intValue)
        }
        return nil
    }

    private static func parseETA(_ value: Any?) -> TimeInterval? {
        if let seconds = value as? Double {
            return seconds
        }
        if let seconds = value as? Int {
            return TimeInterval(seconds)
        }
        // Handle string format like "2m30s"
        if let etaString = value as? String {
            return parseETAString(etaString)
        }
        return nil
    }

    private static func parseETAString(_ str: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var currentNum = ""

        for char in str {
            if char.isNumber || char == "." {
                currentNum.append(char)
            } else {
                guard let num = Double(currentNum) else {
                    currentNum = ""
                    continue
                }
                switch char {
                case "h": total += num * 3600
                case "m": total += num * 60
                case "s": total += num
                default: break
                }
                currentNum = ""
            }
        }

        return total > 0 ? total : nil
    }

    private static func extractBytesValue(from line: String, before separator: String) -> Int64? {
        guard let range = line.range(of: "Transferred:") else { return nil }
        let afterTransferred = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        guard let sepRange = afterTransferred.range(of: separator) else { return nil }
        let beforeSep = String(afterTransferred[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)

        return parseHumanBytes(beforeSep)
    }

    private static func extractBytesValue(from line: String, after: String, before: String) -> Int64? {
        guard let afterRange = line.range(of: after) else { return nil }
        let remaining = String(line[afterRange.upperBound...])

        guard let beforeRange = remaining.range(of: before) else {
            return parseHumanBytes(remaining.trimmingCharacters(in: .whitespaces))
        }

        let value = String(remaining[..<beforeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return parseHumanBytes(value)
    }

    private static func extractSpeedValue(from line: String) -> Int64? {
        // Look for pattern like "50.000 MiB/s"
        let components = line.components(separatedBy: ",")
        for component in components {
            if component.contains("/s") {
                let trimmed = component.trimmingCharacters(in: .whitespaces)
                // Remove "/s" and parse
                if let range = trimmed.range(of: "/s") {
                    let speedPart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    return parseHumanBytes(speedPart)
                }
            }
        }
        return nil
    }

    private static func extractETAValue(from line: String) -> TimeInterval? {
        guard let etaRange = line.range(of: "ETA ") else { return nil }
        let afterETA = String(line[etaRange.upperBound...])

        // Find the end of the ETA value (next comma, space after time, or end of string)
        var etaStr = ""
        for char in afterETA {
            if char == "," || (char == " " && !etaStr.isEmpty) {
                break
            }
            if char.isNumber || char == "h" || char == "m" || char == "s" {
                etaStr.append(char)
            }
        }

        return parseETAString(etaStr)
    }

    private static func parseHumanBytes(_ str: String) -> Int64? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let components = trimmed.split(separator: " ", maxSplits: 1)

        guard components.count >= 1 else { return nil }

        guard let number = Double(components[0]) else { return nil }

        let multiplier: Double
        if components.count == 2 {
            let unit = String(components[1]).uppercased()
            switch unit {
            case "B", "BYTES": multiplier = 1
            case "KB", "KIB": multiplier = 1024
            case "MB", "MIB": multiplier = 1024 * 1024
            case "GB", "GIB": multiplier = 1024 * 1024 * 1024
            case "TB", "TIB": multiplier = 1024 * 1024 * 1024 * 1024
            default: multiplier = 1
            }
        } else {
            multiplier = 1
        }

        return Int64(number * multiplier)
    }
}
