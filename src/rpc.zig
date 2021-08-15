//! Messages which are used by Client and Server to communicate via `transport` module.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const jsonrpc = @import("jsonrpc.zig");
const kisa = @import("kisa");

pub const EmptyResponse = ResponseType(rpcImplementation, bool);
pub const EmptyRequest = RequestType(rpcImplementation, []bool);
pub const DrawDataResponse = ResponseType(rpcImplementation, kisa.DrawData);
pub const InitClientRequest = RequestType(rpcImplementation, kisa.ClientInitParams);

pub fn ackResponse(id: ?u32) EmptyResponse {
    return EmptyResponse.initSuccess(id, true);
}
pub const ResponseError = error{
    AccessDenied,
};
pub fn errorResponse(id: ?u32, err: ResponseError) EmptyResponse {
    switch (err) {
        error.AccessDenied => return EmptyResponse.initError(id, 13, "Permission denied"),
    }
    unreachable;
}

pub fn request(
    comptime ParamsShape: type,
    id: ?u32,
    method: []const u8,
    params: ?ParamsShape,
) RequestType(rpcImplementation, ParamsShape) {
    return RequestType(rpcImplementation, ParamsShape).init(id, method, params);
}

pub fn response(
    comptime ResultShape: type,
    id: ?u32,
    result: ResultShape,
) ResponseType(rpcImplementation, ResultShape) {
    return ResponseType(rpcImplementation, ResultShape).initSuccess(id, result);
}

pub fn parseRequest(
    comptime ParamsShape: type,
    buf: []u8,
    string: []const u8,
) !RequestType(rpcImplementation, ParamsShape) {
    return try RequestType(rpcImplementation, ParamsShape).parse(buf, string);
}

pub fn parseResponse(
    comptime ResultShape: type,
    buf: []u8,
    string: []const u8,
) !ResponseType(rpcImplementation, ResultShape) {
    return try ResponseType(rpcImplementation, ResultShape).parse(buf, string);
}

pub fn parseId(string: []const u8) !?u32 {
    switch (rpcImplementation) {
        .jsonrpc => {
            const id_value = try jsonrpc.parseId(null, string);
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
            return try jsonrpc.parseMethod(buf, string);
        },
    }
}

const RpcKind = enum { jsonrpc };
const rpcImplementation = RpcKind.jsonrpc;

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
