const std = @import("std");
const cairo = @import("../../../wl/buffer/shm.zig").cairo;
const text = @import("../../../text/layout.zig");
const dw_data = @import("../../../ux/shared/desktop_widgets_data.zig");
const widget = @import("widget.zig");

// Desktop system-monitor widget.
// design: 600-wide 2x2 grid of stat cards (CPU/GPU top, MEMORY/NET bottom),
// each with a header, big-value stat rows and sparklines over 40 samples,
// fed by synchronous /proc + /sys + RAPL + NVML reads.
//
// Deviation: sampling on a background thread; here `refresh()` reads
// synchronously on the host's 1s tick. The reads are a handful of small
// sysfs/procfs files (sub-millisecond), so no worker is needed.

pub const graph_samples: usize = 40;

pub const CpuData = struct {
    temp: i32 = 0,
    freq_mhz: i32 = 0,
    usage_pct: i32 = 0,
    power_w: f64 = -1.0,
};
pub const GpuData = struct {
    temp: i32 = 0,
    vram_used_mb: i32 = 0,
    vram_total_mb: i32 = 0,
    usage_pct: i32 = 0,
    power_mw: i32 = 0,
    power_max_mw: i32 = 0,
    valid: bool = false,
};
pub const RamData = struct {
    used_mb: i32 = 0,
    total_mb: i32 = 0,
    usage_pct: i32 = 0,
    swap_used_mb: i32 = 0,
    swap_total_mb: i32 = 0,
    swap_usage_pct: i32 = 0,
};
pub const NetData = struct {
    up_kbps: f64 = 0,
    down_kbps: f64 = 0,
};

pub const Snapshot = struct {
    cpu: CpuData = .{},
    gpu: GpuData = .{},
    ram: RamData = .{},
    net: NetData = .{},
};

const Ring = struct {
    buf: [graph_samples]i32 = [_]i32{0} ** graph_samples,
    len: usize = 0,
    fn push(self: *Ring, v: i32) void {
        if (self.len < graph_samples) {
            self.buf[self.len] = v;
            self.len += 1;
        } else {
            std.mem.copyForwards(i32, self.buf[0 .. graph_samples - 1], self.buf[1..]);
            self.buf[graph_samples - 1] = v;
        }
    }
    fn slice(self: *const Ring) []const i32 {
        return self.buf[0..self.len];
    }
};

pub const State = struct {
    widget_id: []const u8 = "",
    snap: Snapshot = .{},
    cpu_usage: Ring = .{},
    cpu_temp: Ring = .{},
    cpu_clock: Ring = .{},
    cpu_power: Ring = .{},
    gpu_usage: Ring = .{},
    gpu_temp: Ring = .{},
    gpu_power_mw: Ring = .{},
    gpu_vram_mb: Ring = .{},
    gpu_vram: Ring = .{},
    gpu_power: Ring = .{},
    ram_usage: Ring = .{},
    ram_used: Ring = .{},
    swap_usage: Ring = .{},
    swap_used: Ring = .{},
    net_throughput: Ring = .{},
    net_down: Ring = .{},
    net_up: Ring = .{},
    cpu_name: [128]u8 = [_]u8{0} ** 128,
    cpu_name_len: usize = 0,
    gpu_name: [64]u8 = [_]u8{0} ** 64,
    gpu_name_len: usize = 0,
    stat_user: i64 = 0,
    stat_nice: i64 = 0,
    stat_sys: i64 = 0,
    stat_idle: i64 = 0,
    net_rx_prev: u64 = 0,
    net_tx_prev: u64 = 0,
    energy_prev: u64 = 0,
    energy_prev_ms: i64 = 0,
    energy_init: bool = false,
    nvml: Nvml = .{},
    width: i32 = 600,
    height: i32 = 180,
};

pub fn stateFromConfig(cfg: dw_data.WidgetConfig) State {
    return .{ .widget_id = cfg.id };
}

pub fn refresh(s: *State, io: std.Io) void {
    s.snap.cpu = readCpu(s, io);
    s.snap.ram = readRam(io);
    s.snap.net = readNet(s, io);
    s.snap.gpu = s.nvml.query();
    // RAPL package power from the energy delta.
    if (readEnergyUj(io)) |e_now| {
        const t_now = widget.monotonicMs();
        if (s.energy_init and e_now >= s.energy_prev) {
            const dt = (@as(f64, @floatFromInt(t_now)) - @as(f64, @floatFromInt(s.energy_prev_ms))) / 1000.0;
            if (dt > 0.05) s.snap.cpu.power_w = @as(f64, @floatFromInt(e_now - s.energy_prev)) / 1e6 / dt;
        }
        s.energy_prev = e_now;
        s.energy_prev_ms = @intCast(t_now);
        s.energy_init = true;
    } else {
        s.energy_init = false;
    }
    const cpu = s.snap.cpu;
    const gpu = s.snap.gpu;
    const ram = s.snap.ram;
    const net = s.snap.net;
    s.cpu_usage.push(cpu.usage_pct);
    s.cpu_temp.push(cpu.temp);
    s.cpu_clock.push(cpu.freq_mhz);
    if (cpu.power_w >= 0.0) s.cpu_power.push(@intFromFloat(@round(cpu.power_w * 1000.0)));
    s.gpu_usage.push(gpu.usage_pct);
    if (gpu.valid) {
        s.gpu_temp.push(gpu.temp);
        s.gpu_power_mw.push(gpu.power_mw);
        s.gpu_vram_mb.push(gpu.vram_used_mb);
    }
    s.gpu_vram.push(if (gpu.vram_total_mb > 0) std.math.clamp(@divTrunc(gpu.vram_used_mb * 100, gpu.vram_total_mb), 0, 100) else 0);
    s.gpu_power.push(if (gpu.power_max_mw > 0 and gpu.power_mw >= 0) std.math.clamp(@divTrunc(gpu.power_mw * 100, gpu.power_max_mw), 0, 100) else 0);
    s.ram_usage.push(ram.usage_pct);
    s.ram_used.push(ram.used_mb);
    s.swap_usage.push(ram.swap_usage_pct);
    s.swap_used.push(ram.swap_used_mb);
    s.net_down.push(@intFromFloat(@round(net.down_kbps)));
    s.net_up.push(@intFromFloat(@round(net.up_kbps)));
    s.net_throughput.push(@intFromFloat(@round(net.down_kbps + net.up_kbps)));
    if (s.cpu_name_len == 0) {
        const n = readCpuName(io, &s.cpu_name);
        s.cpu_name_len = n;
    }
    if (s.gpu_name_len == 0) {
        const n = s.nvml.name(&s.gpu_name);
        s.gpu_name_len = n;
    }
}

pub fn ticks(s: *const State) bool {
    _ = s;
    return true;
}

pub fn size(s: *const State) [2]i32 {
    return .{ s.width, s.height };
}

fn readFileTrim(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn readIntFile(io: std.Io, path: []const u8) i64 {
    var buf: [64]u8 = undefined;
    const s = readFileTrim(io, path, &buf) orelse return 0;
    return std.fmt.parseInt(i64, s, 10) catch 0;
}

fn readCpuTemp(io: std.Io) i32 {
    const names = [_][]const u8{ "k10temp", "coretemp", "zenpower", "cpu_thermal" };
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        var path_buf: [128]u8 = undefined;
        const name_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;
        var nb: [64]u8 = undefined;
        const sensor = readFileTrim(io, name_path, &nb) orelse continue;
        var is_cpu = false;
        for (names) |n| {
            if (std.mem.eql(u8, sensor, n)) {
                is_cpu = true;
                break;
            }
        }
        if (!is_cpu) continue;
        // Prefer Tdie (temp2) over Tctl/package (temp1) on AMD.
        const label_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/temp2_label", .{i}) catch continue;
        var lb: [32]u8 = undefined;
        if (readFileTrim(io, label_path, &lb)) |label| {
            if (std.mem.indexOf(u8, label, "Tdie") != null) {
                const p = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/temp2_input", .{i}) catch continue;
                return @intCast(@divTrunc(readIntFile(io, p), 1000));
            }
        }
        const p = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/temp1_input", .{i}) catch continue;
        return @intCast(@divTrunc(readIntFile(io, p), 1000));
    }
    return 0;
}

fn readCpu(s: *State, io: std.Io) CpuData {
    var d = CpuData{};
    d.temp = readCpuTemp(io);
    d.freq_mhz = @intCast(@divTrunc(readIntFile(io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"), 1000));
    var buf: [256]u8 = undefined;
    if (readFileTrim(io, "/proc/stat", &buf)) |line0| {
        const line = if (std.mem.indexOfScalar(u8, line0, '\n')) |nl| line0[0..nl] else line0;
        var it = std.mem.splitScalar(u8, line, ' ');
        var nums: [4]i64 = .{ 0, 0, 0, 0 };
        var ni: usize = 0;
        _ = it.next(); // "cpu"
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            if (ni >= 4) break;
            nums[ni] = std.fmt.parseInt(i64, tok, 10) catch 0;
            ni += 1;
        }
        const du = nums[0] - s.stat_user;
        const dn = nums[1] - s.stat_nice;
        const ds = nums[2] - s.stat_sys;
        const di = nums[3] - s.stat_idle;
        const total = du + dn + ds + di;
        if (s.stat_user > 0 and total > 0) d.usage_pct = @intCast(@divTrunc((du + dn + ds) * 100, total));
        s.stat_user = nums[0];
        s.stat_nice = nums[1];
        s.stat_sys = nums[2];
        s.stat_idle = nums[3];
    }
    return d;
}

fn readCpuName(io: std.Io, out: *[128]u8) usize {
    var buf: [4096]u8 = undefined;
    const content = readFileTrim(io, "/proc/cpuinfo", &buf) orelse {
        @memcpy(out[0..3], "CPU");
        return 3;
    };
    var it = std.mem.splitScalar(u8, content, '\n');
    var name: []const u8 = "CPU";
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |ci| {
                name = std.mem.trim(u8, line[ci + 1 ..], " \t");
                break;
            }
        }
    }
    var tmp: [128]u8 = undefined;
    var n: usize = @min(name.len, tmp.len);
    @memcpy(tmp[0..n], name[0..n]);
    // Strip vendor prefixes (order matters: "AMD " before Ryzen check).
    for ([_][]const u8{ "AMD ", "Intel(R) Core(TM) ", "Intel(R) " }) |pre| {
        if (std.mem.startsWith(u8, tmp[0..n], pre)) {
            std.mem.copyForwards(u8, tmp[0..], tmp[pre.len..n]);
            n -= pre.len;
            break;
        }
    }
    // "Ryzen N" -> "RN".
    if (n > 7 and std.mem.startsWith(u8, tmp[0..n], "Ryzen ") and tmp[6] >= '0' and tmp[6] <= '9') {
        tmp[1] = tmp[6];
        std.mem.copyForwards(u8, tmp[2..], tmp[7..n]);
        n -= 5;
    }
    // Strip trailing " N-Core Processor" / " N-Core".
    for ([_][]const u8{ "-Core Processor", "-Core" }) |suf| {
        if (n > suf.len + 2 and std.mem.endsWith(u8, tmp[0..n], suf) and tmp[n - suf.len - 1] >= '0' and tmp[n - suf.len - 1] <= '9') {
            var cut = n - suf.len;
            while (cut > 0 and tmp[cut - 1] >= '0' and tmp[cut - 1] <= '9') cut -= 1;
            if (cut > 0 and tmp[cut - 1] == ' ') cut -= 1;
            n = cut;
            break;
        }
    }
    // Strip trailing " CPU @ ...".
    if (std.mem.indexOf(u8, tmp[0..n], " CPU @ ")) |ci| n = ci;
    while (n > 0 and (tmp[n - 1] == ' ' or tmp[n - 1] == '\t')) n -= 1;
    if (n == 0) {
        @memcpy(out[0..3], "CPU");
        return 3;
    }
    @memcpy(out[0..n], tmp[0..n]);
    return n;
}

fn readRam(io: std.Io) RamData {
    var d = RamData{};
    var buf: [2048]u8 = undefined;
    const content = readFileTrim(io, "/proc/meminfo", &buf) orelse return d;
    var total: i64 = 0;
    var avail: i64 = 0;
    var stotal: i64 = 0;
    var sfree: i64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        var jt = std.mem.splitScalar(u8, line, ' ');
        const key = jt.next() orelse continue;
        var val: i64 = 0;
        while (jt.next()) |tok| {
            if (tok.len == 0) continue;
            val = std.fmt.parseInt(i64, tok, 10) catch 0;
            break;
        }
        if (std.mem.eql(u8, key, "MemTotal:")) total = val;
        if (std.mem.eql(u8, key, "MemAvailable:")) avail = val;
        if (std.mem.eql(u8, key, "SwapTotal:")) stotal = val;
        if (std.mem.eql(u8, key, "SwapFree:")) sfree = val;
    }
    d.total_mb = @intCast(@divTrunc(total, 1024));
    d.used_mb = @intCast(@divTrunc(total - avail, 1024));
    if (d.total_mb > 0) d.usage_pct = @intCast(@divTrunc(d.used_mb * 100, d.total_mb));
    d.swap_total_mb = @intCast(@divTrunc(stotal, 1024));
    d.swap_used_mb = @intCast(@max(@as(i64, 0), @divTrunc(stotal - sfree, 1024)));
    if (d.swap_total_mb > 0) d.swap_usage_pct = @intCast(@divTrunc(d.swap_used_mb * 100, d.swap_total_mb));
    return d;
}

fn readNet(s: *State, io: std.Io) NetData {
    var d = NetData{};
    var buf: [4096]u8 = undefined;
    const content = readFileTrim(io, "/proc/net/dev", &buf) orelse return d;
    var rx: u64 = 0;
    var tx: u64 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const ci = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..ci], " \t"), "lo")) continue;
        var jt = std.mem.splitScalar(u8, line[ci + 1 ..], ' ');
        var nums: [16]u64 = [_]u64{0} ** 16;
        var ni: usize = 0;
        while (jt.next()) |tok| {
            if (tok.len == 0) continue;
            if (ni >= 16) break;
            nums[ni] = std.fmt.parseInt(u64, tok, 10) catch 0;
            ni += 1;
        }
        if (ni < 9) continue;
        rx += nums[0];
        tx += nums[8];
    }
    if (s.net_rx_prev > 0) {
        d.down_kbps = @as(f64, @floatFromInt(rx -| s.net_rx_prev)) / 1024.0;
        d.up_kbps = @as(f64, @floatFromInt(tx -| s.net_tx_prev)) / 1024.0;
    }
    s.net_rx_prev = rx;
    s.net_tx_prev = tx;
    return d;
}

fn readEnergyUj(io: std.Io) ?u64 {
    for ([_][]const u8{
        "/sys/class/powercap/intel-rapl:0/energy_uj",
        "/sys/class/powercap/intel-rapl:0:0/energy_uj",
    }) |path| {
        var buf: [32]u8 = undefined;
        if (readFileTrim(io, path, &buf)) |st| {
            if (std.fmt.parseInt(u64, st, 10)) |v| return v else |_| {}
        }
    }
    return null;
}

const Nvml = struct {
    lib: ?std.DynLib = null,
    handle: usize = 0,
    ready: bool = false,
    name_buf: [64]u8 = [_]u8{0} ** 64,

    const NVML_SUCCESS: c_int = 0;
    const NVML_TEMPERATURE_GPU: c_uint = 0;

    fn sym(self: *Nvml, sym_name: [:0]const u8) ?*anyopaque {
        const lib = &(self.lib orelse return null);
        return lib.lookup(*anyopaque, sym_name);
    }

    fn ensure(self: *Nvml) bool {
        if (self.ready) return true;
        if (self.lib != null) return false;
        var lib = std.DynLib.open("libnvidia-ml.so") catch
            std.DynLib.open("libnvidia-ml.so.1") catch return false;
        const need = [_][:0]const u8{
            "nvmlInit", "nvmlShutdown", "nvmlDeviceGetHandleByIndex",
            "nvmlDeviceGetTemperature", "nvmlDeviceGetMemoryInfo",
            "nvmlDeviceGetUtilizationRates",
        };
        for (need) |n| {
            if (lib.lookup(*anyopaque, n) == null) {
                lib.close();
                return false;
            }
        }
        self.lib = lib;
        const init: *const fn () callconv(.c) c_int = @ptrCast(self.sym("nvmlInit") orelse return false);
        if (init() != NVML_SUCCESS) {
            self.lib = null;
            lib.close();
            return false;
        }
        const get_handle: *const fn (c_uint, *usize) callconv(.c) c_int = @ptrCast(self.sym("nvmlDeviceGetHandleByIndex") orelse return false);
        var h: usize = 0;
        if (get_handle(0, &h) != NVML_SUCCESS) {
            const shut: *const fn () callconv(.c) c_int = @ptrCast(self.sym("nvmlShutdown") orelse return false);
            _ = shut();
            self.lib = null;
            lib.close();
            return false;
        }
        self.handle = h;
        self.ready = true;
        return true;
    }

    fn name(self: *Nvml, out: *[64]u8) usize {
        if (!self.ensure()) {
            @memcpy(out[0..3], "GPU");
            return 3;
        }
        const get_name: *const fn (usize, [*]u8, c_uint) callconv(.c) c_int = @ptrCast(self.sym("nvmlDeviceGetName") orelse {
            @memcpy(out[0..3], "GPU");
            return 3;
        });
        var buf: [64]u8 = [_]u8{0} ** 64;
        if (get_name(self.handle, &buf, 64) != NVML_SUCCESS) {
            @memcpy(out[0..3], "GPU");
            return 3;
        }
        const raw = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
        var n: usize = @min(raw.len, 63);
        @memcpy(out[0..n], raw[0..n]);
        for ([_][]const u8{ "NVIDIA GeForce ", "AMD Radeon ", "AMD Radeon(TM) " }) |pre| {
            if (std.mem.startsWith(u8, out[0..n], pre)) {
                std.mem.copyForwards(u8, out[0..], out[pre.len..n]);
                n -= pre.len;
                break;
            }
        }
        return n;
    }

    fn query(self: *Nvml) GpuData {
        var d = GpuData{};
        if (!self.ensure()) return d;
        const get_temp: *const fn (usize, c_uint, *c_uint) callconv(.c) c_int = @ptrCast(self.sym("nvmlDeviceGetTemperature") orelse return d);
        const get_mem: *const fn (usize, *NvmlMemory) callconv(.c) c_int = @ptrCast(self.sym("nvmlDeviceGetMemoryInfo") orelse return d);
        const get_util: *const fn (usize, *NvmlUtil) callconv(.c) c_int = @ptrCast(self.sym("nvmlDeviceGetUtilizationRates") orelse return d);
        var temp: c_uint = 0;
        if (get_temp(self.handle, NVML_TEMPERATURE_GPU, &temp) == NVML_SUCCESS) d.temp = @intCast(temp);
        var mem: NvmlMemory = .{};
        if (get_mem(self.handle, &mem) == NVML_SUCCESS) {
            d.vram_used_mb = @intCast(mem.used / (1024 * 1024));
            d.vram_total_mb = @intCast(mem.total / (1024 * 1024));
        }
        var util: NvmlUtil = .{};
        if (get_util(self.handle, &util) == NVML_SUCCESS) d.usage_pct = @intCast(util.gpu);
        if (self.sym("nvmlDeviceGetPowerUsage")) |p| {
            const get_power: *const fn (usize, *c_uint) callconv(.c) c_int = @ptrCast(p);
            var mw: c_uint = 0;
            if (get_power(self.handle, &mw) == NVML_SUCCESS) d.power_mw = @intCast(mw);
        }
        if (self.sym("nvmlDeviceGetEnforcedPowerLimit")) |p| {
            const get_lim: *const fn (usize, *c_uint) callconv(.c) c_int = @ptrCast(p);
            var mw: c_uint = 0;
            if (get_lim(self.handle, &mw) == NVML_SUCCESS) d.power_max_mw = @intCast(mw);
        }
        d.valid = true;
        return d;
    }

    const NvmlMemory = extern struct {
        total: c_ulonglong = 0,
        free: c_ulonglong = 0,
        used: c_ulonglong = 0,
    };
    const NvmlUtil = extern struct {
        gpu: c_uint = 0,
        memory: c_uint = 0,
    };
};

const cpu_blue = [3]f64{ 0.3, 0.7, 1.0 };
const gpu_green = [3]f64{ 0.2, 0.9, 0.5 };
const temp_red = [3]f64{ 1.0, 0.38, 0.35 };
const power_orange = [3]f64{ 1.0, 0.45, 0.25 };
const clock_cyan = [3]f64{ 0.3, 0.9, 0.9 };
const vram_purple = [3]f64{ 0.8, 0.5, 1.0 };
const ram_orange = [3]f64{ 1.0, 0.7, 0.2 };
const swap_pink = [3]f64{ 1.0, 0.35, 0.55 };

const stat_pad_l: f64 = 8.0;
const stat_pad_t: f64 = 8.0;
const stat_pad_b: f64 = 8.0;
const stat_header_h: f64 = 18.0;
const stat_row_h: f64 = 40.0;
const stat_spark_h: f64 = 24.0;

fn cardBackground(c: ?*cairo.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64, alpha: f64, bg_r: f64, bg_g: f64, bg_b: f64) void {
    const cr = c orelse return;
    cairo.cairo_save(cr);
    widget.roundRect(cr, x, y + 2.0, w, h, radius);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.22);
    cairo.cairo_fill(cr);
    cairo.cairo_restore(cr);
    widget.roundRect(cr, x, y, w, h, radius);
    cairo.cairo_set_source_rgba(cr, bg_r * 0.55, bg_g * 0.55, bg_b * 0.55, alpha);
    cairo.cairo_fill_preserve(cr);
    cairo.cairo_save(cr);
    widget.roundRect(cr, x, y, w, h, radius);
    cairo.cairo_clip(cr);
    const sheen = cairo.cairo_pattern_create_linear(0, y, 0, y + h * 0.45);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 0.0, 1, 1, 1, 0.13 * alpha);
    cairo.cairo_pattern_add_color_stop_rgba(sheen, 1.0, 1, 1, 1, 0.0);
    cairo.cairo_set_source(cr, sheen);
    cairo.cairo_rectangle(cr, x, y, w, h * 0.45);
    cairo.cairo_fill(cr);
    cairo.cairo_pattern_destroy(sheen);
    cairo.cairo_restore(cr);
    const rim = cairo.cairo_pattern_create_linear(0, y, 0, y + h);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.0, 1, 1, 1, 0.38 * alpha);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.35, 1, 1, 1, 0.14 * alpha);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 0.7, 1, 1, 1, 0.05 * alpha);
    cairo.cairo_pattern_add_color_stop_rgba(rim, 1.0, 1, 1, 1, 0.12 * alpha);
    cairo.cairo_set_source(cr, rim);
    cairo.cairo_set_line_width(cr, 1.0);
    widget.roundRect(cr, x + 1.0, y + 1.0, w - 2.0, h - 2.0, radius - 1.0);
    cairo.cairo_stroke(cr);
    cairo.cairo_pattern_destroy(rim);
    cairo.cairo_set_source_rgba(cr, 0, 0, 0, 0.25);
    cairo.cairo_set_line_width(cr, 1.0);
    widget.roundRect(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0, radius);
    cairo.cairo_stroke(cr);
}

fn paintGraph(c: ?*cairo.cairo_t, left: f64, top: f64, w: f64, h: f64, data: []const i32, filled: bool, color: [3]f64, d2: ?[]const i32, c2: ?[3]f64, d3: ?[]const i32, c3: ?[3]f64, fill_primary: bool) void {
    const cr = c orelse return;
    if (w <= 10.0 or h <= 4.0 or data.len < 2) return;
    cairo.cairo_save(cr);
    cairo.cairo_rectangle(cr, left, top, w, h);
    cairo.cairo_clip(cr);
    var min_v: i32 = 0;
    var max_v: i32 = 100;
    if (!filled) {
        min_v = data[0];
        max_v = data[0];
        for (data) |v| {
            if (v < min_v) min_v = v;
            if (v > max_v) max_v = v;
        }
        const expand = struct {
            fn f(dq: ?[]const i32, mn: *i32, mx: *i32) void {
                const d = dq orelse return;
                if (d.len < 2) return;
                for (d) |v| {
                    if (v < mn.*) mn.* = v;
                    if (v > mx.*) mx.* = v;
                }
            }
        }.f;
        expand(d2, &min_v, &max_v);
        expand(d3, &min_v, &max_v);
        if (max_v <= min_v) max_v = min_v + 1;
    }
    const step_x = w / @as(f64, @floatFromInt(graph_samples - 1));
    const pad = 2.0;
    const inner_h = h - pad * 2.0;
    const span: f64 = @max(1.0, @as(f64, @floatFromInt(max_v - min_v)));
    const vy = struct {
        fn f(val: i32, mn: i32, sp: f64, t: f64, ih: f64, p: f64) f64 {
            var v = (@as(f64, @floatFromInt(val - mn))) / sp;
            if (v < 0.0) v = 0.0;
            if (v > 1.0) v = 1.0;
            return t + p + ih - v * ih;
        }
    }.f;
    if (fill_primary) {
        cairo.cairo_move_to(cr, left, top + h);
        for (data, 0..) |v, i| {
            cairo.cairo_line_to(cr, left + @as(f64, @floatFromInt(i)) * step_x, vy(v, min_v, span, top, inner_h, pad));
        }
        cairo.cairo_line_to(cr, left + @as(f64, @floatFromInt(data.len - 1)) * step_x, top + h);
        cairo.cairo_close_path(cr);
        cairo.cairo_set_source_rgba(cr, color[0], color[1], color[2], 0.18);
        cairo.cairo_fill(cr);
    }
    cairo.cairo_set_source_rgba(cr, color[0], color[1], color[2], 0.9);
    cairo.cairo_set_line_width(cr, 1.5);
    for (data, 0..) |v, i| {
        const px = left + @as(f64, @floatFromInt(i)) * step_x;
        const py = vy(v, min_v, span, top, inner_h, pad);
        if (i == 0) cairo.cairo_move_to(cr, px, py) else cairo.cairo_line_to(cr, px, py);
    }
    cairo.cairo_stroke(cr);
    const stroke2 = struct {
        fn f(cr2: ?*cairo.cairo_t, dq: ?[]const i32, col: ?[3]f64, l: f64, t: f64, mn: i32, sp: f64, ih: f64, p: f64, sx: f64) void {
            const d = dq orelse return;
            const cc = col orelse return;
            if (d.len < 2) return;
            const cx = cr2 orelse return;
            cairo.cairo_set_source_rgba(cx, cc[0], cc[1], cc[2], 0.9);
            cairo.cairo_set_line_width(cx, 1.5);
            for (d, 0..) |v, i| {
                var vv = (@as(f64, @floatFromInt(v - mn))) / sp;
                if (vv < 0.0) vv = 0.0;
                if (vv > 1.0) vv = 1.0;
                const px = l + @as(f64, @floatFromInt(i)) * sx;
                const py = t + p + ih - vv * ih;
                if (i == 0) cairo.cairo_move_to(cx, px, py) else cairo.cairo_line_to(cx, px, py);
            }
            cairo.cairo_stroke(cx);
        }
    }.f;
    stroke2(c, d2, c2, left, top, min_v, span, inner_h, pad, step_x);
    stroke2(c, d3, c3, left, top, min_v, span, inner_h, pad, step_x);
    cairo.cairo_restore(cr);
}

fn shadowed(c: ?*cairo.cairo_t, desc: []const u8, str: []const u8, x: f64, y: f64, r: f64, g: f64, b: f64, a: f64) [2]i32 {
    var l = widget.makeLine(c, desc, str);
    defer l.destroy();
    const px = l.pixelSize();
    widget.showShadowed(c, &l, x, y, r, g, b, a);
    return .{ px.w, px.h };
}

fn measure(c: ?*cairo.cairo_t, desc: []const u8, str: []const u8) [2]i32 {
    var l = widget.makeLine(c, desc, str);
    defer l.destroy();
    const px = l.pixelSize();
    return .{ px.w, px.h };
}

fn truncFit(c: ?*cairo.cairo_t, alloc: std.mem.Allocator, desc: []const u8, str: []const u8, max_w: f64) []const u8 {
    if (@as(f64, @floatFromInt(measure(c, desc, str)[0])) <= max_w) return str;
    var n = str.len;
    while (n > 4) {
        n -= 1;
        while (n > 0 and (str[n] & 0xC0) == 0x80) n -= 1;
        const cand = std.fmt.allocPrint(alloc, "{s}…", .{str[0..n]}) catch break;
        if (@as(f64, @floatFromInt(measure(c, desc, cand)[0])) <= max_w) return cand;
    }
    return str[0..@min(n, str.len)];
}

const StatRow = struct {
    label: []const u8,
    value: []const u8,
    unit: []const u8,
    color: [3]f64,
    history: ?[]const i32,
};

fn statCardHeight(rows: usize) i32 {
    return @as(i32, @intCast(8 + 18 + 6)) + @as(i32, @intCast(rows)) * 40 + 8;
}

fn paintStatCard(
    c: ?*cairo.cairo_t,
    alloc: std.mem.Allocator,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    title: []const u8,
    title_value: []const u8,
    title_unit: []const u8,
    title_color: ?[3]f64,
    rows: []const StatRow,
    alpha: f64,
    bg_r: f64,
    bg_g: f64,
    bg_b: f64,
    tx_r: f64,
    tx_g: f64,
    tx_b: f64,
) void {
    const cr = c orelse return;
    cairo.cairo_save(cr);
    cardBackground(c, x, y, w, h, 15.0, alpha, bg_r, bg_g, bg_b);
    var right_reserve: f64 = 0.0;
    if (title_color != null and title_value.len > 0) {
        const tv_w = measure(c, "Inter Bold 12", title_value)[0];
        const tu_w = measure(c, "Inter 9", title_unit)[0];
        right_reserve = @as(f64, @floatFromInt(tv_w + 3 + tu_w));
        _ = shadowed(c, "Inter Bold 12", title_value, x + w - stat_pad_l - right_reserve, y + stat_pad_t, title_color.?[0], title_color.?[1], title_color.?[2], 0.95);
        _ = shadowed(c, "Inter 9", title_unit, x + w - stat_pad_l - @as(f64, @floatFromInt(tu_w)), y + stat_pad_t + 3.0, tx_r, tx_g, tx_b, 0.6);
    }
    const gap_extra: f64 = if (right_reserve > 0) 8.0 else 0.0;
    const t = truncFit(c, alloc, "Inter Bold 10", title, w - 2 * stat_pad_l - right_reserve - gap_extra);
    _ = shadowed(c, "Inter Bold 10", t, x + stat_pad_l, y + stat_pad_t, tx_r, tx_g, tx_b, 0.7);
    const content_top = y + stat_pad_t + stat_header_h + 6.0;

    var max_text_w: f64 = 0.0;
    for (rows) |row| {
        const vw = measure(c, "Inter Bold 15", row.value)[0];
        const uw = measure(c, "Inter 10", row.unit)[0];
        max_text_w = @max(max_text_w, @as(f64, @floatFromInt(vw + 3 + uw)));
    }
    const spark_right = x + w - stat_pad_l;
    var spark_x = x + stat_pad_l + max_text_w + 10.0;
    if (spark_right - spark_x < 80.0) spark_x = spark_right - 80.0;
    const spark_w = spark_right - spark_x;
    const text_w = spark_x - 10.0 - (x + stat_pad_l);

    cairo.cairo_set_source_rgba(cr, tx_r, tx_g, tx_b, 0.07);
    cairo.cairo_set_line_width(cr, 1.0);
    for (rows, 0..) |_, i| {
        const ly = content_top + @as(f64, @floatFromInt(i)) * stat_row_h;
        cairo.cairo_move_to(cr, x + stat_pad_l, ly + 0.5);
        cairo.cairo_line_to(cr, x + w - stat_pad_l, ly + 0.5);
    }
    cairo.cairo_stroke(cr);

    for (rows, 0..) |row, i| {
        const rt = content_top + @as(f64, @floatFromInt(i)) * stat_row_h;
        _ = shadowed(c, "Inter 9", row.label, x + stat_pad_l, rt + 2.0, tx_r, tx_g, tx_b, 0.55);
        var big_desc: []const u8 = "Inter Bold 15";
        var vw = measure(c, big_desc, row.value)[0];
        const vh = measure(c, big_desc, row.value)[1];
        const uw = measure(c, "Inter 10", row.unit)[0];
        const uh = measure(c, "Inter 10", row.unit)[1];
        if (@as(f64, @floatFromInt(vw + 3 + uw)) > text_w) {
            big_desc = "Inter Bold 13";
            vw = measure(c, big_desc, row.value)[0];
        }
        const value_y = rt + 13.0;
        _ = shadowed(c, big_desc, row.value, x + stat_pad_l, value_y, row.color[0], row.color[1], row.color[2], 0.95);
        _ = shadowed(c, "Inter 10", row.unit, x + stat_pad_l + @as(f64, @floatFromInt(vw)) + 3.0, value_y + (@as(f64, @floatFromInt(vh)) - @as(f64, @floatFromInt(uh))), tx_r, tx_g, tx_b, 0.6);
        if (row.history) |hist| {
            if (hist.len >= 2) {
                paintGraph(c, spark_x, rt + (stat_row_h - stat_spark_h) / 2.0, spark_w, stat_spark_h, hist, false, row.color, null, null, null, null, false);
            }
        }
    }
    cairo.cairo_restore(cr);
}

pub fn paint(s: *State, cr: ?*cairo.cairo_t, ctx: widget.Ctx) void {
    const c = cr orelse return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const snap = s.snap;
    const card_gap: f64 = 8.0;
    const cw: f64 = (@as(f64, @floatFromInt(s.width)) - card_gap) / 2.0;

    var clock_buf: [32]u8 = undefined;
    const clock_txt = std.fmt.bufPrint(&clock_buf, "{d}.{d}", .{ @divTrunc(snap.cpu.freq_mhz, 1000), @divTrunc(@mod(snap.cpu.freq_mhz, 1000), 100) }) catch "?";

    var cpu_rows: std.ArrayListUnmanaged(StatRow) = .empty;
    cpu_rows.append(alloc, .{ .label = "USAGE", .value = std.fmt.allocPrint(alloc, "{d}", .{snap.cpu.usage_pct}) catch "?", .unit = " %", .color = cpu_blue, .history = s.cpu_usage.slice() }) catch {};
    cpu_rows.append(alloc, .{ .label = "TEMP", .value = std.fmt.allocPrint(alloc, "{d}", .{snap.cpu.temp}) catch "?", .unit = " °C", .color = temp_red, .history = s.cpu_temp.slice() }) catch {};
    if (snap.cpu.power_w >= 0.0) {
        cpu_rows.append(alloc, .{ .label = "POWER", .value = std.fmt.allocPrint(alloc, "{d:.0}", .{snap.cpu.power_w}) catch "?", .unit = " W", .color = power_orange, .history = s.cpu_power.slice() }) catch {};
    } else {
        cpu_rows.append(alloc, .{ .label = "POWER", .value = "--", .unit = " W", .color = power_orange, .history = null }) catch {};
    }
    cpu_rows.append(alloc, .{ .label = "CLOCK", .value = clock_txt, .unit = " GHz", .color = clock_cyan, .history = s.cpu_clock.slice() }) catch {};

    const gv = snap.gpu.valid;
    var gpu_rows: std.ArrayListUnmanaged(StatRow) = .empty;
    gpu_rows.append(alloc, .{ .label = "USAGE", .value = if (gv) std.fmt.allocPrint(alloc, "{d}", .{snap.gpu.usage_pct}) catch "?" else "--", .unit = " %", .color = gpu_green, .history = s.gpu_usage.slice() }) catch {};
    gpu_rows.append(alloc, .{ .label = "TEMP", .value = if (gv) std.fmt.allocPrint(alloc, "{d}", .{snap.gpu.temp}) catch "?" else "--", .unit = " °C", .color = temp_red, .history = s.gpu_temp.slice() }) catch {};
    var gpu_power_unit_buf: [32]u8 = undefined;
    const gpu_power_unit: []const u8 = if (gv and snap.gpu.power_max_mw > 0)
        std.fmt.bufPrint(&gpu_power_unit_buf, "/ {d} W", .{@divTrunc(snap.gpu.power_max_mw, 1000)}) catch " W"
    else
        " W";
    gpu_rows.append(alloc, .{ .label = "POWER", .value = if (gv) std.fmt.allocPrint(alloc, "{d}", .{@divTrunc(snap.gpu.power_mw, 1000)}) catch "?" else "--", .unit = gpu_power_unit, .color = power_orange, .history = s.gpu_power_mw.slice() }) catch {};
    var vram_unit_buf: [32]u8 = undefined;
    const vram_unit: []const u8 = if (gv and snap.gpu.vram_total_mb > 0)
        std.fmt.bufPrint(&vram_unit_buf, "/ {d:.1} GB", .{@as(f64, @floatFromInt(snap.gpu.vram_total_mb)) / 1024.0}) catch "GB"
    else
        "GB";
    gpu_rows.append(alloc, .{ .label = "VRAM", .value = if (gv) std.fmt.allocPrint(alloc, "{d:.1}", .{@as(f64, @floatFromInt(snap.gpu.vram_used_mb)) / 1024.0}) catch "?" else "--", .unit = vram_unit, .color = vram_purple, .history = s.gpu_vram_mb.slice() }) catch {};

    var mem_rows: std.ArrayListUnmanaged(StatRow) = .empty;
    var ram_unit_buf: [48]u8 = undefined;
    const ram_unit = std.fmt.bufPrint(&ram_unit_buf, "/ {d:.1} GB", .{@as(f64, @floatFromInt(snap.ram.total_mb)) / 1024.0}) catch "GB";
    mem_rows.append(alloc, .{ .label = "RAM", .value = std.fmt.allocPrint(alloc, "{d:.1}", .{@as(f64, @floatFromInt(snap.ram.used_mb)) / 1024.0}) catch "?", .unit = ram_unit, .color = ram_orange, .history = s.ram_used.slice() }) catch {};
    mem_rows.append(alloc, .{ .label = "SWAP", .value = std.fmt.allocPrint(alloc, "{d:.1}", .{@as(f64, @floatFromInt(snap.ram.swap_used_mb)) / 1024.0}) catch "?", .unit = " GB used", .color = swap_pink, .history = s.swap_used.slice() }) catch {};
    const ram_pct = std.fmt.allocPrint(alloc, "{d}", .{snap.ram.usage_pct}) catch "?";

    const down_pair = fmtRate(alloc, snap.net.down_kbps) catch [_][]const u8{ "?", " KB/s" };
    const up_pair = fmtRate(alloc, snap.net.up_kbps) catch [_][]const u8{ "?", " KB/s" };
    var net_rows: std.ArrayListUnmanaged(StatRow) = .empty;
    net_rows.append(alloc, .{ .label = "DOWN", .value = down_pair[0], .unit = down_pair[1], .color = clock_cyan, .history = s.net_down.slice() }) catch {};
    net_rows.append(alloc, .{ .label = "UP", .value = up_pair[0], .unit = up_pair[1], .color = vram_purple, .history = s.net_up.slice() }) catch {};

    const top_h = @max(statCardHeight(cpu_rows.items.len), statCardHeight(gpu_rows.items.len));
    const bot_h = @max(statCardHeight(mem_rows.items.len), statCardHeight(net_rows.items.len));
    s.height = top_h + @as(i32, @intFromFloat(card_gap)) + bot_h;

    const alpha = ctx.overlay_widget_card;
    const bg_r = ctx.drawer_r;
    const bg_g = ctx.drawer_g;
    const bg_b = ctx.drawer_b;
    const tx_r = ctx.text_r;
    const tx_g = ctx.text_g;
    const tx_b = ctx.text_b;

    var title_buf: [160]u8 = undefined;
    const cpu_title = std.fmt.bufPrint(&title_buf, "CPU · {s}", .{s.cpu_name[0..s.cpu_name_len]}) catch "CPU";
    var gpu_title_buf: [96]u8 = undefined;
    const gpu_title = std.fmt.bufPrint(&gpu_title_buf, "GPU · {s}", .{s.gpu_name[0..s.gpu_name_len]}) catch "GPU";
    paintStatCard(c, alloc, 0, 0, cw, @floatFromInt(top_h), cpu_title, clock_txt, " GHz", clock_cyan, cpu_rows.items, alpha, bg_r, bg_g, bg_b, tx_r, tx_g, tx_b);
    paintStatCard(c, alloc, cw + card_gap, 0, cw, @floatFromInt(top_h), gpu_title, "", "", null, gpu_rows.items, alpha, bg_r, bg_g, bg_b, tx_r, tx_g, tx_b);
    paintStatCard(c, alloc, 0, @floatFromInt(top_h + @as(i32, @intFromFloat(card_gap))), cw, @floatFromInt(bot_h), "MEMORY", ram_pct, " %", ram_orange, mem_rows.items, alpha, bg_r, bg_g, bg_b, tx_r, tx_g, tx_b);
    paintStatCard(c, alloc, cw + card_gap, @floatFromInt(top_h + @as(i32, @intFromFloat(card_gap))), cw, @floatFromInt(bot_h), "NET", "", "", null, net_rows.items, alpha, bg_r, bg_g, bg_b, tx_r, tx_g, tx_b);
}

fn fmtRate(alloc: std.mem.Allocator, kbps: f64) ![2][]const u8 {
    if (kbps >= 1000.0) {
        return .{ try std.fmt.allocPrint(alloc, "{d:.1}", .{kbps / 1024.0}), try alloc.dupe(u8, " MB/s") };
    }
    return .{ try std.fmt.allocPrint(alloc, "{d:.0}", .{kbps}), try alloc.dupe(u8, " KB/s") };
}

test "settings-desktop-sysmon: sensors read without crashing" {
    const t = std.testing;
    var s = State{};
    refresh(&s, std.testing.io);
    try t.expect(s.cpu_name_len > 0);
    try t.expect(s.snap.ram.total_mb >= 0);
}
