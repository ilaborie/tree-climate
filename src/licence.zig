//! The licence policy, in one place, and away from anything to do with the
//! network: which licences may be used at all.

const std = @import("std");

/// ND licences are deliberately absent. A resized thumbnail is a derivative
/// work, so "no derivatives" means the image cannot be published here at all.
pub const accepted = [_][]const u8{
    "cc0",
    "domaine-public",
    "cc-by",
    "cc-by-sa",
    "cc-by-nc",
    "cc-by-nc-sa",
};

pub fn isAccepted(code: []const u8) bool {
    for (accepted) |known| {
        if (std.mem.eql(u8, known, code)) return true;
    }
    return false;
}

test "the accepted set is exactly the six licences the data uses" {
    try std.testing.expect(isAccepted("cc-by-sa"));
    try std.testing.expect(isAccepted("domaine-public"));
    try std.testing.expect(!isAccepted("cc-by-nd"));
    try std.testing.expect(!isAccepted("all-rights-reserved"));
    try std.testing.expect(!isAccepted(""));
}
