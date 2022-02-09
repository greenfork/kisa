//! Public buffer API, all the functions that are based on a lower-level implementation-specific
//! buffer API. Only these functions are used to operate in the editor.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const kisa = @import("kisa");
const BufferImpl = @import("text_buffer_array.zig").Buffer;

const Sel = kisa.Selection;
const Sels = kisa.Selections;
const Pos = kisa.TextBufferPosition;

pub fn forwardChar(b: BufferImpl, s: Sel) Sel {
    return s.move(@intCast(Sel.Offset, b.nextCodepointOffset(s.cursor)));
}
pub fn backwardChar(b: BufferImpl, s: Sel) Sel {
    return s.move(@intCast(Sel.Offset, b.prevCodepointOffset(s.cursor)));
}

const s0 = Sel{ .cursor = 0, .anchor = 0 };
const s1 = Sel{ .cursor = 1, .anchor = 1 };
const s2 = Sel{ .cursor = 2, .anchor = 2 };
const s3 = Sel{ .cursor = 3, .anchor = 3 };
const s4 = Sel{ .cursor = 4, .anchor = 4 };
const s5 = Sel{ .cursor = 5, .anchor = 5 };
const s6 = Sel{ .cursor = 6, .anchor = 6 };
const s7 = Sel{ .cursor = 7, .anchor = 7 };
const s8 = Sel{ .cursor = 8, .anchor = 8 };
const s9 = Sel{ .cursor = 9, .anchor = 9 };
const s10 = Sel{ .cursor = 10, .anchor = 10 };
const s11 = Sel{ .cursor = 11, .anchor = 11 };

test "api: forwardChar" {
    const text =
        \\Dobrý
        \\deň
    ;
    var buffer = try BufferImpl.initWithText(testing.allocator, text);
    defer buffer.deinit();
    try testing.expectEqual(s1, forwardChar(buffer, s0));
    try testing.expectEqual(s2, forwardChar(buffer, s1));
    try testing.expectEqual(s3, forwardChar(buffer, s2));
    try testing.expectEqual(s4, forwardChar(buffer, s3));
    try testing.expectEqual(s6, forwardChar(buffer, s4));
    try testing.expectEqual(s6, forwardChar(buffer, s5));
    try testing.expectEqual(s7, forwardChar(buffer, s6));
    try testing.expectEqual(s8, forwardChar(buffer, s7));
    try testing.expectEqual(s9, forwardChar(buffer, s8));
    try testing.expectEqual(s9, forwardChar(buffer, s9));
    try testing.expectEqual(s9, forwardChar(buffer, s10));
    try testing.expectEqual(s9, forwardChar(buffer, s11));
}
