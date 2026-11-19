import Foundation

@main
struct ReleaseUpdateTests {
    static func main() throws {
        func version(_ tag: String, current: String = "0.4.12", draft: Bool = false, prerelease: Bool = false) throws -> String? {
            try PublishedRelease(tag_name: tag, draft: draft, prerelease: prerelease).newerVersion(than: current)
        }
        let next = try version("v0.4.13")
        let numeric = try version("0.10.0")
        let equal = try version("v0.4.12.0")
        let older = try version("v0.4.9")
        let draft = try version("1.0", draft: true)
        let preview = try version("1.0", prerelease: true)
        precondition(next == "0.4.13" && numeric == "0.10.0" && [equal, older, draft, preview].allSatisfy { $0 == nil })
        for tag in ["v1..0", "v0.5-beta", "v1.+3", "latest"] {
            do { _ = try version(tag); preconditionFailure("Invalid release tag accepted") }
            catch is URLError {}
        }
        print("Release checks passed.")
    }
}
