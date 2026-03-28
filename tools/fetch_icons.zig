//! Dev tool: download item/equipment icons from SchaleDB.
//!
//! Fetches master data JSON, extracts icon names, downloads WebP icons.
//! zigimg does not support WebP, so icons are saved as .webp files.
//!
//! Usage: zig build fetch-icons [-- --items-only | --equipment-only]

const std = @import("std");

const base_data_url = "https://schaledb.com/data/jp";
const base_icon_url = "https://schaledb.com/images";
const user_agent = "shittim-reader/0.1.0";
const request_interval_ns: u64 = 100 * std.time.ns_per_ms;

const Category = struct {
    name: []const u8,
    json_path: []const u8,
    icon_url: []const u8,
    output_dir: []const u8,
};

const categories = [_]Category{
    .{
        .name = "items",
        .json_path = "/items.json",
        .icon_url = "/item/icon",
        .output_dir = "assets/icons/items",
    },
    .{
        .name = "equipment",
        .json_path = "/equipment.json",
        .icon_url = "/equipment/icon",
        .output_dir = "assets/icons/equipment",
    },
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var items_only = false;
    var equipment_only = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--items-only")) items_only = true;
        if (std.mem.eql(u8, arg, "--equipment-only")) equipment_only = true;
    }

    std.fs.cwd().makePath("assets/data") catch {};

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    for (&categories) |*cat| {
        if (items_only and !std.mem.eql(u8, cat.name, "items")) continue;
        if (equipment_only and !std.mem.eql(u8, cat.name, "equipment")) continue;
        try processCategory(allocator, &client, cat);
    }

    std.debug.print("\nAll done.\n", .{});
}

fn processCategory(allocator: std.mem.Allocator, client: *std.http.Client, cat: *const Category) !void {
    std.debug.print("\n=== {s} ===\n", .{cat.name});

    // Fetch master data JSON
    const json_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_data_url, cat.json_path });
    defer allocator.free(json_url);

    std.debug.print("Fetching {s} ...\n", .{json_url});

    // Download JSON to memory
    const json_body = try downloadToBuffer(allocator, client, json_url);
    defer allocator.free(json_body);

    // Save a copy to disk for reference
    const data_path = try std.fmt.allocPrint(allocator, "assets/data/{s}.json", .{cat.name});
    defer allocator.free(data_path);
    {
        const file = try std.fs.cwd().createFile(data_path, .{});
        defer file.close();
        try file.writeAll(json_body);
    }
    std.debug.print("Saved {s}\n", .{data_path});

    // Extract icon names from JSON
    var icons: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (icons.items) |s| allocator.free(s);
        icons.deinit(allocator);
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_body, .{});
    defer parsed.deinit();

    // JSON might be object or array
    const entries: []const std.json.Value = switch (parsed.value) {
        .object => |obj| blk: {
            var vals: std.ArrayListUnmanaged(std.json.Value) = .empty;
            defer vals.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                try vals.append(allocator, entry.value_ptr.*);
            }
            break :blk try vals.toOwnedSlice(allocator);
        },
        .array => |arr| arr.items,
        else => &.{},
    };
    defer if (parsed.value == .object) allocator.free(entries);

    for (entries) |item| {
        if (item != .object) continue;
        const icon_val = item.object.get("Icon") orelse continue;
        if (icon_val != .string) continue;
        try icons.append(allocator, try allocator.dupe(u8, icon_val.string));
    }

    std.debug.print("Found {d} icons\n", .{icons.items.len});

    std.fs.cwd().makePath(cat.output_dir) catch {};

    // Download missing icons
    var downloaded: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;

    for (icons.items) |icon_name| {
        // Save as .webp (zigimg doesn't support WebP decode)
        const webp_path = try std.fmt.allocPrint(allocator, "{s}/{s}.webp", .{ cat.output_dir, icon_name });
        defer allocator.free(webp_path);

        // Skip if already exists
        if (std.fs.cwd().access(webp_path, .{})) |_| {
            skipped += 1;
            continue;
        } else |_| {}

        if (downloaded > 0) std.Thread.sleep(request_interval_ns);

        const webp_url = try std.fmt.allocPrint(allocator, "{s}{s}/{s}.webp", .{ base_icon_url, cat.icon_url, icon_name });
        defer allocator.free(webp_url);

        downloadToFile(allocator, client, webp_url, webp_path) catch |err| {
            std.debug.print("  SKIP {s} ({s})\n", .{ icon_name, @errorName(err) });
            failed += 1;
            continue;
        };

        downloaded += 1;
    }

    std.debug.print("Done: {d} new, {d} unchanged, {d} failed\n", .{ downloaded, skipped, failed });
}

fn downloadToBuffer(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = user_agent },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        return error.HttpError;
    }

    var transfer_buf: [16384]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try body_reader.read(&chunk);
        if (n == 0) break;
        try result.appendSlice(allocator, chunk[0..n]);
    }
    return try result.toOwnedSlice(allocator);
}

fn downloadToFile(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8) !void {
    const data = try downloadToBuffer(allocator, client, url);
    defer allocator.free(data);

    const file = try std.fs.cwd().createFile(dest_path, .{});
    defer file.close();
    try file.writeAll(data);
}
