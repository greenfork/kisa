const std = @import("std");
const json = std.json;
const testing = std.testing;

const jsonrpc_version = "2.0";
const default_parse_options = json.ParseOptions{
    .allocator = null,
    .duplicate_field_behavior = .Error,
    .ignore_unknown_fields = false,
    .allow_trailing_data = false,
};

/// Primitive json value which can be represented as Zig value.
/// Includes all json values but "object". For objects one should construct a Zig struct.
pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []const Value,
};

pub fn Request(comptime ParamsShape: type) type {
    return struct {
        jsonrpc: []const u8,
        method: []const u8,
        id: ?i64 = null,
        params: ParamsShape,

        const Self = @This();

        pub fn parse(allocator: *std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            return try json.parse(Self, &token_stream, parse_options);
        }

        pub fn free(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }
    };
}

pub const SimpleRequest = Request(Value);

// TODO: add `data` field.
pub const ResponseErrorImpl = struct { code: i64, message: []const u8 };

pub fn Response(comptime ResultShape: type) type {
    return struct {
        jsonrpc: []const u8,
        id: i64,
        result: ?ResultShape = null,
        @"error": ?ResponseErrorImpl = null,

        const Self = @This();

        /// Parses a string into specified `Response` structure. Requires `allocator` if
        /// any of the `Response` values are arrays/pointers/slices; pass `null` otherwise.
        pub fn parse(allocator: ?*std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            return try json.parse(Self, &token_stream, parse_options);
        }

        pub fn free(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }
    };
}

pub const SimpleResponse = Response(Value);

test "parse request" {
    const params = [_]Value{ .{ .string = "Bob" }, .{ .string = "Alice" }, .{ .integer = 10 } };
    const params_array = .{ .array = std.mem.span(&params) };
    const request = SimpleRequest{
        .jsonrpc = jsonrpc_version,
        .method = "startParty",
        .params = params_array,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":63}
    ;
    const parsed = try SimpleRequest.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(request.jsonrpc, parsed.jsonrpc);
    try testing.expectEqualStrings(request.method, parsed.method);
    try testing.expectEqualStrings(request.params.array[0].string, parsed.params.array[0].string);
    try testing.expectEqualStrings(request.params.array[1].string, parsed.params.array[1].string);
    try testing.expectEqual(request.params.array[2].integer, parsed.params.array[2].integer);
    try testing.expectEqual(request.id, parsed.id);
    parsed.free(testing.allocator);
}

const Face = struct {
    fg: []const u8,
    bg: []const u8,
    attributes: []const []const u8 = std.mem.span(&empty_attr),

    const empty_attr = [_][]const u8{};
};
const Span = struct {
    face: Face,
    contents: []const u8,
};

fn expectEqualFaces(expected: Face, actual: Face) !void {
    try testing.expectEqualStrings(expected.fg, actual.fg);
    try testing.expectEqualStrings(expected.bg, actual.bg);
    var i: usize = 0;
    while (i < expected.attributes.len) : (i += 1) {
        try testing.expectEqualStrings(expected.attributes[i], actual.attributes[i]);
    }
}

fn expectEqualSpans(expected: Span, actual: Span) !void {
    try expectEqualFaces(expected.face, actual.face);
    try testing.expectEqualStrings(expected.contents, actual.contents);
}

test "parse complex request" {
    const reverse_attr = [_][]const u8{"reverse"};
    const final_attr = [_][]const u8{ "final_fg", "final_bg" };
    const Parameter = union(enum) {
        lines: []const []const Span,
        face: Face,
    };
    const ParamsShape = []const Parameter;
    const MyRequest = Request(ParamsShape);

    const first_line_array = [_]Span{
        Span{
            .face = Face{ .fg = "default", .bg = "default", .attributes = std.mem.span(&reverse_attr) },
            .contents = " 1",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = " ",
        },
        Span{
            .face = Face{ .fg = "black", .bg = "white", .attributes = std.mem.span(&final_attr) },
            .contents = "*",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = "** this is a *scratch* buffer",
        },
    };
    const second_line_array = [_]Span{
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = " 1 ",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = "*** use it for notes",
        },
    };
    const lines_array = [_][]const Span{
        std.mem.span(&first_line_array),
        std.mem.span(&second_line_array),
    };
    const params = [_]Parameter{
        .{ .lines = std.mem.span(&lines_array) },
        .{ .face = Face{ .fg = "default", .bg = "default" } },
        .{ .face = Face{ .fg = "blue", .bg = "default" } },
    };
    const params_array = std.mem.span(&params);
    const request = MyRequest{
        .jsonrpc = jsonrpc_version,
        .method = "draw",
        .params = params_array,
    };
    // Taken from Kakoune editor and modified.
    const jsonrpc_string =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "draw",
        \\  "params": [
        \\      [
        \\          [
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": [
        \\                          "reverse"
        \\                      ]
        \\                  },
        \\                  "contents": " 1"
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": " "
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "black",
        \\                      "bg": "white",
        \\                      "attributes": [
        \\                          "final_fg",
        \\                          "final_bg"
        \\                      ]
        \\                  },
        \\                  "contents": "*"
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": "** this is a *scratch* buffer"
        \\              }
        \\          ],
        \\          [
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": " 1 "
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": "*** use it for notes"
        \\              }
        \\          ]
        \\      ],
        \\      {
        \\          "fg": "default",
        \\          "bg": "default",
        \\          "attributes": []
        \\      },
        \\      {
        \\          "fg": "blue",
        \\          "bg": "default",
        \\          "attributes": []
        \\      }
        \\  ]
        \\}
    ;
    const parsed = try MyRequest.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(request.jsonrpc, parsed.jsonrpc);
    try testing.expectEqualStrings(request.method, parsed.method);
    try testing.expectEqual(request.id, parsed.id);

    var line_idx: usize = 0;
    const lines = request.params[0].lines;
    while (line_idx < lines.len) : (line_idx += 1) {
        var span_idx: usize = 0;
        const spans = lines[line_idx];
        while (span_idx < spans.len) : (span_idx += 1) {
            try expectEqualSpans(spans[span_idx], parsed.params[0].lines[line_idx][span_idx]);
        }
    }

    try expectEqualFaces(request.params[1].face, parsed.params[1].face);
    try expectEqualFaces(request.params[2].face, parsed.params[2].face);
    parsed.free(testing.allocator);
}

test "parse success response" {
    const data = Value{ .integer = 42 };
    const response = SimpleResponse{
        .jsonrpc = jsonrpc_version,
        .result = data,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","result":42,"id":63}
    ;
    const parsed = try SimpleResponse.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc, parsed.jsonrpc);
    try testing.expectEqual(response.result.?.integer, parsed.result.?.integer);
    try testing.expectEqual(response.id, parsed.id);
    parsed.free(testing.allocator);
}

test "parse error response" {
    const data = ResponseErrorImpl{ .code = 13, .message = "error message" };
    const response = SimpleResponse{
        .jsonrpc = jsonrpc_version,
        .@"error" = data,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","error":{"code":13,"message":"error message"},"id":63}
    ;
    const parsed = try SimpleResponse.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc, parsed.jsonrpc);
    try testing.expectEqual(response.@"error".?.code, parsed.@"error".?.code);
    try testing.expectEqualStrings(response.@"error".?.message, parsed.@"error".?.message);
    try testing.expectEqual(response.id, parsed.id);
    parsed.free(testing.allocator);
}

test "parse array response" {
    const data = [_]Value{ .{ .integer = 42 }, .{ .string = "The Answer" } };
    const array_data = .{ .array = std.mem.span(&data) };
    const response = SimpleResponse{
        .jsonrpc = jsonrpc_version,
        .result = array_data,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","result":[42,"The Answer"],"id":63}
    ;
    const parsed = try SimpleResponse.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc, parsed.jsonrpc);
    try testing.expectEqual(response.result.?.array[0].integer, parsed.result.?.array[0].integer);
    try testing.expectEqualStrings(response.result.?.array[1].string, parsed.result.?.array[1].string);
    try testing.expectEqual(response.id, parsed.id);
    parsed.free(testing.allocator);
}

test "parse complex response" {
    const reverse_attr = [_][]const u8{"reverse"};
    const final_attr = [_][]const u8{ "final_fg", "final_bg" };
    const Parameter = union(enum) {
        lines: []const []const Span,
        face: Face,
    };
    const ResultShape = []const Parameter;
    const MyResponse = Response(ResultShape);

    const first_line_array = [_]Span{
        Span{
            .face = Face{ .fg = "default", .bg = "default", .attributes = std.mem.span(&reverse_attr) },
            .contents = " 1",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = " ",
        },
        Span{
            .face = Face{ .fg = "black", .bg = "white", .attributes = std.mem.span(&final_attr) },
            .contents = "*",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = "** this is a *scratch* buffer",
        },
    };
    const second_line_array = [_]Span{
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = " 1 ",
        },
        Span{
            .face = Face{ .fg = "default", .bg = "default" },
            .contents = "*** use it for notes",
        },
    };
    const lines_array = [_][]const Span{
        std.mem.span(&first_line_array),
        std.mem.span(&second_line_array),
    };
    const params = [_]Parameter{
        .{ .lines = std.mem.span(&lines_array) },
        .{ .face = Face{ .fg = "default", .bg = "default" } },
        .{ .face = Face{ .fg = "blue", .bg = "default" } },
    };
    const params_array = std.mem.span(&params);
    const response = MyResponse{
        .jsonrpc = jsonrpc_version,
        .result = params_array,
        .id = 98,
    };
    // Taken from Kakoune editor and modified.
    const jsonrpc_string =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 98,
        \\  "result": [
        \\      [
        \\          [
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": [
        \\                          "reverse"
        \\                      ]
        \\                  },
        \\                  "contents": " 1"
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": " "
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "black",
        \\                      "bg": "white",
        \\                      "attributes": [
        \\                          "final_fg",
        \\                          "final_bg"
        \\                      ]
        \\                  },
        \\                  "contents": "*"
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": "** this is a *scratch* buffer"
        \\              }
        \\          ],
        \\          [
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": " 1 "
        \\              },
        \\              {
        \\                  "face": {
        \\                      "fg": "default",
        \\                      "bg": "default",
        \\                      "attributes": []
        \\                  },
        \\                  "contents": "*** use it for notes"
        \\              }
        \\          ]
        \\      ],
        \\      {
        \\          "fg": "default",
        \\          "bg": "default",
        \\          "attributes": []
        \\      },
        \\      {
        \\          "fg": "blue",
        \\          "bg": "default",
        \\          "attributes": []
        \\      }
        \\  ]
        \\}
    ;
    const parsed = try MyResponse.parse(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc, parsed.jsonrpc);
    try testing.expectEqual(response.id, parsed.id);

    var line_idx: usize = 0;
    const lines = response.result.?[0].lines;
    while (line_idx < lines.len) : (line_idx += 1) {
        var span_idx: usize = 0;
        const spans = lines[line_idx];
        while (span_idx < spans.len) : (span_idx += 1) {
            try expectEqualSpans(spans[span_idx], parsed.result.?[0].lines[line_idx][span_idx]);
        }
    }

    try expectEqualFaces(response.result.?[1].face, parsed.result.?[1].face);
    try expectEqualFaces(response.result.?[2].face, parsed.result.?[2].face);
    parsed.free(testing.allocator);
}
