const std = @import("std");

const Allocator = std.mem.Allocator;

/// A parsed JSON-RPC style request.
pub const Request = struct {
    id: i64,
    method: []const u8,
    /// The full raw JSON line, kept for lazy param extraction.
    raw_line: []const u8,

    /// Parse a line of JSON into a Request.
    pub fn parse(alloc: Allocator, line: []const u8) !Request {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidRequest;

        const id_val = root.object.get("id") orelse return error.MissingId;
        const id: i64 = switch (id_val) {
            .integer => id_val.integer,
            .float => @intFromFloat(id_val.float),
            else => return error.InvalidId,
        };

        const method_val = root.object.get("method") orelse return error.MissingMethod;
        if (method_val != .string) return error.InvalidMethod;

        return .{
            .id = id,
            .method = try alloc.dupe(u8, method_val.string),
            .raw_line = try alloc.dupe(u8, line),
        };
    }

    pub fn deinit(self: *Request, alloc: Allocator) void {
        alloc.free(self.method);
        alloc.free(self.raw_line);
    }

    /// Get a string parameter from the params JSON.
    pub fn getStringParam(self: *const Request, alloc: Allocator, key: []const u8) ?[]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, self.raw_line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const params = parsed.value.object.get("params") orelse return null;
        if (params != .object) return null;
        const val = params.object.get(key) orelse return null;
        if (val != .string) return null;
        return alloc.dupe(u8, val.string) catch null;
    }

    /// Get a boolean parameter from the params JSON.
    pub fn getBoolParam(self: *const Request, alloc: Allocator, key: []const u8) ?bool {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, self.raw_line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const params = parsed.value.object.get("params") orelse return null;
        if (params != .object) return null;
        const val = params.object.get(key) orelse return null;
        return switch (val) {
            .bool => val.bool,
            else => null,
        };
    }

    /// Get a float parameter from the params JSON.
    pub fn getFloatParam(self: *const Request, alloc: Allocator, key: []const u8) ?f64 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, self.raw_line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const params = parsed.value.object.get("params") orelse return null;
        if (params != .object) return null;
        const val = params.object.get(key) orelse return null;
        return switch (val) {
            .float => val.float,
            .integer => @floatFromInt(val.integer),
            else => null,
        };
    }

    /// Get an integer parameter from the params JSON.
    pub fn getIntParam(self: *const Request, alloc: Allocator, key: []const u8) ?i64 {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, self.raw_line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const params = parsed.value.object.get("params") orelse return null;
        if (params != .object) return null;
        const val = params.object.get(key) orelse return null;
        return switch (val) {
            .integer => val.integer,
            .float => @intFromFloat(val.float),
            else => null,
        };
    }
};

/// Build a success response JSON line.
pub fn successResponse(alloc: Allocator, id: i64, result_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"id":{d},"ok":true,"result":{s}}}
    , .{ id, result_json }) catch return error.OutOfMemory;
}

/// Build an error response JSON line.
pub fn errorResponse(alloc: Allocator, id: i64, code: []const u8, message: []const u8) ![]const u8 {
    // Simple JSON escaping for the message
    var escaped: std.ArrayListUnmanaged(u8) = .{};
    defer escaped.deinit(alloc);
    for (message) |ch| {
        switch (ch) {
            '"' => try escaped.appendSlice(alloc, "\\\""),
            '\\' => try escaped.appendSlice(alloc, "\\\\"),
            '\n' => try escaped.appendSlice(alloc, "\\n"),
            '\r' => try escaped.appendSlice(alloc, "\\r"),
            '\t' => try escaped.appendSlice(alloc, "\\t"),
            else => try escaped.append(alloc, ch),
        }
    }

    return std.fmt.allocPrint(alloc,
        \\{{"id":{d},"ok":false,"error":{{"code":"{s}","message":"{s}"}}}}
    , .{ id, code, escaped.items });
}
