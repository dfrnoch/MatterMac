// Release versioning for CI (development tool; not linked into the app).
//
// The single source of truth is `MARKETING_VERSION` in
// Apps/MatterMac/Configuration/Shared.xcconfig: the version of the next production
// release, `MAJOR.MINOR.PATCH`.
//
//   swift Tools/ReleaseVersion.swift current
//       → 1.0.0
//   swift Tools/ReleaseVersion.swift nightly <build-number> [yyyymmdd]
//       → 1.0.0-nightly.20260923.45   (date defaults to today in UTC)
//   swift Tools/ReleaseVersion.swift next <major|minor|patch> [version]
//       → the version after `version` (default: current)
//   swift Tools/ReleaseVersion.swift set <version>
//       → rewrites MARKETING_VERSION in Shared.xcconfig
//
// Every command validates its input and exits non-zero with a message on stderr.

import Foundation

let xcconfig = URL(fileURLWithPath: "Apps/MatterMac/Configuration/Shared.xcconfig")

struct Version: CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    func bumped(_ part: String) -> Version? {
        var next = self
        switch part {
        case "major": next.major += 1; next.minor = 0; next.patch = 0
        case "minor": next.minor += 1; next.patch = 0
        case "patch": next.patch += 1
        default: return nil
        }
        return next
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readConfig() -> String {
    guard let text = try? String(contentsOf: xcconfig, encoding: .utf8) else { fail("cannot read \(xcconfig.path)") }
    return text
}

/// The `MARKETING_VERSION = x.y.z` line (exactly one, at the start of a line).
func currentVersion(in text: String) -> Version {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { $0.hasPrefix("MARKETING_VERSION") }
    guard lines.count == 1, let value = lines[0].split(separator: "=", maxSplits: 1).last,
          let version = Version(value.trimmingCharacters(in: .whitespaces)) else {
        fail("Shared.xcconfig must contain exactly one `MARKETING_VERSION = MAJOR.MINOR.PATCH` line")
    }
    return version
}

func utcDate() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: Date())
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: current | nightly <build> [yyyymmdd] | next <part> [version] | set <version>") }
arguments.removeFirst()

switch command {
case "current":
    print(currentVersion(in: readConfig()))

case "nightly":
    guard let build = arguments.first, let number = Int(build), number > 0, String(number) == build else {
        fail("nightly needs a positive build number")
    }
    let date = arguments.count > 1 ? arguments[1] : utcDate()
    guard date.count == 8, date.allSatisfy(\.isNumber) else { fail("date must be yyyymmdd") }
    print("\(currentVersion(in: readConfig()))-nightly.\(date).\(number)")

case "next":
    guard let part = arguments.first else { fail("next needs major, minor or patch") }
    let base: Version
    if arguments.count > 1 {
        guard let given = Version(arguments[1]) else { fail("invalid version \(arguments[1])") }
        base = given
    } else {
        base = currentVersion(in: readConfig())
    }
    guard let next = base.bumped(part) else { fail("next needs major, minor or patch") }
    print(next)

case "set":
    guard let value = arguments.first, let version = Version(value) else { fail("set needs MAJOR.MINOR.PATCH") }
    let text = readConfig()
    _ = currentVersion(in: text)
    let updated = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.hasPrefix("MARKETING_VERSION") ? "MARKETING_VERSION = \(version)" : String(line)
    }.joined(separator: "\n")
    do { try updated.write(to: xcconfig, atomically: true, encoding: .utf8) } catch { fail("cannot write Shared.xcconfig") }
    print(version)

default:
    fail("unknown command \(command)")
}
