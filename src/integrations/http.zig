/// Thin HTTP client wrapper using std.http.Client.
/// No unit tests — HTTP calls require a live server.
const std = @import("std");

pub const Method = enum { GET, POST, PATCH };

pub const Header = struct {
    name:  []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: u16,
    body:   []u8, // caller owns

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

/// Perform a single HTTP request and return the full response body.
/// Caller must call resp.deinit(allocator) when done.
/// body_json: optional request body for POST/PATCH.
pub fn request(
    allocator: std.mem.Allocator,
    method: Method,
    url: []const u8,
    headers: []const Header,
    body_json: ?[]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    const http_method: std.http.Method = switch (method) {
        .GET   => .GET,
        .POST  => .POST,
        .PATCH => .PATCH,
    };

    // Build extra headers list
    var extra_headers = std.ArrayListUnmanaged(std.http.Header){};
    defer extra_headers.deinit(allocator);
    for (headers) |h| {
        try extra_headers.append(allocator, .{ .name = h.name, .value = h.value });
    }
    if (body_json != null) {
        try extra_headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    }

    // Use an Allocating writer to collect the response body dynamically
    var body_writer = std.io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const result = try client.fetch(.{
        .method          = http_method,
        .location        = .{ .uri = uri },
        .extra_headers   = extra_headers.items,
        .payload         = body_json,
        .response_writer = &body_writer.writer,
    });

    return Response{
        .status = @intFromEnum(result.status),
        .body   = try body_writer.toOwnedSlice(),
    };
}
