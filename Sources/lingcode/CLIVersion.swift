import Foundation

/// The single place the CLI's version number lives.
///
/// There used to be five hardcoded copies and they had all drifted apart:
/// `--version` said 0.8.23, the REPL banner and `doctor` said 0.8.16, and the
/// telemetry heartbeat reported 0.8.21. So users saw one number, support was
/// told another, and the version analytics were simply wrong.
///
/// NOTE ON SOURCE OF TRUTH: the `cli-v*` git tags remain authoritative for what
/// has actually been *released*. This constant is what a build claims to be, and
/// it is easy to forget to bump — so treat a mismatch between this and the
/// newest tag as "unreleased dev build", not as evidence of a release.
/// Bump it in the same commit that cuts the tag.
/// Bumping this by hand kept being forgotten — 0.8.26, 0.8.27 and 0.8.28 all
/// shipped reporting "0.8.25", so a user who upgraded and ran `--version` saw the
/// old number and reasonably concluded the upgrade had failed. The comment above
/// said to bump it with the tag; comments do not enforce anything.
/// `build-cli-standalone.sh` now refuses to build when this disagrees with the
/// version it was asked to produce.
public enum CLIVersion {
    public static let current = "0.8.35"

    /// Prefixed form for UI that shows a leading `v`.
    public static var display: String { "v" + current }
}
