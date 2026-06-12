/// GitHub OAuth Device Authorization Grant (pure HTTP, no threading).
/// Reference: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
const std = @import("std");
const shared = @import("shared");
const http = shared.http;
const json_util = shared.json_util;

pub const DeviceCodeResponse = struct {
    device_code:      []u8,
    user_code:        []u8,
    verification_uri: []u8,
    expires_in:       i64,
    interval:         i64,

    pub fn deinit(self: DeviceCodeResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
    }
};

pub const PollResult = union(enum) {
    token:     []u8, // caller owns; received access token
    pending:   void, // authorization_pending – keep waiting
    slow_down: void, // slow_down – increase interval
    expired:   void, // token expired – abort
    denied:    void, // user declined – abort
    err:       []u8, // caller owns; unexpected error message
};

const DEVICE_URL = "https://github.com/login/device/code";
const TOKEN_URL  = "https://github.com/login/oauth/access_token";

/// Step 1 — request a device + user code pair.
/// scope: space-separated, e.g. "repo read:user"
pub fn requestDeviceCode(
    allocator: std.mem.Allocator,
    client_id: []const u8,
) !DeviceCodeResponse {
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        "client_id={s}&scope=repo+read:user",
        .{client_id});

    const headers = [_]http.Header{
        .{ .name = "Accept",       .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    const resp = try http.request(allocator, .POST, DEVICE_URL, &headers, body);
    defer resp.deinit(allocator);

    if (resp.status != 200) return error.DeviceCodeRequestFailed;

    const parsed = try json_util.parseObject(allocator, resp.body);
    defer parsed.deinit();
    const v = parsed.value;

    const dc = json_util.getString(v, "device_code");
    const uc = json_util.getString(v, "user_code");
    const uri = json_util.getString(v, "verification_uri");
    if (dc.len == 0 or uc.len == 0) return error.InvalidDeviceCodeResponse;

    return DeviceCodeResponse{
        .device_code      = try allocator.dupe(u8, dc),
        .user_code        = try allocator.dupe(u8, uc),
        .verification_uri = try allocator.dupe(u8, if (uri.len > 0) uri else "https://github.com/login/device"),
        .expires_in       = json_util.getInt(v, "expires_in"),
        .interval         = json_util.getInt(v, "interval"),
    };
}

/// Step 2 — poll once.  Caller sleeps `interval` seconds between calls.
pub fn pollToken(
    allocator: std.mem.Allocator,
    client_id: []const u8,
    device_code: []const u8,
) !PollResult {
    var body_buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
        .{ client_id, device_code });

    const headers = [_]http.Header{
        .{ .name = "Accept",       .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };
    const resp = try http.request(allocator, .POST, TOKEN_URL, &headers, body);
    defer resp.deinit(allocator);

    const parsed = try json_util.parseObject(allocator, resp.body);
    defer parsed.deinit();
    const v = parsed.value;

    const token = json_util.getString(v, "access_token");
    if (token.len > 0) return PollResult{ .token = try allocator.dupe(u8, token) };

    const code = json_util.getString(v, "error");
    if (std.mem.eql(u8, code, "authorization_pending"))    return .pending;
    if (std.mem.eql(u8, code, "slow_down"))                return .slow_down;
    if (std.mem.eql(u8, code, "expired_token"))            return .expired;
    if (std.mem.eql(u8, code, "access_denied"))            return .denied;

    const msg = json_util.getString(v, "error_description");
    return PollResult{ .err = try allocator.dupe(u8, if (msg.len > 0) msg else code) };
}
