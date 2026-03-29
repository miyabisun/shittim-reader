//! Windows Graphics Capture (WGC) API: background window capture via Direct3D 11.
//!
//! Unlike BitBlt-based capture, WGC can capture windows that are occluded or
//! in the background. Requires Windows 10 1903+ with Graphics Capture support.

const std = @import("std");

// ── Win32 base types ──

const HRESULT = i32;
const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };
const HSTRING = *anyopaque;

const SizeInt32 = extern struct {
    width: i32,
    height: i32,
};

const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc: extern struct { Count: u32, Quality: u32 },
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?[*]u8,
    RowPitch: u32,
    DepthPitch: u32,
};

// ── Constants ──

const RO_INIT_MULTITHREADED: i32 = 1;
const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_USAGE_STAGING: u32 = 3;
const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
const D3D11_MAP_READ: u32 = 1;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;

// ── IIDs ──

const IID_IDXGIDevice = GUID{
    .data1 = 0x54ec77fa, .data2 = 0x1377, .data3 = 0x44e6,
    .data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};
const IID_IGraphicsCaptureItemInterop = GUID{
    .data1 = 0x3628e81b, .data2 = 0x3cac, .data3 = 0x4c60,
    .data4 = .{ 0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56 },
};
const IID_IGraphicsCaptureItem = GUID{
    .data1 = 0x79c3f95b, .data2 = 0x31f7, .data3 = 0x4ec2,
    .data4 = .{ 0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60 },
};
const IID_IDirect3DDxgiInterfaceAccess = GUID{
    .data1 = 0xa9b3d012, .data2 = 0x3df2, .data3 = 0x4ee3,
    .data4 = .{ 0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1 },
};
const IID_IClosable = GUID{
    .data1 = 0x30d5a829, .data2 = 0x7fa4, .data3 = 0x4026,
    .data4 = .{ 0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e },
};
const IID_ID3D11Texture2D = GUID{
    .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89,
    .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

// IDirect3D11CaptureFramePoolStatics2 IID (for CreateFreeThreaded)
const IID_IDirect3D11CaptureFramePoolStatics2 = GUID{
    .data1 = 0x589b103f, .data2 = 0x6bbc, .data3 = 0x5df5,
    .data4 = .{ 0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5 },
};

// ── Vtable access ──

/// Read a function pointer from a COM vtable at the given slot index.
fn vtblSlot(comptime T: type, obj: *anyopaque, comptime index: usize) T {
    const vtbl_ptr: *const [*]const usize = @ptrCast(@alignCast(obj));
    return @ptrFromInt(vtbl_ptr.*[index]);
}

// ── COM helpers ──

/// Release a COM object via its IUnknown::Release (vtable slot 2).
inline fn comRelease(ptr: *anyopaque) void {
    const release: *const fn (*anyopaque) callconv(.winapi) u32 =
        vtblSlot(*const fn (*anyopaque) callconv(.winapi) u32, ptr, 2);
    _ = release(ptr);
}

/// Call IUnknown::QueryInterface (vtable slot 0).
inline fn comQueryInterface(ptr: *anyopaque, iid: *const GUID, out: **anyopaque) HRESULT {
    const qi: *const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT, ptr, 0);
    return qi(ptr, iid, out);
}

/// Close an IClosable object (QI for IClosable, call Close, then Release).
/// No-op if the object does not implement IClosable.
inline fn comClose(ptr: *anyopaque) void {
    var closable: *anyopaque = undefined;
    if (comQueryInterface(ptr, &IID_IClosable, &closable) >= 0) {
        const close_fn: *const fn (*anyopaque) callconv(.winapi) HRESULT =
            vtblSlot(*const fn (*anyopaque) callconv(.winapi) HRESULT, closable, 6);
        _ = close_fn(closable);
        comRelease(closable);
    }
}

// Vtable slot reference (for documentation):
// IUnknown: QueryInterface(0), AddRef(1), Release(2)
// IInspectable: IUnknown + GetIids(3), GetRuntimeClassName(4), GetTrustLevel(5)
// ID3D11Device: CreateTexture2D(5), GetImmediateContext(40)
// ID3D11DeviceContext: Map(14), Unmap(15), CopyResource(47)
// ID3D11Texture2D: GetDesc(10)  [IUnknown(3) + DeviceChild(4) + Resource(3)]
// IGraphicsCaptureItemInterop: CreateForWindow(3)
// IGraphicsCaptureItem: get_Size(7)
// IDirect3D11CaptureFramePoolStatics2: CreateFreeThreaded(6)
// IDirect3D11CaptureFramePool: TryGetNextFrame(7), CreateCaptureSession(10)
// IGraphicsCaptureSession: StartCapture(6)
// IDirect3D11CaptureFrame: get_Surface(6)
// IDirect3DDxgiInterfaceAccess: GetInterface(3)
// IClosable: Close(6)

// ── Extern function declarations ──

// WinRT core (api-ms-win-core-winrt-l1-1-0)
extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(initType: i32) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoUninitialize() callconv(.winapi) void;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(classId: HSTRING, iid: *const GUID, factory: **anyopaque) callconv(.winapi) HRESULT;

// WinRT strings (api-ms-win-core-winrt-string-l1-1-0)
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(src: [*]const u16, len: u32, out: *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(str: HSTRING) callconv(.winapi) HRESULT;

// d3d11
extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    feature_levels: ?[*]const u32,
    num_levels: u32,
    sdk_version: u32,
    device: **anyopaque,
    feature_level: ?*u32,
    context: **anyopaque,
) callconv(.winapi) HRESULT;

// d3d11 (from dxgi.lib but we load via d3d11)
extern "d3d11" fn CreateDirect3D11DeviceFromDXGIDevice(
    dxgi_device: *anyopaque,
    graphics_device: **anyopaque,
) callconv(.winapi) HRESULT;

// kernel32
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

// ── Public API ──

pub const WgcError = error{
    ComInitFailed,
    D3D11CreateDeviceFailed,
    QueryInterfaceFailed,
    WrapDeviceFailed,
    ActivationFactoryFailed,
    CreateCaptureItemFailed,
    GetSizeFailed,
    FramePoolCreateFailed,
    SessionCreateFailed,
    StartCaptureFailed,
    CaptureTimeout,
    GetSurfaceFailed,
    GetTextureFailed,
    CreateStagingFailed,
    MapFailed,
    OutOfMemory,
    StringCreateFailed,
};

pub const CaptureResult = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: CaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Capture a window's contents using Windows Graphics Capture API.
/// This works for background/occluded windows (unlike BitBlt).
/// Requires Windows 10 version 1903 or later.
pub fn captureWindow(allocator: std.mem.Allocator, hwnd: *anyopaque) WgcError!CaptureResult {
    // 1. Initialize WinRT
    const ro_hr = RoInitialize(RO_INIT_MULTITHREADED);
    // RPC_E_CHANGED_MODE (0x80010106) is OK — means already initialized as STA
    if (ro_hr < 0 and ro_hr != @as(i32, @bitCast(@as(u32, 0x80010106)))) return error.ComInitFailed;
    defer RoUninitialize();

    // 2. Create D3D11 device
    const feature_levels = [_]u32{D3D_FEATURE_LEVEL_11_0};
    var device: *anyopaque = undefined;
    var feature_level: u32 = 0;
    var context: *anyopaque = undefined;

    if (D3D11CreateDevice(
        null,
        D3D_DRIVER_TYPE_HARDWARE,
        null,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        &feature_levels,
        1,
        7, // D3D11_SDK_VERSION
        &device,
        &feature_level,
        &context,
    ) < 0) return error.D3D11CreateDeviceFailed;
    defer comRelease(device);
    defer comRelease(context);

    // 3. Get IDXGIDevice from D3D11 device
    var dxgi_device: *anyopaque = undefined;
    if (comQueryInterface(device, &IID_IDXGIDevice, &dxgi_device) < 0) return error.QueryInterfaceFailed;
    defer comRelease(dxgi_device);

    // 4. Wrap as WinRT IDirect3DDevice
    var d3d_device: *anyopaque = undefined;
    if (CreateDirect3D11DeviceFromDXGIDevice(dxgi_device, &d3d_device) < 0) return error.WrapDeviceFailed;
    defer comRelease(d3d_device);

    // 5. Get IGraphicsCaptureItemInterop via activation factory for GraphicsCaptureItem
    const capture_item_class = comptime toUtf16Literal("Windows.Graphics.Capture.GraphicsCaptureItem");
    var capture_item_hstring: HSTRING = undefined;
    if (WindowsCreateString(&capture_item_class, capture_item_class.len, &capture_item_hstring) < 0) return error.StringCreateFailed;
    defer _ = WindowsDeleteString(capture_item_hstring);

    var interop: *anyopaque = undefined;
    if (RoGetActivationFactory(capture_item_hstring, &IID_IGraphicsCaptureItemInterop, &interop) < 0) return error.ActivationFactoryFailed;
    defer comRelease(interop);

    // 6. Create capture item for window
    var capture_item: *anyopaque = undefined;
    const create_for_window: *const fn (*anyopaque, *anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT, interop, 3);
    if (create_for_window(interop, hwnd, &IID_IGraphicsCaptureItem, &capture_item) < 0) return error.CreateCaptureItemFailed;
    defer comRelease(capture_item);

    // 7. Get capture item size
    var size: SizeInt32 = undefined;
    const get_size: *const fn (*anyopaque, *SizeInt32) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *SizeInt32) callconv(.winapi) HRESULT, capture_item, 7);
    if (get_size(capture_item, &size) < 0) return error.GetSizeFailed;

    // 8. Get frame pool factory (IDirect3D11CaptureFramePoolStatics2)
    const frame_pool_class = comptime toUtf16Literal("Windows.Graphics.Capture.Direct3D11CaptureFramePool");
    var frame_pool_hstring: HSTRING = undefined;
    if (WindowsCreateString(&frame_pool_class, frame_pool_class.len, &frame_pool_hstring) < 0) return error.StringCreateFailed;
    defer _ = WindowsDeleteString(frame_pool_hstring);

    var factory2: *anyopaque = undefined;
    if (RoGetActivationFactory(frame_pool_hstring, &IID_IDirect3D11CaptureFramePoolStatics2, &factory2) < 0) return error.ActivationFactoryFailed;
    defer comRelease(factory2);

    // 9. CreateFreeThreaded(d3d_device, BGRA8, 1, size) → frame_pool
    var frame_pool: *anyopaque = undefined;
    const create_free_threaded: *const fn (*anyopaque, *anyopaque, u32, i32, SizeInt32, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *anyopaque, u32, i32, SizeInt32, **anyopaque) callconv(.winapi) HRESULT, factory2, 6);
    if (create_free_threaded(factory2, d3d_device, DXGI_FORMAT_B8G8R8A8_UNORM, 1, size, &frame_pool) < 0) return error.FramePoolCreateFailed;
    defer {
        comClose(frame_pool);
        comRelease(frame_pool);
    }

    // 10. CreateCaptureSession
    var session: *anyopaque = undefined;
    const create_session: *const fn (*anyopaque, *anyopaque, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *anyopaque, **anyopaque) callconv(.winapi) HRESULT, frame_pool, 10);
    if (create_session(frame_pool, capture_item, &session) < 0) return error.SessionCreateFailed;
    defer {
        comClose(session);
        comRelease(session);
    }

    // 11. StartCapture
    const start_capture: *const fn (*anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque) callconv(.winapi) HRESULT, session, 6);
    if (start_capture(session) < 0) return error.StartCaptureFailed;

    // 12. Poll for frame (max ~1 second: 62 retries x 16ms)
    var frame: *anyopaque = undefined;
    const try_get_next: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT, frame_pool, 7);

    var got_frame = false;
    for (0..62) |_| {
        var maybe_frame: *anyopaque = undefined;
        const hr = try_get_next(frame_pool, &maybe_frame);
        if (hr >= 0 and @intFromPtr(maybe_frame) != 0) {
            frame = maybe_frame;
            got_frame = true;
            break;
        }
        Sleep(16);
    }
    if (!got_frame) return error.CaptureTimeout;
    defer comRelease(frame);

    // 13. Get surface → IDirect3DDxgiInterfaceAccess → ID3D11Texture2D
    var surface: *anyopaque = undefined;
    const get_surface: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT, frame, 6);
    if (get_surface(frame, &surface) < 0) return error.GetSurfaceFailed;
    defer comRelease(surface);

    var access: *anyopaque = undefined;
    if (comQueryInterface(surface, &IID_IDirect3DDxgiInterfaceAccess, &access) < 0) return error.GetSurfaceFailed;
    defer comRelease(access);

    var frame_texture: *anyopaque = undefined;
    const get_interface: *const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *const GUID, **anyopaque) callconv(.winapi) HRESULT, access, 3);
    if (get_interface(access, &IID_ID3D11Texture2D, &frame_texture) < 0) return error.GetTextureFailed;
    defer comRelease(frame_texture);

    // 14. GetDesc
    var desc: D3D11_TEXTURE2D_DESC = undefined;
    const get_desc: *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(.winapi) void =
        vtblSlot(*const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(.winapi) void, frame_texture, 10);
    get_desc(frame_texture, &desc);

    const width = desc.Width;
    const height = desc.Height;

    // 15. Create staging texture
    var staging_desc = D3D11_TEXTURE2D_DESC{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = desc.Format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = D3D11_USAGE_STAGING,
        .BindFlags = 0,
        .CPUAccessFlags = D3D11_CPU_ACCESS_READ,
        .MiscFlags = 0,
    };

    var staging: *anyopaque = undefined;
    const create_texture: *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC, ?*anyopaque, **anyopaque) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *D3D11_TEXTURE2D_DESC, ?*anyopaque, **anyopaque) callconv(.winapi) HRESULT, device, 5);
    if (create_texture(device, &staging_desc, null, &staging) < 0) return error.CreateStagingFailed;
    defer comRelease(staging);

    // 16. CopyResource(staging, frame_texture)
    const copy_resource: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void =
        vtblSlot(*const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void, context, 47);
    copy_resource(context, staging, frame_texture);

    // 17. Map staging texture
    var mapped: D3D11_MAPPED_SUBRESOURCE = undefined;
    const map_fn: *const fn (*anyopaque, *anyopaque, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT =
        vtblSlot(*const fn (*anyopaque, *anyopaque, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT, context, 14);
    if (map_fn(context, staging, 0, D3D11_MAP_READ, 0, &mapped) < 0) return error.MapFailed;
    defer {
        const unmap_fn: *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void =
            vtblSlot(*const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void, context, 15);
        unmap_fn(context, staging, 0);
    }

    // 18. Convert BGRA → RGB
    const src_data = mapped.pData orelse return error.MapFailed;
    const rgb = bgraToRgb(allocator, src_data, width, height, mapped.RowPitch) catch return error.OutOfMemory;

    return CaptureResult{
        .pixels = rgb,
        .width = width,
        .height = height,
    };
}

/// Convert a string literal to a UTF-16 array at comptime.
fn toUtf16Literal(comptime s: []const u8) [s.len]u16 {
    var result: [s.len]u16 = undefined;
    for (s, 0..) |c, i| {
        result[i] = c;
    }
    return result;
}

/// Convert BGRA row data to RGB pixel buffer.
/// Extracted for testability — handles row pitch padding.
pub fn bgraToRgb(
    allocator: std.mem.Allocator,
    src_data: [*]const u8,
    width: u32,
    height: u32,
    row_pitch: u32,
) error{OutOfMemory}![]u8 {
    const pixel_count: usize = @as(usize, width) * height;
    const rgb = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(rgb);

    for (0..height) |y| {
        const src_row = src_data + y * row_pitch;
        for (0..width) |x| {
            const src_offset = x * 4;
            const dst_idx = (y * width + x) * 3;
            rgb[dst_idx + 0] = src_row[src_offset + 2]; // R from BGRA
            rgb[dst_idx + 1] = src_row[src_offset + 1]; // G from BGRA
            rgb[dst_idx + 2] = src_row[src_offset + 0]; // B from BGRA
        }
    }
    return rgb;
}

// ── Tests ──

test "toUtf16Literal converts ASCII to UTF-16" {
    const result = toUtf16Literal("ABC");
    try std.testing.expectEqual(@as(u16, 'A'), result[0]);
    try std.testing.expectEqual(@as(u16, 'B'), result[1]);
    try std.testing.expectEqual(@as(u16, 'C'), result[2]);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "bgraToRgb basic 2x2" {
    const allocator = std.testing.allocator;
    // 2x2 image, row_pitch = 8 (2 pixels * 4 bytes, no padding)
    const bgra = [_]u8{
        // Row 0: pixel(0,0) BGRA=10,20,30,255  pixel(1,0) BGRA=40,50,60,255
        10, 20, 30, 255, 40, 50, 60, 255,
        // Row 1: pixel(0,1) BGRA=70,80,90,255  pixel(1,1) BGRA=100,110,120,255
        70, 80, 90, 255, 100, 110, 120, 255,
    };
    const rgb = try bgraToRgb(allocator, &bgra, 2, 2, 8);
    defer allocator.free(rgb);

    // pixel(0,0): R=30 G=20 B=10
    try std.testing.expectEqual(@as(u8, 30), rgb[0]);
    try std.testing.expectEqual(@as(u8, 20), rgb[1]);
    try std.testing.expectEqual(@as(u8, 10), rgb[2]);
    // pixel(1,0): R=60 G=50 B=40
    try std.testing.expectEqual(@as(u8, 60), rgb[3]);
    try std.testing.expectEqual(@as(u8, 50), rgb[4]);
    try std.testing.expectEqual(@as(u8, 40), rgb[5]);
    // pixel(0,1): R=90 G=80 B=70
    try std.testing.expectEqual(@as(u8, 90), rgb[6]);
    try std.testing.expectEqual(@as(u8, 80), rgb[7]);
    try std.testing.expectEqual(@as(u8, 70), rgb[8]);
}

test "bgraToRgb with row pitch padding" {
    const allocator = std.testing.allocator;
    // 1x2 image, row_pitch = 8 (padded to 8, but only 4 bytes used per row)
    const bgra = [_]u8{
        // Row 0: pixel BGRA=10,20,30,255 + 4 bytes padding
        10, 20, 30, 255, 0, 0, 0, 0,
        // Row 1: pixel BGRA=40,50,60,255 + 4 bytes padding
        40, 50, 60, 255, 0, 0, 0, 0,
    };
    const rgb = try bgraToRgb(allocator, &bgra, 1, 2, 8);
    defer allocator.free(rgb);

    // pixel(0,0): R=30 G=20 B=10
    try std.testing.expectEqual(@as(u8, 30), rgb[0]);
    try std.testing.expectEqual(@as(u8, 20), rgb[1]);
    try std.testing.expectEqual(@as(u8, 10), rgb[2]);
    // pixel(0,1): R=60 G=50 B=40
    try std.testing.expectEqual(@as(u8, 60), rgb[3]);
    try std.testing.expectEqual(@as(u8, 50), rgb[4]);
    try std.testing.expectEqual(@as(u8, 40), rgb[5]);
}

test "bgraToRgb zero dimension" {
    const allocator = std.testing.allocator;
    const bgra = [_]u8{};
    const rgb = try bgraToRgb(allocator, &bgra, 0, 0, 0);
    defer allocator.free(rgb);
    try std.testing.expectEqual(@as(usize, 0), rgb.len);
}

test "GUID layout" {
    // Verify IID_IDXGIDevice has expected first field
    try std.testing.expectEqual(@as(u32, 0x54ec77fa), IID_IDXGIDevice.data1);
}
