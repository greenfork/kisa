// Limitations:
// 1. No batch mode, contributions are welcome.
// 2. ID value for requests can't be `null`, it becomes a notification with absent "id" field
//    in the resulting json. Specification discourages the use of `null` for IDs, hopefully
//    this will never be a use case. This limitation is partly due to standard library json
//    parser being unable to parse into unions with `void` values.
//
//    Another solution to this problem would be to return a "subtype" from `parse` but
//    it complicates things for the user of this library since it will require to switch
//    on the type of the returned value instead of just checking for nulls in fields in
//    order to determine the object type.

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

/// The resulting structure which represents a "request" object as specified in json-rpc 2.0.
/// For notifications the `id` field is `null`.
pub fn Request(comptime ParamsShape: type) type {
    return struct {
        jsonrpc: []const u8,
        method: []const u8,
        id: ?i64 = null,
        params: ParamsShape,

        const RequestSubtype = struct {
            jsonrpc: []const u8,
            method: []const u8,
            id: i64,
            params: ParamsShape,
        };
        const NotificationSubtype = struct {
            jsonrpc: []const u8,
            method: []const u8,
            params: ParamsShape,
        };

        const Self = @This();

        /// Parses a string into specified `Request` structure. Requires `allocator` if
        /// any of the `Request` values are arrays/pointers/slices; pass `null` otherwise.
        /// Caller owns the memory, free it with `parseFree`.
        pub fn parse(allocator: *std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            return try json.parse(Self, &token_stream, parse_options);
        }

        pub fn parseFree(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }

        /// Caller owns the memory.
        pub fn generate(self: Self, allocator: *std.mem.Allocator) ![]u8 {
            var result = std.ArrayList(u8).init(allocator);
            try json.stringify(self, .{}, result.writer());
            return result.toOwnedSlice();
        }

        pub fn jsonStringify(
            self: Self,
            options: json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            if (self.id == null) {
                try json.stringify(NotificationSubtype{
                    .jsonrpc = self.jsonrpc,
                    .method = self.method,
                    .params = self.params,
                }, options, out_stream);
            } else {
                try json.stringify(RequestSubtype{
                    .jsonrpc = self.jsonrpc,
                    .method = self.method,
                    .params = self.params,
                    .id = self.id.?,
                }, options, out_stream);
            }
        }
    };
}

pub const SimpleRequest = Request(Value);

// TODO: add `data` field.
pub const ResponseErrorImpl = struct { code: i64, message: []const u8 };

/// The resulting structure which represents a "response" object as specified in json-rpc 2.0.
/// `Response` has either `null` value in `result` or in `error` field depending on the type.
pub fn Response(comptime ResultShape: type) type {
    return struct {
        jsonrpc: []const u8,
        id: ?i64,
        result: ?ResultShape = null,
        @"error": ?ResponseErrorImpl = null,

        const ResultSubtype = struct {
            jsonrpc: []const u8,
            id: i64,
            result: ?ResultShape,
        };
        const ErrorSubtype = struct {
            jsonrpc: []const u8,
            id: ?i64,
            @"error": ResponseErrorImpl,
        };

        const Self = @This();

        /// Parses a string into specified `Response` structure. Requires `allocator` if
        /// any of the `Response` values are arrays/pointers/slices; pass `null` otherwise.
        /// Caller owns the memory, free it with `parseFree`.
        pub fn parse(allocator: ?*std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            return try json.parse(Self, &token_stream, parse_options);
        }

        pub fn parseFree(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }

        /// Caller owns the memory.
        pub fn generate(self: Self, allocator: *std.mem.Allocator) ![]u8 {
            var result = std.ArrayList(u8).init(allocator);
            try json.stringify(self, .{}, result.writer());
            return result.toOwnedSlice();
        }

        pub fn jsonStringify(
            self: Self,
            options: json.StringifyOptions,
            out_stream: anytype,
        ) @TypeOf(out_stream).Error!void {
            if (self.result == null) {
                try json.stringify(ErrorSubtype{
                    .jsonrpc = self.jsonrpc,
                    .id = self.id,
                    .@"error" = self.@"error".?,
                }, options, out_stream);
            } else {
                try json.stringify(ResultSubtype{
                    .jsonrpc = self.jsonrpc,
                    .id = self.id.?,
                    .result = self.result,
                }, options, out_stream);
            }
        }
    };
}

pub const SimpleResponse = Response(Value);

// ===========================================================================
// Testing
// ===========================================================================
//
// Note that "generate" tests depend on how Zig orders keys in the object type. In spec they have
// no order and for the actual use it also doesn't matter.

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
    parsed.parseFree(testing.allocator);
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

fn removeSpaces(allocator: *std.mem.Allocator, str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var inside_string = false;
    for (str) |ch| {
        switch (ch) {
            '"' => {
                if (inside_string) {
                    inside_string = false;
                } else {
                    inside_string = true;
                }
                try result.append(ch);
            },
            ' ', '\n' => {
                if (inside_string) try result.append(ch);
            },
            else => try result.append(ch),
        }
    }
    return result.items;
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
    parsed.parseFree(testing.allocator);
}

test "generate request" {
    const params = [_]Value{ .{ .string = "Bob" }, .{ .string = "Alice" }, .{ .integer = 10 } };
    const params_array = .{ .array = std.mem.span(&params) };
    const request = SimpleRequest{
        .jsonrpc = jsonrpc_version,
        .method = "startParty",
        .params = params_array,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","id":63,"params":["Bob","Alice",10]}
    ;
    const generated = try request.generate(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "generate notification without ID" {
    const params = [_]Value{ .{ .string = "Bob" }, .{ .string = "Alice" }, .{ .integer = 10 } };
    const params_array = .{ .array = std.mem.span(&params) };
    const request = SimpleRequest{
        .jsonrpc = jsonrpc_version,
        .method = "startParty",
        .params = params_array,
        .id = null,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10]}
    ;
    const generated = try request.generate(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "generate complex request" {
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
        .id = 87,
    };
    // Taken from Kakoune editor and modified.
    const jsonrpc_string =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "draw",
        \\  "id": 87,
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
    const generated = try request.generate(testing.allocator);
    const stripped_jsonrpc_string = try removeSpaces(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(stripped_jsonrpc_string, generated);
    testing.allocator.free(generated);
    testing.allocator.free(stripped_jsonrpc_string);
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
    parsed.parseFree(testing.allocator);
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
    parsed.parseFree(testing.allocator);
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
    parsed.parseFree(testing.allocator);
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
    parsed.parseFree(testing.allocator);
}

test "generate success response" {
    const data = Value{ .integer = 42 };
    const response = SimpleResponse{
        .jsonrpc = jsonrpc_version,
        .result = data,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"result":42}
    ;
    const generated = try response.generate(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "generate error response" {
    const data = ResponseErrorImpl{ .code = 13, .message = "error message" };
    const response = SimpleResponse{
        .jsonrpc = jsonrpc_version,
        .@"error" = data,
        .id = 63,
    };
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"error":{"code":13,"message":"error message"}}
    ;
    const generated = try response.generate(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "generate complex response" {
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
    const generated = try response.generate(testing.allocator);
    const stripped_jsonrpc_string = try removeSpaces(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(stripped_jsonrpc_string, generated);
    testing.allocator.free(generated);
    testing.allocator.free(stripped_jsonrpc_string);
}
