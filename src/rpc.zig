//! Messages which are used by Client and Server to communicate via `transport` module.
const std = @import("std");
const meta = std.meta;
const testing = std.testing;
const assert = std.debug.assert;
const jsonrpc = @import("jsonrpc.zig");
const kisa = @import("kisa");
const Keys = @import("main.zig").Keys;

const RpcKind = enum { jsonrpc };
const rpcImplementation = RpcKind.jsonrpc;

pub fn Request(comptime ParamsShape: type) type {
    return RequestType(rpcImplementation, ParamsShape);
}
pub fn Response(comptime ResultShape: type) type {
    return ResponseType(rpcImplementation, ResultShape);
}

pub const EmptyResponse = Response(bool);
pub const EmptyRequest = Request([]bool);
pub const KeypressRequest = jsonrpc.Request(Keys.Key);

pub fn ackResponse(id: ?u32) EmptyResponse {
    return EmptyResponse.initSuccess(id, true);
}
pub const ResponseError = error{
    AccessDenied,
    BadPathName,
    DeviceBusy,
    EmptyPacket,
    FileNotFound,
    FileTooBig,
    InputOutput,
    InvalidParams,
    InvalidRequest,
    InvalidUtf8,
    IsDir,
    MethodNotFound,
    NameTooLong,
    NoDevice,
    NoSpaceLeft,
    NotOpenForReading,
    NullIdInRequest,
    OperationAborted,
    ParseError,
    ProcessFdQuotaExceeded,
    SharingViolation,
    SymLinkLoop,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
    UninitializedClient,
};
pub fn errorResponse(id: ?u32, err: ResponseError) EmptyResponse {
    switch (err) {
        // JSON-RPC 2.0 errors
        error.EmptyPacket => return EmptyResponse.initError(id, -32700, "Parse error: empty packet"),
        error.InvalidRequest => return EmptyResponse.initError(id, -32600, "Invalid request"),
        error.NullIdInRequest => return EmptyResponse.initError(id, -32600, "Invalid request: Id can't be null"),
        error.ParseError => return EmptyResponse.initError(id, -32700, "Parse error"),
        error.MethodNotFound => return EmptyResponse.initError(id, -32601, "Method not found"),
        error.InvalidParams => return EmptyResponse.initError(id, -32602, "Invalid params"),

        // Unix-style issues
        error.AccessDenied => return EmptyResponse.initError(id, 13, "Permission denied"),
        error.SharingViolation => return EmptyResponse.initError(id, 37, "Sharing violation"),
        error.SymLinkLoop => return EmptyResponse.initError(id, 40, "Too many levels of symbolic links"),
        error.ProcessFdQuotaExceeded => return EmptyResponse.initError(id, 24, "Too many open files"),
        error.SystemFdQuotaExceeded => return EmptyResponse.initError(id, 23, "Too many open files in system"),
        error.FileNotFound => return EmptyResponse.initError(id, 2, "No such file or directory"),
        error.SystemResources => return EmptyResponse.initError(id, 104, "Connection reset by peer"),
        error.NameTooLong => return EmptyResponse.initError(id, 36, "File name too long"),
        error.NoDevice => return EmptyResponse.initError(id, 19, "No such device"),
        error.DeviceBusy => return EmptyResponse.initError(id, 16, "Device or resource busy"),
        error.FileTooBig => return EmptyResponse.initError(id, 27, "File too large"),
        error.NoSpaceLeft => return EmptyResponse.initError(id, 28, "No space left on device"),
        error.IsDir => return EmptyResponse.initError(id, 21, "Is a directory"),
        error.NotOpenForReading => return EmptyResponse.initError(id, 77, "File descriptor in bad state, not open for reading"),
        error.InputOutput => return EmptyResponse.initError(id, 5, "Input/output error"),

        // Other OS-specific issues
        error.BadPathName => return EmptyResponse.initError(id, 1001, "On Windows, file paths cannot contain these characters: '/', '*', '?', '\"', '<', '>', '|'"),
        error.InvalidUtf8 => return EmptyResponse.initError(id, 1002, "On Windows, file paths must be valid Unicode."),
        error.OperationAborted => return EmptyResponse.initError(id, 1003, "Operation aborted"),
        error.Unexpected => return EmptyResponse.initError(id, 999, "Unexpected error, language-level bug"),

        // Application errors
        error.UninitializedClient => return EmptyResponse.initError(id, 2001, "Client is not initialized"),
    }
    unreachable;
}

pub fn request(
    comptime ParamsShape: type,
    id: ?u32,
    method: []const u8,
    params: ?ParamsShape,
) Request(ParamsShape) {
    return Request(ParamsShape).init(id, method, params);
}

pub fn commandRequest(
    comptime command_kind: kisa.CommandKind,
    id: ?u32,
    params: meta.TagPayload(kisa.Command, command_kind),
) Request(meta.TagPayload(kisa.Command, command_kind)) {
    return request(
        meta.TagPayload(kisa.Command, command_kind),
        id,
        comptime meta.tagName(command_kind),
        params,
    );
}

pub fn emptyCommandRequest(comptime command_kind: kisa.CommandKind, id: ?u32) EmptyRequest {
    return EmptyRequest.init(id, comptime meta.tagName(command_kind), null);
}

pub fn emptyNotification(
    method: []const u8,
) Request([]bool) {
    return Request([]bool).init(null, method, null);
}

pub fn response(
    comptime ResultShape: type,
    id: ?u32,
    result: ResultShape,
) Response(ResultShape) {
    return Response(ResultShape).initSuccess(id, result);
}

pub fn parseRequest(
    comptime ParamsShape: type,
    buf: []u8,
    string: []const u8,
) !Request(ParamsShape) {
    return try Request(ParamsShape).parse(buf, string);
}

pub fn parseResponse(
    comptime ResultShape: type,
    buf: []u8,
    string: []const u8,
) !Response(ResultShape) {
    return try Response(ResultShape).parse(buf, string);
}

pub fn parseCommandFromRequest(
    comptime command_kind: kisa.CommandKind,
    buf: []u8,
    string: []const u8,
) !kisa.Command {
    const Payload = meta.TagPayload(kisa.Command, command_kind);
    switch (@typeInfo(Payload)) {
        .Void => {
            _ = EmptyRequest.parse(buf, string) catch return error.InvalidRequest;
            return @unionInit(kisa.Command, comptime meta.tagName(command_kind), {});
        },
        else => {
            const req = Request(Payload).parse(buf, string) catch |err| switch (err) {
                error.MissingField => return error.InvalidParams,
                else => return error.InvalidRequest,
            };
            return @unionInit(kisa.Command, comptime meta.tagName(command_kind), req.params.?);
        },
    }
}

pub fn parseId(string: []const u8) !?u32 {
    switch (rpcImplementation) {
        .jsonrpc => {
            const id_value = jsonrpc.parseId(null, string) catch |err| switch (err) {
                error.MissingField => return error.MissingField,
                else => return error.ParseError,
            };
            if (id_value) |id| {
                return @intCast(u32, id.Integer);
            } else {
                return null;
            }
        },
    }
    unreachable;
}

pub fn parseMethod(buf: []u8, string: []const u8) ![]u8 {
    switch (rpcImplementation) {
        .jsonrpc => {
            return jsonrpc.parseMethod(buf, string) catch |err| switch (err) {
                error.MissingField => return error.MethodNotFound,
                else => return error.ParseError,
            };
        },
    }
}

fn RequestType(comptime kind: RpcKind, comptime ParamsShape: type) type {
    return struct {
        /// Identification of a message, when ID is `null`, it means there's no response expected.
        id: ?u32,
        /// Name of a remote procedure.
        method: []const u8,
        /// Parameters to the `method`.
        params: ?ParamsShape,

        const Self = @This();
        const RequestImpl = switch (kind) {
            .jsonrpc => jsonrpc.Request(ParamsShape),
        };

        pub fn init(id: ?u32, method: []const u8, params: ?ParamsShape) Self {
            return Self{ .id = id, .method = method, .params = params };
        }

        /// Turns message into string representation.
        pub fn generate(self: Self, buf: []u8) ![]u8 {
            switch (kind) {
                .jsonrpc => {
                    const message = blk: {
                        if (self.id) |id| {
                            break :blk RequestImpl.init(
                                jsonrpc.IdValue{ .Integer = id },
                                self.method,
                                self.params,
                            );
                        } else {
                            break :blk RequestImpl.initNotification(self.method, self.params);
                        }
                    };
                    return try message.generate(buf);
                },
            }
            unreachable;
        }

        pub fn parse(buf: []u8, string: []const u8) !Self {
            switch (kind) {
                .jsonrpc => {
                    const jsonrpc_message = try RequestImpl.parse(buf, string);
                    switch (jsonrpc_message) {
                        .Request => |s| {
                            return Self{
                                .id = @intCast(u32, s.id.?.Integer),
                                .method = s.method,
                                .params = s.params,
                            };
                        },
                        .RequestNoParams => |s| {
                            return Self{
                                .id = @intCast(u32, s.id.?.Integer),
                                .method = s.method,
                                .params = null,
                            };
                        },
                        .Notification => |s| {
                            return Self{
                                .id = null,
                                .method = s.method,
                                .params = s.params,
                            };
                        },
                        .NotificationNoParams => |s| {
                            return Self{
                                .id = null,
                                .method = s.method,
                                .params = null,
                            };
                        },
                    }
                },
            }
            unreachable;
        }
    };
}

fn ResponseType(comptime kind: RpcKind, comptime ResultShape: type) type {
    return union(enum) {
        Success: struct {
            /// Identification of a message, must be same as the ID of the request.
            /// When ID is `null`, it means there's specific request to respond to.
            id: ?u32,
            /// Result of a request, by convention when nothing is needed it is `true`.
            result: ResultShape,
        },
        Error: struct {
            /// Identification of a message, must be same as the ID of the request.
            /// When ID is `null`, it means there's specific request to respond to.
            id: ?u32,
            /// Error code, a mix of Linux-specific codes and HTTP error codes.
            code: i64,
            /// Error message describing the error code.
            message: []const u8,
        },

        const Self = @This();
        const ResponseImpl = switch (kind) {
            .jsonrpc => jsonrpc.Response(ResultShape, bool),
        };

        pub fn initSuccess(id: ?u32, result: ResultShape) Self {
            return Self{ .Success = .{ .id = id, .result = result } };
        }

        pub fn initError(id: ?u32, code: i32, message: []const u8) Self {
            return Self{ .Error = .{ .id = id, .code = code, .message = message } };
        }

        /// Turns message into string representation.
        pub fn generate(self: Self, buf: []u8) ![]u8 {
            switch (kind) {
                .jsonrpc => {
                    const message = blk: {
                        switch (self) {
                            .Success => |s| {
                                if (s.id) |id| {
                                    break :blk ResponseImpl.initResult(
                                        jsonrpc.IdValue{ .Integer = id },
                                        s.result,
                                    );
                                } else {
                                    break :blk ResponseImpl.initResult(
                                        null,
                                        s.result,
                                    );
                                }
                            },
                            .Error => |e| {
                                if (e.id) |id| {
                                    break :blk ResponseImpl.initError(
                                        jsonrpc.IdValue{ .Integer = id },
                                        e.code,
                                        e.message,
                                        null,
                                    );
                                } else {
                                    break :blk ResponseImpl.initError(
                                        null,
                                        e.code,
                                        e.message,
                                        null,
                                    );
                                }
                            },
                        }
                    };
                    return try message.generate(buf);
                },
            }
            unreachable;
        }

        pub fn parse(buf: []u8, string: []const u8) !Self {
            switch (kind) {
                .jsonrpc => {
                    const jsonrpc_message = try ResponseImpl.parse(buf, string);
                    switch (jsonrpc_message) {
                        .Result => |r| {
                            if (r.id) |id| {
                                return Self{ .Success = .{
                                    .id = @intCast(u32, id.Integer),
                                    .result = r.result,
                                } };
                            } else {
                                return Self{ .Success = .{
                                    .id = null,
                                    .result = r.result,
                                } };
                            }
                        },
                        .Error => |e| {
                            if (e.id) |id| {
                                return Self{ .Error = .{
                                    .id = @intCast(u32, id.Integer),
                                    .code = jsonrpc_message.errorCode(),
                                    .message = jsonrpc_message.errorMessage(),
                                } };
                            } else {
                                return Self{ .Error = .{
                                    .id = null,
                                    .code = jsonrpc_message.errorCode(),
                                    .message = jsonrpc_message.errorMessage(),
                                } };
                            }
                        },
                    }
                },
            }
            unreachable;
        }
    };
}

const MyRequest = RequestType(.jsonrpc, []const u32);
const Person = struct { name: []const u8, age: u32 };
const PersonRequest = RequestType(.jsonrpc, Person);
const MyResponse = ResponseType(.jsonrpc, []const u32);
const PersonResponse = ResponseType(.jsonrpc, Person);

fn testMyRequest(want: MyRequest, message: MyRequest) !void {
    try testing.expectEqual(want.id, message.id);
    try testing.expectEqualStrings(want.method, message.method);
    if (want.params) |params| {
        try testing.expectEqual(params.len, message.params.?.len);
        try testing.expectEqual(params[0], message.params.?[0]);
    } else {
        try testing.expectEqual(@as(?[]const u32, null), message.params);
    }
}

fn testPersonRequest(want: PersonRequest, message: PersonRequest) !void {
    try testing.expectEqual(want.id, message.id);
    try testing.expectEqualStrings(want.method, message.method);
    try testing.expectEqualStrings(want.params.?.name, message.params.?.name);
    try testing.expectEqual(want.params.?.age, message.params.?.age);
}

fn testMyResponse(want: MyResponse, message: MyResponse) !void {
    switch (want) {
        .Success => |s| {
            try testing.expectEqual(s.id, message.Success.id);
            try testing.expectEqual(s.result.len, message.Success.result.len);
            try testing.expectEqual(s.result[0], message.Success.result[0]);
        },
        .Error => |e| {
            try testing.expectEqual(e.id, message.Error.id);
            try testing.expectEqual(e.code, message.Error.code);
            try testing.expectEqualStrings(e.message, message.Error.message);
        },
    }
}

fn testPersonResponse(want: PersonResponse, message: PersonResponse) !void {
    switch (want) {
        .Success => |s| {
            try testing.expectEqual(s.id, message.Success.id);
            try testing.expectEqualStrings(s.result.name, message.Success.result.name);
            try testing.expectEqual(s.result.age, message.Success.result.age);
        },
        .Error => |e| {
            try testing.expectEqual(e.id, message.Error.id);
            try testing.expectEqual(e.code, message.Error.code);
            try testing.expectEqualStrings(e.message, message.Error.message);
        },
    }
}

test "myrpc: jsonrpc generates and parses a request string" {
    var generate_buf: [256]u8 = undefined;
    var parse_buf: [256]u8 = undefined;
    {
        const message = MyRequest.init(1, "startParty", &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","method":"startParty","id":1,"params":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyRequest.parse(&parse_buf, want);
        try testMyRequest(message, parsed);
    }
    {
        const message = MyRequest.init(null, "startParty", &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","method":"startParty","params":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyRequest.parse(&parse_buf, want);
        try testMyRequest(message, parsed);
    }
    {
        const message = MyRequest.init(null, "startParty", null);
        const want =
            \\{"jsonrpc":"2.0","method":"startParty"}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyRequest.parse(&parse_buf, want);
        try testMyRequest(message, parsed);
    }
    {
        const message = MyRequest.init(1, "startParty", null);
        const want =
            \\{"jsonrpc":"2.0","method":"startParty","id":1}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyRequest.parse(&parse_buf, want);
        try testMyRequest(message, parsed);
    }
    {
        const message = PersonRequest.init(null, "startParty", Person{ .name = "Bob", .age = 37 });
        const want =
            \\{"jsonrpc":"2.0","method":"startParty","params":{"name":"Bob","age":37}}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try PersonRequest.parse(&parse_buf, want);
        try testPersonRequest(message, parsed);
    }
    {
        const message = request([]const u32, 1, "startParty", &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","method":"startParty","id":1,"params":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try parseRequest([]const u32, &parse_buf, want);
        try testMyRequest(message, parsed);
    }
}

test "myrpc: jsonrpc generates and parses a response string" {
    var generate_buf: [256]u8 = undefined;
    var parse_buf: [256]u8 = undefined;
    {
        const message = MyResponse.initSuccess(1, &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","id":1,"result":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyResponse.parse(&parse_buf, want);
        try testMyResponse(message, parsed);
    }
    {
        const message = MyResponse.initSuccess(null, &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","id":null,"result":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyResponse.parse(&parse_buf, want);
        try testMyResponse(message, parsed);
    }
    {
        const message = PersonResponse.initSuccess(1, Person{ .name = "Bob", .age = 37 });
        const want =
            \\{"jsonrpc":"2.0","id":1,"result":{"name":"Bob","age":37}}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try PersonResponse.parse(&parse_buf, want);
        try testPersonResponse(message, parsed);
    }
    {
        const message = MyResponse.initError(1, 2, "ENOENT");
        const want =
            \\{"jsonrpc":"2.0","id":1,"error":{"code":2,"message":"ENOENT"}}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyResponse.parse(&parse_buf, want);
        try testMyResponse(message, parsed);
    }
    {
        const message = MyResponse.initError(null, 2, "ENOENT");
        const want =
            \\{"jsonrpc":"2.0","id":null,"error":{"code":2,"message":"ENOENT"}}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try MyResponse.parse(&parse_buf, want);
        try testMyResponse(message, parsed);
    }
    {
        const message = response([]const u32, 1, &[_]u32{18});
        const want =
            \\{"jsonrpc":"2.0","id":1,"result":[18]}
        ;
        try testing.expectEqualStrings(want, try message.generate(&generate_buf));
        const parsed = try parseResponse([]const u32, &parse_buf, want);
        try testMyResponse(message, parsed);
    }
}
