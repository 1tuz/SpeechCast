import Foundation

/// One shipping app, one bundle id; a local build has no release stream and never updates itself.
/// The running version decides the cadence: a beta build follows the prerelease stream, a stable
/// build the release stream, and either may land on the other's newest — a beta advances to its
/// own stable release under the same bundle id.
enum ReleaseChannel: Sendable, Equatable {
    case stable
    case beta
    case development
    init(bundleID: String?, runningVersion: AppVersion?) {
        switch bundleID {
        case "com.tinycast.app":
            self = runningVersion?.isPrerelease == true ? .beta : .stable
        default:
            self = .development
        }
    }

    /// The pre-version form: the bundle id alone cannot tell a beta run from a stable one, so
    /// it answers the stable channel, which is the only stream a versionless caller reads.
    init(bundleID: String?) {
        self.init(bundleID: bundleID, runningVersion: nil)
    }

    var updatesItself: Bool { self != .development }

    /// What the channel offers. The beta channel takes betas and stable releases both, so a
    /// beta can advance to its own stable release; the stable channel takes releases only, so a
    /// beta run is never downgraded by a feed whose newest stable is older than the running beta.
    func accepts(prerelease: Bool) -> Bool {
        switch self {
        case .stable: return !prerelease
        case .beta: return true
        case .development: return false
        }
    }
}
