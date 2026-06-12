/// Shared module for the bundled todo extensions.
pub const http = @import("http.zig");
pub const json_util = @import("json_util.zig");
pub const task = @import("task.zig");
pub const proto = @import("proto.zig");

comptime {
    _ = http;
    _ = json_util;
    _ = task;
    _ = proto;
}
