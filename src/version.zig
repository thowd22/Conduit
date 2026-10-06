//! The version Conduit was built as.
//!
//! The value comes from the build: `zig build -Dversion=<semver>` stamps it
//! through the generated `build_options` module, and a build without the flag
//! reports the `0.0.0-dev` placeholder. TASK-69.1's release workflow passes the
//! Git tag with its leading `v` removed, so a packaged `conduit --version`
//! reports exactly the tag it was cut from. `build.zig` has already refused
//! anything that is not SemVer 2.0.0 by the time this module compiles.

const std = @import("std");
const build_options = @import("build_options");

/// The stamped version, as `conduit --version` prints it after `conduit `.
pub const version: [:0]const u8 = build_options.version;

test "stamped version is a SemVer 2.0.0 version without a tag prefix" {
    const parsed = try std.SemanticVersion.parse(version);
    try std.testing.expect(!std.mem.startsWith(u8, version, "v"));
    try std.testing.expectEqual(version.len, std.mem.len(version.ptr));
    // A build with no `-Dversion=` carries the development placeholder; a
    // release build carries no `dev` prerelease identifier.
    if (std.mem.eql(u8, version, "0.0.0-dev")) {
        try std.testing.expectEqualStrings("dev", parsed.pre.?);
    }
}
