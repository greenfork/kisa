// Limitations:
// 1. No batch mode, contributions are welcome.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const testing = std.testing;

pub const jsonrpc_version = "2.0";
const default_parse_options = json.ParseOptions{
    .allocator = null,
    .duplicate_field_behavior = .Error,
    .ignore_unknown_fields = false,
    .allow_trailing_data = false,
};

pub const SimpleRequest = Request([]const Value);
pub const SimpleResponse = Response(Value, Value);

/// Primitive json value which can be represented as Zig value.
/// Includes all json values but "object". For objects one should construct a Zig struct.
pub const Value = union(enum) {
    Bool: bool,
    Integer: i64,
    Float: f64,
    String: []const u8,
    Array: []const Value,
};

pub const IdValue = union(enum) {
    Integer: i64,
    Float: f64,
    String: []const u8,
};

pub const RequestKind = enum { Request, RequestNoParams, Notification, NotificationNoParams };

/// The resulting structure which represents a "request" object as specified in json-rpc 2.0.
/// For notifications the `id` field is `null`.
pub fn Request(comptime ParamsShape: type) type {
    const error_message = "Only Struct or Slice is allowed, found '" ++ @typeName(ParamsShape) ++ "'";
    switch (@typeInfo(ParamsShape)) {
        .Struct => {},
        .Pointer => |info| {
            if (info.size != .Slice) @compileError(error_message);
        },
        else => @compileError(error_message),
    }

    return union(RequestKind) {
        Request: struct {
            jsonrpc: []const u8,
            method: []const u8,
            id: ?IdValue,
            params: ParamsShape,
        },
        RequestNoParams: struct {
            jsonrpc: []const u8,
            method: []const u8,
            id: ?IdValue,
        },
        Notification: struct {
            jsonrpc: []const u8,
            method: []const u8,
            params: ParamsShape,
        },
        NotificationNoParams: struct {
            jsonrpc: []const u8,
            method: []const u8,
        },

        const Self = @This();

        pub fn init(_id: ?IdValue, _method: []const u8, _params: ?ParamsShape) Self {
            if (_params) |p| {
                return Self{ .Request = .{
                    .jsonrpc = jsonrpc_version,
                    .id = _id,
                    .method = _method,
                    .params = p,
                } };
            } else {
                return Self{ .RequestNoParams = .{
                    .jsonrpc = jsonrpc_version,
                    .id = _id,
                    .method = _method,
                } };
            }
        }

        pub fn initNotification(_method: []const u8, _params: ?ParamsShape) Self {
            if (_params) |p| {
                return Self{ .Notification = .{
                    .jsonrpc = jsonrpc_version,
                    .method = _method,
                    .params = p,
                } };
            } else {
                return Self{ .NotificationNoParams = .{
                    .jsonrpc = jsonrpc_version,
                    .method = _method,
                } };
            }
        }

        /// Getter function for `jsonrpc`.
        pub fn jsonrpc(self: Self) []const u8 {
            return switch (self) {
                .Request => |s| s.jsonrpc,
                .RequestNoParams => |s| s.jsonrpc,
                .Notification => |s| s.jsonrpc,
                .NotificationNoParams => |s| s.jsonrpc,
            };
        }

        /// Getter function for `method`.
        pub fn method(self: Self) []const u8 {
            return switch (self) {
                .Request => |s| s.method,
                .RequestNoParams => |s| s.method,
                .Notification => |s| s.method,
                .NotificationNoParams => |s| s.method,
            };
        }

        // TODO: make unreachable
        /// Getter function for `id`.
        pub fn id(self: Self) ?IdValue {
            return switch (self) {
                .Request => |s| s.id,
                .RequestNoParams => |s| s.id,
                .Notification, .NotificationNoParams => null,
            };
        }

        /// Getter function for `params`.
        pub fn params(self: Self) ?ParamsShape {
            return switch (self) {
                .Request => |s| s.params,
                .Notification => |s| s.params,
                .RequestNoParams, .NotificationNoParams => null,
            };
        }

        /// Parses a string into specified `Request` structure. Requires `allocator` if
        /// any of the `Request` values are arrays/pointers/slices; pass `null` otherwise.
        /// Caller owns the memory, free it with `parseFree`.
        pub fn parseAlloc(allocator: *std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            const result = try json.parse(Self, &token_stream, parse_options);
            if (!mem.eql(u8, jsonrpc_version, result.jsonrpc())) return error.IncorrectJsonrpcVersion;
            return result;
        }

        pub fn parseFree(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }

        pub fn parse(buf: []u8, string: []const u8) !Self {
            var fba = std.heap.FixedBufferAllocator.init(buf);
            return try parseAlloc(&fba.allocator, string);
        }

        /// Caller owns the memory.
        pub fn generateAlloc(self: Self, allocator: *std.mem.Allocator) ![]u8 {
            var result = std.ArrayList(u8).init(allocator);
            try self.writeTo(result.writer());
            return result.toOwnedSlice();
        }

        pub fn generate(self: Self, buf: []u8) ![]u8 {
            var fba = std.heap.FixedBufferAllocator.init(buf);
            return try self.generateAlloc(&fba.allocator);
        }

        pub fn writeTo(self: Self, stream: anytype) !void {
            try json.stringify(self, .{}, stream);
        }

        /// Caller owns the memory.
        pub fn parseMethodAlloc(ally: *std.mem.Allocator, string: []const u8) ![]u8 {
            const RequestMethod = struct { method: []u8 };
            const parse_options = json.ParseOptions{
                .allocator = ally,
                .duplicate_field_behavior = .Error,
                .ignore_unknown_fields = true,
                .allow_trailing_data = false,
            };
            var token_stream = json.TokenStream.init(string);
            const parsed = try json.parse(RequestMethod, &token_stream, parse_options);
            return parsed.method;
        }

        pub fn parseMethod(buf: []u8, string: []const u8) ![]u8 {
            var fba = std.heap.FixedBufferAllocator.init(buf);
            var ally = &fba.allocator;
            return try parseMethodAlloc(ally, string);
        }
    };
}

pub const ResponseKind = enum { Result, Error };

/// The resulting structure which represents a "response" object as specified in json-rpc 2.0.
/// `Response` has either `null` value in `result` or in `error` field depending on the type.
pub fn Response(comptime ResultShape: type, comptime ErrorDataShape: type) type {
    return union(ResponseKind) {
        Result: struct {
            jsonrpc: []const u8,
            id: ?IdValue,
            result: ResultShape,
        },
        Error: struct {
            jsonrpc: []const u8,
            id: ?IdValue,
            @"error": ErrorObject,
        },

        const Self = @This();
        const ErrorObjectWithoutData = struct { code: i64, message: []const u8 };
        const ErrorObjectWithData = struct { code: i64, message: []const u8, data: ErrorDataShape };
        const ErrorObject = union(enum) {
            WithoutData: ErrorObjectWithoutData,
            WithData: ErrorObjectWithData,
        };

        pub fn initResult(_id: ?IdValue, _result: ResultShape) Self {
            return Self{ .Result = .{
                .jsonrpc = jsonrpc_version,
                .id = _id,
                .result = _result,
            } };
        }

        pub fn initError(_id: ?IdValue, _code: i64, _message: []const u8, _data: ?ErrorDataShape) Self {
            if (_data) |data| {
                return Self{ .Error = .{
                    .jsonrpc = jsonrpc_version,
                    .id = _id,
                    .@"error" = .{ .WithData = .{ .code = _code, .message = _message, .data = data } },
                } };
            } else {
                return Self{ .Error = .{
                    .jsonrpc = jsonrpc_version,
                    .id = _id,
                    .@"error" = .{ .WithoutData = .{ .code = _code, .message = _message } },
                } };
            }
        }

        /// Getter function for `jsonrpc`.
        pub fn jsonrpc(self: Self) []const u8 {
            return switch (self) {
                .Result => |s| s.jsonrpc,
                .Error => |s| s.jsonrpc,
            };
        }

        /// Getter function for `id`.
        pub fn id(self: Self) ?IdValue {
            return switch (self) {
                .Result => |s| s.id,
                .Error => |s| s.id,
            };
        }

        /// Getter function for `result`.
        pub fn result(self: Self) ResultShape {
            return switch (self) {
                .Result => |s| s.result,
                .Error => unreachable,
            };
        }

        /// Getter function for `error`.
        pub fn @"error"(self: Self) ErrorObject {
            return switch (self) {
                .Result => unreachable,
                .Error => |s| s.@"error",
            };
        }

        /// Getter function for `error.code`.
        pub fn errorCode(self: Self) i64 {
            return switch (self) {
                .Result => unreachable,
                .Error => |s| switch (s.@"error") {
                    .WithoutData => |e| e.code,
                    .WithData => |e| e.code,
                },
            };
        }

        /// Getter function for `error.message`.
        pub fn errorMessage(self: Self) []const u8 {
            return switch (self) {
                .Result => unreachable,
                .Error => |s| switch (s.@"error") {
                    .WithoutData => |e| e.message,
                    .WithData => |e| e.message,
                },
            };
        }

        /// Getter function for `error.data`.
        pub fn errorData(self: Self) ErrorDataShape {
            return switch (self) {
                .Result => unreachable,
                .Error => |s| switch (s.@"error") {
                    .WithoutData => unreachable,
                    .WithData => |e| e.data,
                },
            };
        }

        /// Parses a string into specified `Response` structure. Requires `allocator` if
        /// any of the `Response` values are arrays/pointers/slices; pass `null` otherwise.
        /// Caller owns the memory, free it with `parseFree`.
        pub fn parseAlloc(allocator: ?*std.mem.Allocator, string: []const u8) !Self {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            var token_stream = json.TokenStream.init(string);
            const rs = try json.parse(Self, &token_stream, parse_options);
            if (!mem.eql(u8, jsonrpc_version, rs.jsonrpc())) return error.IncorrectJsonrpcVersion;
            return rs;
        }

        pub fn parseFree(self: Self, allocator: *std.mem.Allocator) void {
            var parse_options = default_parse_options;
            parse_options.allocator = allocator;
            json.parseFree(Self, self, parse_options);
        }

        pub fn parse(buf: []u8, string: []const u8) !Self {
            var fba = std.heap.FixedBufferAllocator.init(buf);
            return try parseAlloc(&fba.allocator, string);
        }

        /// Caller owns the memory.
        pub fn generateAlloc(self: Self, allocator: *std.mem.Allocator) ![]u8 {
            var rs = std.ArrayList(u8).init(allocator);
            try self.writeTo(rs.writer());
            return rs.toOwnedSlice();
        }

        pub fn generate(self: Self, buf: []u8) ![]u8 {
            var fba = std.heap.FixedBufferAllocator.init(buf);
            return try self.generateAlloc(&fba.allocator);
        }

        pub fn writeTo(self: Self, stream: anytype) !void {
            try json.stringify(self, .{}, stream);
        }
    };
}

// ===========================================================================
// Testing
// ===========================================================================
//
// Note that "generate" tests depend on how Zig orders keys in the object type. In spec they have
// no order and for the actual use it also doesn't matter.

test "jsonrpc: parse alloc request" {
    const params = [_]Value{ .{ .String = "Bob" }, .{ .String = "Alice" }, .{ .Integer = 10 } };
    const request = SimpleRequest.init(IdValue{ .Integer = 63 }, "startParty", &params);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":63}
    ;
    const parsed = try SimpleRequest.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqual(RequestKind.Request, std.meta.activeTag(parsed));
    try testing.expectEqualStrings(request.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqualStrings(request.method(), parsed.method());
    try testing.expectEqualStrings(request.params().?[0].String, parsed.params().?[0].String);
    try testing.expectEqualStrings(request.params().?[1].String, parsed.params().?[1].String);
    try testing.expectEqual(request.params().?[2].Integer, parsed.params().?[2].Integer);
    try testing.expectEqual(request.id(), parsed.id());
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: parse request" {
    const params = [_]Value{ .{ .String = "Bob" }, .{ .String = "Alice" }, .{ .Integer = 10 } };
    const request = SimpleRequest.init(IdValue{ .Integer = 63 }, "startParty", &params);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":63}
    ;
    var buf: [4096]u8 = undefined;
    const parsed = try SimpleRequest.parse(&buf, jsonrpc_string);
    try testing.expectEqualStrings(request.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqualStrings(request.method(), parsed.method());
    try testing.expectEqualStrings(request.params().?[0].String, parsed.params().?[0].String);
    try testing.expectEqualStrings(request.params().?[1].String, parsed.params().?[1].String);
    try testing.expectEqual(request.params().?[2].Integer, parsed.params().?[2].Integer);
    try testing.expectEqual(request.id(), parsed.id());
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

test "jsonrpc: parse complex request" {
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
    const request = MyRequest.initNotification("draw", &params);
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
    const parsed = try MyRequest.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(request.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqualStrings(request.method(), parsed.method());
    try testing.expectEqual(request.id(), parsed.id());

    var line_idx: usize = 0;
    const lines = request.params().?[0].lines;
    while (line_idx < lines.len) : (line_idx += 1) {
        var span_idx: usize = 0;
        const spans = lines[line_idx];
        while (span_idx < spans.len) : (span_idx += 1) {
            try expectEqualSpans(spans[span_idx], parsed.params().?[0].lines[line_idx][span_idx]);
        }
    }

    try expectEqualFaces(request.params().?[1].face, parsed.params().?[1].face);
    try expectEqualFaces(request.params().?[2].face, parsed.params().?[2].face);
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: generate alloc request" {
    const params = [_]Value{ .{ .String = "Bob" }, .{ .String = "Alice" }, .{ .Integer = 10 } };
    const request = SimpleRequest.init(IdValue{ .Integer = 63 }, "startParty", &params);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","id":63,"params":["Bob","Alice",10]}
    ;
    const generated = try request.generateAlloc(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "jsonrpc: generate request" {
    const params = [_]Value{ .{ .String = "Bob" }, .{ .String = "Alice" }, .{ .Integer = 10 } };
    const request = SimpleRequest.init(IdValue{ .Integer = 63 }, "startParty", &params);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","id":63,"params":["Bob","Alice",10]}
    ;
    var buf: [256]u8 = undefined;
    const generated = try request.generate(&buf);
    try testing.expectEqualStrings(jsonrpc_string, generated);
}

test "jsonrpc: generate notification without ID" {
    const params = [_]Value{ .{ .String = "Bob" }, .{ .String = "Alice" }, .{ .Integer = 10 } };
    const request = SimpleRequest.initNotification("startParty", &params);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10]}
    ;
    const generated = try request.generateAlloc(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "jsonrpc: generate complex request" {
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
    const request = MyRequest.init(IdValue{ .Integer = 87 }, "draw", &params);
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
    const generated = try request.generateAlloc(testing.allocator);
    const stripped_jsonrpc_string = try removeSpaces(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(stripped_jsonrpc_string, generated);
    testing.allocator.free(generated);
    testing.allocator.free(stripped_jsonrpc_string);
}

test "jsonrpc: parse alloc success response" {
    const data = Value{ .Integer = 42 };
    const response = SimpleResponse.initResult(IdValue{ .Integer = 63 }, data);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","result":42,"id":63}
    ;
    const parsed = try SimpleResponse.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.result().Integer, parsed.result().Integer);
    try testing.expectEqual(response.id(), parsed.id());
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: parse buf success response" {
    const data = Value{ .Integer = 42 };
    const response = SimpleResponse.initResult(IdValue{ .Integer = 63 }, data);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","result":42,"id":63}
    ;
    var buf: [4096]u8 = undefined;
    const parsed = try SimpleResponse.parse(&buf, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.result().Integer, parsed.result().Integer);
    try testing.expectEqual(response.id(), parsed.id());
}

test "jsonrpc: parse error response" {
    const response = SimpleResponse.initError(IdValue{ .Integer = 63 }, 13, "error message", null);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","error":{"code":13,"message":"error message"},"id":63}
    ;
    const parsed = try SimpleResponse.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.errorCode(), parsed.errorCode());
    try testing.expectEqualStrings(response.errorMessage(), parsed.errorMessage());
    try testing.expectEqual(response.id(), parsed.id());
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: parse error response with data" {
    const response = SimpleResponse.initError(
        IdValue{ .Integer = 63 },
        13,
        "error message",
        Value{ .String = "additional info" },
    );
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"error":{"code":13,"message":"error message","data":"additional info"}}
    ;
    const parsed = try SimpleResponse.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.errorCode(), parsed.errorCode());
    try testing.expectEqualStrings(response.errorMessage(), parsed.errorMessage());
    try testing.expectEqual(response.id(), parsed.id());
    try testing.expectEqualStrings(response.errorData().String, parsed.errorData().String);
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: parse array response" {
    const data = [_]Value{ .{ .Integer = 42 }, .{ .String = "The Answer" } };
    const array_data = .{ .Array = std.mem.span(&data) };
    const response = SimpleResponse.initResult(IdValue{ .Integer = 63 }, array_data);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","result":[42,"The Answer"],"id":63}
    ;
    const parsed = try SimpleResponse.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.result().Array[0].Integer, parsed.result().Array[0].Integer);
    try testing.expectEqualStrings(response.result().Array[1].String, parsed.result().Array[1].String);
    try testing.expectEqual(response.id(), parsed.id());
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: parse complex response" {
    const reverse_attr = [_][]const u8{"reverse"};
    const final_attr = [_][]const u8{ "final_fg", "final_bg" };
    const Parameter = union(enum) {
        lines: []const []const Span,
        face: Face,
    };
    const ResultShape = []const Parameter;
    const MyResponse = Response(ResultShape, Value);

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
    const response = MyResponse.initResult(IdValue{ .Integer = 98 }, params_array);
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
    const parsed = try MyResponse.parseAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(response.jsonrpc(), parsed.jsonrpc());
    try testing.expectEqual(response.id(), parsed.id());

    var line_idx: usize = 0;
    const lines = response.result()[0].lines;
    while (line_idx < lines.len) : (line_idx += 1) {
        var span_idx: usize = 0;
        const spans = lines[line_idx];
        while (span_idx < spans.len) : (span_idx += 1) {
            try expectEqualSpans(spans[span_idx], parsed.result()[0].lines[line_idx][span_idx]);
        }
    }

    try expectEqualFaces(response.result()[1].face, parsed.result()[1].face);
    try expectEqualFaces(response.result()[2].face, parsed.result()[2].face);
    parsed.parseFree(testing.allocator);
}

test "jsonrpc: generate alloc success response" {
    const data = Value{ .Integer = 42 };
    const response = SimpleResponse.initResult(IdValue{ .Integer = 63 }, data);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"result":42}
    ;
    const generated = try response.generateAlloc(testing.allocator);
    try testing.expectEqualStrings(jsonrpc_string, generated);
    testing.allocator.free(generated);
}

test "jsonrpc: generate success response" {
    const data = Value{ .Integer = 42 };
    const response = SimpleResponse.initResult(IdValue{ .Integer = 63 }, data);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"result":42}
    ;
    var buf: [256]u8 = undefined;
    const generated = try response.generate(&buf);
    try testing.expectEqualStrings(jsonrpc_string, generated);
}

test "jsonrpc: generate error response" {
    const response = SimpleResponse.initError(IdValue{ .Integer = 63 }, 13, "error message", null);
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"error":{"code":13,"message":"error message"}}
    ;
    const generated = try response.generateAlloc(testing.allocator);
    defer testing.allocator.free(generated);
    try testing.expectEqualStrings(jsonrpc_string, generated);
}

test "jsonrpc: generate error response with data" {
    const response = SimpleResponse.initError(
        IdValue{ .Integer = 63 },
        13,
        "error message",
        Value{ .String = "additional data" },
    );
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","id":63,"error":{"code":13,"message":"error message","data":"additional data"}}
    ;
    const generated = try response.generateAlloc(testing.allocator);
    defer testing.allocator.free(generated);
    try testing.expectEqualStrings(jsonrpc_string, generated);
}

test "jsonrpc: generate complex response" {
    const reverse_attr = [_][]const u8{"reverse"};
    const final_attr = [_][]const u8{ "final_fg", "final_bg" };
    const Parameter = union(enum) {
        lines: []const []const Span,
        face: Face,
    };
    const ResultShape = []const Parameter;
    const MyResponse = Response(ResultShape, Value);

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
    const response = MyResponse.initResult(IdValue{ .Integer = 98 }, params_array);
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
    const generated = try response.generateAlloc(testing.allocator);
    const stripped_jsonrpc_string = try removeSpaces(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings(stripped_jsonrpc_string, generated);
    testing.allocator.free(generated);
    testing.allocator.free(stripped_jsonrpc_string);
}

test "jsonrpc: parse request and only return a method" {
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":63}
    ;
    const method = try SimpleRequest.parseMethodAlloc(testing.allocator, jsonrpc_string);
    try testing.expectEqualStrings("startParty", method);
    testing.allocator.free(method);
}

test "jsonrpc: parse request and only return a method" {
    const jsonrpc_string =
        \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":63}
    ;
    var buf: [32]u8 = undefined;
    const method = try SimpleRequest.parseMethod(&buf, jsonrpc_string);
    try testing.expectEqualStrings("startParty", method);
}

test "jsonrpc: must return an error if jsonrpc has missing field" {
    var buf: [512]u8 = undefined;

    {
        const jsonrpc_string =
            \\{"method":"startParty","params":["Bob","Alice",10],"id":63}
        ;
        try testing.expectError(error.NoUnionMembersMatched, SimpleRequest.parse(&buf, jsonrpc_string));
    }
    {
        const jsonrpc_string =
            \\{"id":63,"result":42}
        ;
        try testing.expectError(error.NoUnionMembersMatched, SimpleResponse.parse(&buf, jsonrpc_string));
    }
}

test "jsonrpc: must return an error if jsonrpc has incorrect version" {
    var buf: [512]u8 = undefined;

    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.1","method":"startParty","params":["Bob","Alice",10],"id":63}
        ;
        try testing.expectError(error.IncorrectJsonrpcVersion, SimpleRequest.parse(&buf, jsonrpc_string));
    }
    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.1","id":63,"result":42}
        ;
        try testing.expectError(error.IncorrectJsonrpcVersion, SimpleResponse.parse(&buf, jsonrpc_string));
    }
}

test "jsonrpc: parse null id values" {
    var buf: [256]u8 = undefined;

    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.0","method":"startParty","params":["Bob","Alice",10],"id":null}
        ;
        const request = try SimpleRequest.parse(&buf, jsonrpc_string);
        try testing.expectEqual(@as(?IdValue, null), request.id());
    }
    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.0","id":null,"result":42}
        ;
        const response = try SimpleResponse.parse(&buf, jsonrpc_string);
        try testing.expectEqual(@as(?IdValue, null), response.id());
    }
}

test "jsonrpc: parse requests without params" {
    var buf: [256]u8 = undefined;

    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.0","method":"startParty","id":"uid250"}
        ;
        const request = try SimpleRequest.parse(&buf, jsonrpc_string);
        try testing.expectEqual(RequestKind.RequestNoParams, std.meta.activeTag(request));
    }

    {
        const jsonrpc_string =
            \\{"jsonrpc":"2.0","method":"startParty"}
        ;
        const request = try SimpleRequest.parse(&buf, jsonrpc_string);
        try testing.expectEqual(RequestKind.NotificationNoParams, std.meta.activeTag(request));
    }
}
