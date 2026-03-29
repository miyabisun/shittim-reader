//! Window capture via Win32 API.
//!
//! Captures the client area of a game window by bringing it to the
//! foreground and using BitBlt from the screen DC. This approach
//! works reliably for DirectX/hardware-accelerated windows.
//!
//! The existing Rust projects (bluearchive-aoi, timeline-plana) use
//! Windows Graphics Capture API via the `windows-capture` crate.
//! That API requires extensive COM/WinRT interop which is impractical
//! in Zig. This module uses the simpler screen-capture approach
//! suitable for CLI development tools.

const std = @import("std");

// ── Win32 types ──

const BOOL = std.os.windows.BOOL;
const HANDLE = *anyopaque;
const HWND = *anyopaque;

const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 0,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER = .{},
    bmiColors: [1]u32 = .{0},
};

// Constants
const SRCCOPY: u32 = 0x00CC0020;
const DIB_RGB_COLORS: u32 = 0;
const CP_UTF8: u32 = 65001;
const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;
// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

// ── Win32 extern functions ──

// user32
extern "user32" fn FindWindowW(
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
) callconv(.winapi) ?HWND;

extern "user32" fn FindWindowExW(
    hWndParent: ?HWND,
    hWndChildAfter: ?HWND,
    lpszClass: ?[*:0]const u16,
    lpszWindow: ?[*:0]const u16,
) callconv(.winapi) ?HWND;

extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HANDLE;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HANDLE) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;

// gdi32
extern "gdi32" fn CreateCompatibleDC(hdc: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "gdi32" fn CreateCompatibleBitmap(hdc: HANDLE, cx: i32, cy: i32) callconv(.winapi) ?HANDLE;
extern "gdi32" fn SelectObject(hdc: HANDLE, h: HANDLE) callconv(.winapi) ?HANDLE;
extern "gdi32" fn DeleteDC(hdc: HANDLE) callconv(.winapi) BOOL;
extern "gdi32" fn DeleteObject(ho: HANDLE) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(
    hdcDest: HANDLE,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    hdcSrc: HANDLE,
    x1: i32,
    y1: i32,
    rop: u32,
) callconv(.winapi) BOOL;
extern "gdi32" fn GetDIBits(
    hdc: HANDLE,
    hbm: HANDLE,
    start: u32,
    cLines: u32,
    lpvBits: [*]u8,
    lpbmi: *BITMAPINFO,
    usage: u32,
) callconv(.winapi) i32;

// dwmapi
extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: HWND,
    dwAttribute: u32,
    pvAttribute: *anyopaque,
    cbAttribute: u32,
) callconv(.winapi) i32;

// kernel32
extern "kernel32" fn MultiByteToWideChar(
    CodePage: u32,
    dwFlags: u32,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: i32,
    lpWideCharStr: ?[*]u16,
    cchWideChar: i32,
) callconv(.winapi) i32;

extern "kernel32" fn WideCharToMultiByte(
    CodePage: u32,
    dwFlags: u32,
    lpWideCharStr: [*]const u16,
    cchWideChar: i32,
    lpMultiByteStr: ?[*]u8,
    cbMultiByte: i32,
    lpDefaultChar: ?*const u8,
    lpUsedDefaultChar: ?*BOOL,
) callconv(.winapi) i32;

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

// ── Public types ──

pub const CaptureResult = struct {
    pixels: []u8, // RGB, 3 bytes per pixel
    width: u32,
    height: u32,

    pub fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const CaptureError = error{
    WindowNotFound,
    GetClientRectFailed,
    GetDCFailed,
    CreateDCFailed,
    CreateBitmapFailed,
    CaptureFailed,
    GetDIBitsFailed,
    OutOfMemory,
    InvalidDimensions,
};

// ── Public functions ──

/// Find a window by exact title (UTF-8).
pub fn findWindowByTitle(title: []const u8) CaptureError!HWND {
    var buf: [256]u16 = undefined;
    const len = MultiByteToWideChar(CP_UTF8, 0, title.ptr, @intCast(title.len), &buf, 256);
    if (len <= 0) return error.WindowNotFound;
    buf[@intCast(len)] = 0;
    const title_z: [*:0]const u16 = @ptrCast(&buf);
    return FindWindowW(null, title_z) orelse error.WindowNotFound;
}

/// Find the first visible window whose title contains the given substring (UTF-8).
pub fn findWindowBySubstring(pattern: []const u8) CaptureError!HWND {
    var pattern_buf: [256]u16 = undefined;
    const pat_len = MultiByteToWideChar(CP_UTF8, 0, pattern.ptr, @intCast(pattern.len), &pattern_buf, 256);
    if (pat_len <= 0) return error.WindowNotFound;
    const needle: []const u16 = pattern_buf[0..@intCast(pat_len)];

    var hwnd: ?HWND = FindWindowExW(null, null, null, null);
    while (hwnd) |h| {
        if (IsWindowVisible(h) != 0) {
            var title_buf: [512]u16 = undefined;
            const title_len = GetWindowTextW(h, &title_buf, 512);
            if (title_len > 0) {
                const title: []const u16 = title_buf[0..@intCast(title_len)];
                if (containsUtf16(title, needle)) {
                    return h;
                }
            }
        }
        hwnd = FindWindowExW(null, h, null, null);
    }

    return error.WindowNotFound;
}

/// Capture the client area of a window, returning RGB pixels.
///
/// Strategy (matching bluearchive-aoi / timeline-plana):
///   1. Set DPI awareness for correct coordinate APIs
///   2. Bring window to foreground (required for screen DC capture)
///   3. Get client area geometry via DwmGetWindowAttribute + ClientToScreen
///   4. BitBlt from screen DC at the client area's screen coordinates
///   5. Convert BGRA → RGB
pub fn captureWindow(allocator: std.mem.Allocator, hwnd: HWND) CaptureError!CaptureResult {
    // DPI awareness: ensures GetClientRect/ClientToScreen return physical pixels
    // (same approach as bluearchive-aoi)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Bring window to foreground so screen DC capture gets the game content
    _ = SetForegroundWindow(hwnd);
    Sleep(200); // wait for window to render

    // Get client area dimensions
    var client_rect: RECT = .{};
    if (GetClientRect(hwnd, &client_rect) == 0) return error.GetClientRectFailed;

    const width: u32 = @intCast(client_rect.right);
    const height: u32 = @intCast(client_rect.bottom);
    if (width == 0 or height == 0) return error.InvalidDimensions;

    // Get client area position in screen coordinates
    var client_origin = POINT{};
    _ = ClientToScreen(hwnd, &client_origin);

    // Create memory DC and bitmap
    const screen_dc = GetDC(null) orelse return error.GetDCFailed;
    defer _ = ReleaseDC(null, screen_dc);

    const mem_dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDCFailed;
    defer _ = DeleteDC(mem_dc);

    const bitmap = CreateCompatibleBitmap(screen_dc, @intCast(width), @intCast(height)) orelse return error.CreateBitmapFailed;
    const old_bmp = SelectObject(mem_dc, bitmap);
    defer {
        if (old_bmp) |ob| _ = SelectObject(mem_dc, ob);
        _ = DeleteObject(bitmap);
    }

    // BitBlt from screen DC at the client area's screen coordinates
    if (BitBlt(
        mem_dc,
        0,
        0,
        @intCast(width),
        @intCast(height),
        screen_dc,
        client_origin.x,
        client_origin.y,
        SRCCOPY,
    ) == 0) {
        return error.CaptureFailed;
    }

    // Deselect bitmap before GetDIBits
    if (old_bmp) |ob| {
        _ = SelectObject(mem_dc, ob);
    }

    // Read BGRA pixels
    var bmi = BITMAPINFO{
        .bmiHeader = .{
            .biWidth = @intCast(width),
            .biHeight = -@as(i32, @intCast(height)), // top-down
            .biBitCount = 32,
        },
    };

    const bgra = try allocator.alloc(u8, @as(usize, width) * height * 4);
    defer allocator.free(bgra);

    if (GetDIBits(screen_dc, bitmap, 0, height, bgra.ptr, &bmi, DIB_RGB_COLORS) == 0) {
        return error.GetDIBitsFailed;
    }

    // Convert BGRA → RGB
    const pixel_count = @as(usize, width) * height;
    const rgb = try allocator.alloc(u8, pixel_count * 3);
    for (0..pixel_count) |i| {
        rgb[i * 3 + 0] = bgra[i * 4 + 2]; // R
        rgb[i * 3 + 1] = bgra[i * 4 + 1]; // G
        rgb[i * 3 + 2] = bgra[i * 4 + 0]; // B
    }

    return .{
        .pixels = rgb,
        .width = width,
        .height = height,
    };
}

/// List all visible windows with their titles to the given writer.
pub fn listWindows(writer: *std.Io.Writer) !void {
    var hwnd: ?HWND = FindWindowExW(null, null, null, null);
    while (hwnd) |h| {
        if (IsWindowVisible(h) != 0) {
            var title_buf: [512]u16 = undefined;
            const title_len = GetWindowTextW(h, &title_buf, 512);
            if (title_len > 0) {
                var utf8_buf: [1024]u8 = undefined;
                const utf8_len = WideCharToMultiByte(
                    CP_UTF8,
                    0,
                    &title_buf,
                    title_len,
                    &utf8_buf,
                    utf8_buf.len,
                    null,
                    null,
                );
                if (utf8_len > 0) {
                    try writer.print("{s}\n", .{utf8_buf[0..@intCast(utf8_len)]});
                }
            }
        }
        hwnd = FindWindowExW(null, h, null, null);
    }
}

// ── Helpers ──

fn containsUtf16(haystack: []const u16, needle: []const u16) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.mem.eql(u16, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
