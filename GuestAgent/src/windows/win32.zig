//! The Win32 the Windows agent calls, declared here rather than taken from std, which declares
//! next to none of it. Every prototype and constant was checked against mingw-w64's headers
//! (winuser.h, wingdi.h, winbase.h, fileapi.h, ioapiset.h, synchapi.h, processthreadsapi.h,
//! winsvc.h, combaseapi.h, oleauto.h); every structure handed to Windows by pointer is held to the
//! size the headers give it on a 64-bit system, below — a field out of place does not fail, it
//! sends a different click or a different mode.

const std = @import("std");

pub const BOOL = c_int;
pub const DWORD = u32;
pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HRESULT = i32;
pub const LPARAM = isize;
pub const WCHAR = u16;

pub const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
pub const POINT = extern struct { x: i32, y: i32 };

pub const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: DWORD = 0,
    offset_high: DWORD = 0,
    event: ?HANDLE = null,
};

pub const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };

pub const MOUSEINPUT = extern struct {
    dx: i32 = 0,
    dy: i32 = 0,
    mouse_data: DWORD = 0,
    flags: DWORD = 0,
    time: DWORD = 0,
    extra_info: usize = 0,
};

pub const KEYBDINPUT = extern struct {
    vk: u16 = 0,
    scan: u16 = 0,
    flags: DWORD = 0,
    time: DWORD = 0,
    extra_info: usize = 0,
};

pub const INPUT = extern struct {
    kind: DWORD,
    data: extern union { mouse: MOUSEINPUT, key: KEYBDINPUT },
};

/// DEVMODEW, display half.
pub const DEVMODEW = extern struct {
    device_name: [32]WCHAR = @splat(0),
    spec_version: u16 = 0,
    driver_version: u16 = 0,
    size: u16 = @sizeOf(DEVMODEW),
    driver_extra: u16 = 0,
    fields: DWORD = 0,
    x: i32 = 0,
    y: i32 = 0,
    orientation: DWORD = 0,
    fixed_output: DWORD = 0,
    color: i16 = 0,
    duplex: i16 = 0,
    y_resolution: i16 = 0,
    tt_option: i16 = 0,
    collate: i16 = 0,
    form_name: [32]WCHAR = @splat(0),
    log_pixels: u16 = 0,
    bits_per_pel: DWORD = 0,
    pels_width: DWORD = 0,
    pels_height: DWORD = 0,
    display_flags: DWORD = 0,
    display_frequency: DWORD = 0,
    icm_method: DWORD = 0,
    icm_intent: DWORD = 0,
    media_type: DWORD = 0,
    dither_type: DWORD = 0,
    reserved1: DWORD = 0,
    reserved2: DWORD = 0,
    panning_width: DWORD = 0,
    panning_height: DWORD = 0,
};

/// BITMAPINFOHEADER, which with no colour table is all of a 32-bit BITMAPINFO.
pub const BITMAPINFOHEADER = extern struct {
    size: DWORD = @sizeOf(BITMAPINFOHEADER),
    width: i32,
    height: i32,
    planes: u16 = 1,
    bit_count: u16 = 32,
    compression: DWORD = 0, // BI_RGB
    size_image: DWORD = 0,
    x_pels_per_meter: i32 = 0,
    y_pels_per_meter: i32 = 0,
    colors_used: DWORD = 0,
    colors_important: DWORD = 0,
};

pub const SERVICE_STATUS = extern struct {
    service_type: DWORD = SERVICE_WIN32_OWN_PROCESS,
    current_state: DWORD,
    controls_accepted: DWORD = 0,
    win32_exit_code: DWORD = 0,
    service_specific_exit_code: DWORD = 0,
    check_point: DWORD = 0,
    wait_hint: DWORD = 0,
};

pub const ServiceMain = *const fn (DWORD, ?[*]?[*:0]u16) callconv(.winapi) void;
pub const HandlerEx = *const fn (DWORD, DWORD, ?*anyopaque, ?*anyopaque) callconv(.winapi) DWORD;
pub const SERVICE_TABLE_ENTRYW = extern struct { name: ?[*:0]const u16, main: ?ServiceMain };
pub const EnumProc = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

comptime {
    const sizes = .{
        .{ RECT, 16 },           .{ POINT, 8 },                 .{ OVERLAPPED, 32 },
        .{ GUID, 16 },           .{ MOUSEINPUT, 32 },           .{ KEYBDINPUT, 24 },
        .{ INPUT, 40 },          .{ DEVMODEW, 220 },            .{ BITMAPINFOHEADER, 40 },
        .{ SERVICE_STATUS, 28 }, .{ SERVICE_TABLE_ENTRYW, 16 },
    };
    for (sizes) |entry| {
        if (@sizeOf(entry[0]) != entry[1]) @compileError(std.fmt.comptimePrint(
            "{s} is {d} bytes, not {d}",
            .{ @typeName(entry[0]), @sizeOf(entry[0]), entry[1] },
        ));
    }
    if (@offsetOf(DEVMODEW, "fields") != 72) @compileError("DEVMODEW.fields is out of place");
    if (@offsetOf(DEVMODEW, "pels_width") != 172) @compileError("DEVMODEW.pels_width is out of place");
    if (@offsetOf(INPUT, "data") != 8) @compileError("INPUT's union is out of place");
    if (@offsetOf(OVERLAPPED, "event") != 24) @compileError("OVERLAPPED.hEvent is out of place");
}

// Constants, as the headers give them.
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const ABOVE_NORMAL_PRIORITY_CLASS: DWORD = 0x8000;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const INFINITE: DWORD = 0xffffffff;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const SERVICE_WIN32_OWN_PROCESS: DWORD = 0x10;
pub const SERVICE_STOPPED: DWORD = 1;
pub const SERVICE_START_PENDING: DWORD = 2;
pub const SERVICE_STOP_PENDING: DWORD = 3;
pub const SERVICE_RUNNING: DWORD = 4;
pub const SERVICE_ACCEPT_STOP: DWORD = 1;
pub const SERVICE_ACCEPT_SHUTDOWN: DWORD = 4;
pub const SERVICE_CONTROL_STOP: DWORD = 1;
pub const SERVICE_CONTROL_INTERROGATE: DWORD = 4;
pub const SERVICE_CONTROL_SHUTDOWN: DWORD = 5;
pub const NO_ERROR: DWORD = 0;
pub const ENUM_CURRENT_SETTINGS: DWORD = 0xffffffff;
pub const CDS_UPDATEREGISTRY: DWORD = 1;
pub const DM_PELSWIDTH: DWORD = 0x00080000;
pub const DM_PELSHEIGHT: DWORD = 0x00100000;
pub const DISP_CHANGE_SUCCESSFUL: i32 = 0;
pub const GA_ROOT: u32 = 2;
pub const PW_RENDERFULLCONTENT: u32 = 2;
pub const DIB_RGB_COLORS: u32 = 0;
pub const INPUT_MOUSE: DWORD = 0;
pub const INPUT_KEYBOARD: DWORD = 1;
pub const MOUSEEVENTF_LEFTDOWN: DWORD = 0x0002;
pub const MOUSEEVENTF_LEFTUP: DWORD = 0x0004;
pub const MOUSEEVENTF_RIGHTDOWN: DWORD = 0x0008;
pub const MOUSEEVENTF_RIGHTUP: DWORD = 0x0010;
pub const KEYEVENTF_KEYUP: DWORD = 0x0002;
pub const KEYEVENTF_UNICODE: DWORD = 0x0004;
pub const CF_UNICODETEXT: u32 = 13;
pub const GMEM_MOVEABLE: u32 = 0x2;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
pub const COINIT_MULTITHREADED: DWORD = 0x0;

// kernel32
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, count: DWORD, read: ?*DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, count: DWORD, written: ?*DWORD, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *OVERLAPPED, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn SetPriorityClass(process: HANDLE, class: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn QueryFullProcessImageNameW(process: HANDLE, flags: DWORD, name: [*]u16, size: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(.winapi) ?HANDLE;

// user32
pub extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
pub extern "user32" fn EnumWindows(callback: EnumProc, parameter: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(window: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(window: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(window: HWND, text: [*]u16, count: c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowThreadProcessId(window: HWND, pid: ?*DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn WindowFromPoint(point: POINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) ?HWND;
pub extern "user32" fn SetCursorPos(x: c_int, y: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SendInput(count: u32, inputs: [*]const INPUT, size: c_int) callconv(.winapi) u32;
pub extern "user32" fn PrintWindow(window: HWND, context: HDC, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn VkKeyScanW(character: WCHAR) callconv(.winapi) i16;
pub extern "user32" fn EnumDisplaySettingsW(device: ?[*:0]const u16, mode: DWORD, devmode: *DEVMODEW) callconv(.winapi) BOOL;
pub extern "user32" fn ChangeDisplaySettingsW(devmode: ?*DEVMODEW, flags: DWORD) callconv(.winapi) i32;
pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(format: u32, memory: HANDLE) callconv(.winapi) ?HANDLE;

// gdi32
pub extern "gdi32" fn CreateCompatibleDC(context: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateDIBSection(context: HDC, info: *const BITMAPINFOHEADER, usage: u32, bits: *?*anyopaque, section: ?HANDLE, offset: DWORD) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SelectObject(context: HDC, object: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(context: HDC) callconv(.winapi) BOOL;

// advapi32
pub extern "advapi32" fn StartServiceCtrlDispatcherW(table: [*]const SERVICE_TABLE_ENTRYW) callconv(.winapi) BOOL;
pub extern "advapi32" fn RegisterServiceCtrlHandlerExW(name: [*:0]const u16, handler: HandlerEx, context: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "advapi32" fn SetServiceStatus(handle: *anyopaque, status: *SERVICE_STATUS) callconv(.winapi) BOOL;

// ole32 and oleaut32
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, init: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(class: *const GUID, outer: ?*anyopaque, context: DWORD, interface: *const GUID, object: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SysAllocString(text: [*:0]const u16) callconv(.winapi) ?[*:0]u16;
pub extern "oleaut32" fn SysFreeString(text: ?[*:0]u16) callconv(.winapi) void;
