const std = @import("std");

/// A Wayland protocol we compile a client binding for.
const Protocol = struct {
    name: []const u8,
    xml: []const u8,
    /// True when the XML comes from the system `wayland-protocols` package.
    /// False means it is vendored under `protocols/`.
    system: bool = false,
};

const protocols = [_]Protocol{
    .{ .name = "xdg-shell", .xml = "stable/xdg-shell/xdg-shell.xml", .system = true },
    .{ .name = "xdg-output-unstable-v1", .xml = "unstable/xdg-output/xdg-output-unstable-v1.xml", .system = true },
    .{ .name = "ext-session-lock-v1", .xml = "staging/ext-session-lock/ext-session-lock-v1.xml", .system = true },
    .{ .name = "idle-inhibit-unstable-v1", .xml = "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml", .system = true },
    .{ .name = "xdg-activation-v1", .xml = "staging/xdg-activation/xdg-activation-v1.xml", .system = true },
    .{ .name = "ext-idle-notify-v1", .xml = "staging/ext-idle-notify/ext-idle-notify-v1.xml", .system = true },
    .{ .name = "ext-data-control-v1", .xml = "staging/ext-data-control/ext-data-control-v1.xml", .system = true },
    .{ .name = "ext-foreign-toplevel-list-v1", .xml = "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml", .system = true },
    .{ .name = "ext-workspace-v1", .xml = "staging/ext-workspace/ext-workspace-v1.xml", .system = true },
    .{ .name = "ext-image-copy-capture-v1", .xml = "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml", .system = true },
    .{ .name = "ext-image-capture-source-v1", .xml = "staging/ext-image-capture-source/ext-image-capture-source-v1.xml", .system = true },
    // Vendored extensions. Some compositors ship these, but not all do, and
    // the versions we bind against are the ones the shell is tested with.
    .{ .name = "wlr-gamma-control-unstable-v1", .xml = "protocols/wlr-gamma-control-unstable-v1.xml" },
    .{ .name = "wlr-data-control-unstable-v1", .xml = "protocols/wlr-data-control-unstable-v1.xml" },
    .{ .name = "virtual-keyboard-unstable-v1", .xml = "protocols/virtual-keyboard-unstable-v1.xml" },
    .{ .name = "wlr-layer-shell-unstable-v1", .xml = "protocols/wlr-layer-shell-unstable-v1.xml" },
    .{ .name = "wlr-foreign-toplevel-management-unstable-v1", .xml = "protocols/wlr-foreign-toplevel-management-unstable-v1.xml" },
    .{ .name = "dwl-ipc-unstable-v2", .xml = "protocols/dwl-ipc-unstable-v2.xml" },
    .{ .name = "hyprland-toplevel-export-v1", .xml = "protocols/hyprland-toplevel-export-v1.xml" },
    .{ .name = "hyprland-focus-grab-v1", .xml = "protocols/hyprland-focus-grab-v1.xml" },
    .{ .name = "wlr-screencopy-unstable-v1", .xml = "protocols/wlr-screencopy-unstable-v1.xml" },
};

/// Options that differ between the shell library and its standalone
/// processes. Everything defaults to the common case: a Zig module that
/// links the shared Wayland/Cairo stack and gets protocol bindings and
/// fixtures from the library module.
const ModuleOptions = struct {
    /// Link Pango/Cairo for text layout. Components that import `eh` already
    /// inherit it, but standalone roots need it explicitly.
    pango: bool = false,
    /// Compile the generated protocol C sources and the vendored stb C
    /// implementation into this module.
    c_sources: bool = false,
    /// Link PipeWire. Required by the Audio Center and the tests.
    pipewire: bool = false,
};

const Binary = struct {
    name: []const u8,
    root: []const u8,
    step: []const u8,
    description: []const u8,
    options: ModuleOptions = .{},
    /// Import the shared `eh` module after creating this module.
    imports_eh: bool = false,
};

const binaries = [_]Binary{
    .{
        .name = "horizon-wallpaper",
        .root = "src/bin/wallpaper.zig",
        .step = "wallpaper",
        .description = "Build only horizon-wallpaper",
        .imports_eh = true,
    },
    .{
        .name = "horizon-dock",
        .root = "src/bin/dock.zig",
        .step = "dock",
        .description = "Build only horizon-dock",
        .imports_eh = true,
    },
    .{
        .name = "horizon-settings",
        .root = "src/bin/settings2.zig",
        .step = "settings2",
        .description = "Build only horizon-settings",
        .options = .{ .pango = true },
        .imports_eh = true,
    },
    .{
        .name = "horizon-audio-center",
        .root = "src/bin/audio_center.zig",
        .step = "audio-center",
        .description = "Build only horizon-audio-center",
        .options = .{ .pango = true, .pipewire = true },
        .imports_eh = true,
    },
    .{
        .name = "horizon-overview",
        .root = "src/overview_bin.zig",
        .step = "overview",
        .description = "Build only horizon-overview",
        .options = .{ .pango = true, .c_sources = true },
    },
    .{
        .name = "horizon-desktop-widgets",
        .root = "src/bin/desktop_widgets.zig",
        .step = "desktop-widgets",
        .description = "Build only horizon-desktop-widgets",
        .imports_eh = true,
    },
    .{
        .name = "horizon-notifications",
        .root = "src/notifications_bin.zig",
        .step = "notifications",
        .description = "Build only horizon-notifications",
        .options = .{ .c_sources = true },
    },
    .{
        .name = "horizon-polkit-agent",
        .root = "src/polkit_agent_bin.zig",
        .step = "polkit-agent",
        .description = "Build only horizon-polkit-agent",
        .options = .{ .pango = true, .c_sources = true },
    },
    .{
        .name = "horizon-taskbar",
        .root = "src/bin/taskbar.zig",
        .step = "taskbar",
        .description = "Build only horizon-taskbar",
        .imports_eh = true,
    },
    .{
        .name = "horizon-desktop",
        .root = "src/bin/desktop.zig",
        .step = "desktop",
        .description = "Build only horizon-desktop",
        .imports_eh = true,
    },
    .{
        .name = "horizonClipboardDaemon",
        .root = "src/bin/clipboard.zig",
        .step = "clipboard",
        .description = "Build only horizonClipboardDaemon",
        .imports_eh = true,
    },
    .{
        .name = "horizon-clipstack",
        .root = "src/bin/clipstack.zig",
        .step = "clipstack",
        .description = "Build only horizon-clipstack",
        .imports_eh = true,
    },
    .{
        .name = "horizon-clipstack-pick",
        .root = "src/bin/clipstack_pick.zig",
        .step = "clipstack-pick",
        .description = "Build only horizon-clipstack-pick",
        .options = .{ .pango = true },
        .imports_eh = true,
    },
};

/// Ask pkg-config for one module and apply its include paths and libraries
/// to a Zig module. This is the only place the build assumes a Unix host.
fn addPkgConfig(b: *std.Build, mod: *std.Build.Module, package: []const u8) void {
    const cflags = b.run(&.{ "pkg-config", "--cflags", package });
    var it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I") and flag.len > 2) {
            mod.addIncludePath(.{ .cwd_relative = b.dupe(flag[2..]) });
        } else if (std.mem.eql(u8, flag, "-pthread")) {
            mod.linkSystemLibrary("pthread", .{});
        }
    }

    const libs = b.run(&.{ "pkg-config", "--libs", package });
    it = std.mem.tokenizeAny(u8, libs, " \t\r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-L") and flag.len > 2) {
            mod.addLibraryPath(.{ .cwd_relative = b.dupe(flag[2..]) });
        } else if (std.mem.startsWith(u8, flag, "-l") and flag.len > 2) {
            mod.linkSystemLibrary(flag[2..], .{});
        } else if (std.mem.eql(u8, flag, "-pthread")) {
            mod.linkSystemLibrary("pthread", .{});
        }
    }
}

fn linkShellLibraries(b: *std.Build, mod: *std.Build.Module, options: ModuleOptions) void {
    addPkgConfig(b, mod, "wayland-client");
    addPkgConfig(b, mod, "xkbcommon");
    addPkgConfig(b, mod, "cairo");
    // librsvg-2.0's pkg-config name is not the linker name (`rsvg-2`), so
    // resolve it through pkg-config rather than guessing `-l`.
    addPkgConfig(b, mod, "librsvg-2.0");
    addPkgConfig(b, mod, "libwebp");
    if (options.pango) addPkgConfig(b, mod, "pangocairo");
    if (options.pipewire) addPkgConfig(b, mod, "libpipewire-0.3");
}

fn genProtocol(
    b: *std.Build,
    spec: Protocol,
    wayland_protocols_dir: []const u8,
) struct { header: std.Build.LazyPath, code: std.Build.LazyPath } {
    const xml: std.Build.LazyPath = if (spec.system)
        .{ .cwd_relative = b.pathJoin(&.{ wayland_protocols_dir, spec.xml }) }
    else
        b.path(spec.xml);

    const header_cmd = b.addSystemCommand(&.{"wayland-scanner"});
    header_cmd.addArg("client-header");
    header_cmd.addFileArg(xml);
    const header = header_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{spec.name}));

    const code_cmd = b.addSystemCommand(&.{"wayland-scanner"});
    code_cmd.addArg("private-code");
    code_cmd.addFileArg(xml);
    const code = code_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.c", .{spec.name}));

    return .{ .header = header, .code = code };
}

fn shellModule(
    b: *std.Build,
    root_src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    protocol_codes: []const std.Build.LazyPath,
    protocol_includes: []const std.Build.LazyPath,
    options: ModuleOptions,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_src),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    linkShellLibraries(b, mod, options);

    for (protocol_includes) |include| mod.addIncludePath(include);
    if (options.c_sources) {
        for (protocol_codes) |code| {
            mod.addCSourceFile(.{ .file = code, .flags = &.{} });
        }
        mod.addCSourceFile(.{ .file = b.path("src/c/stb_impl.c"), .flags = &.{} });
        mod.addCSourceFile(.{ .file = b.path("src/c/stb_write.c"), .flags = &.{} });
        mod.addIncludePath(b.path("third_party/stb"));
    }

    // Recorded IPC fixtures sit outside `src/`; keep them reachable through
    // a tiny module rooted at `testdata/root.zig`.
    const fixtures = b.createModule(.{
        .root_source_file = b.path("testdata/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("testdata", fixtures);

    return mod;
}

fn addBinaryStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const install = b.addInstallArtifact(exe, .{});
    const step = b.step(name, description);
    step.dependOn(&install.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_protocols_dir = std.mem.trim(
        u8,
        b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }),
        " \t\r\n",
    );

    var protocol_codes: [protocols.len]std.Build.LazyPath = undefined;
    var protocol_includes: [protocols.len]std.Build.LazyPath = undefined;
    for (protocols, 0..) |spec, i| {
        const generated = genProtocol(b, spec, wayland_protocols_dir);
        protocol_codes[i] = generated.code;
        protocol_includes[i] = generated.header.dirname();
    }

    // The supervisor. It pulls in the shell modules directly, so it needs
    // the protocol sources and Pango as well.
    const horizon_mod = shellModule(
        b,
        "src/main.zig",
        target,
        optimize,
        &protocol_codes,
        &protocol_includes,
        .{ .pango = true, .c_sources = true },
    );
    const horizon = b.addExecutable(.{ .name = "horizon", .root_module = horizon_mod });
    b.installArtifact(horizon);
    addBinaryStep(b, "horizon", "Build only horizon (the shell supervisor)", horizon);

    const run_cmd = b.addRunArtifact(horizon);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the shell supervisor");
    run_step.dependOn(&run_cmd.step);

    // Standalone IPC client: no Wayland, no Cairo, no protocol bindings.
    const ipc_mod = b.createModule(.{
        .root_source_file = b.path("src/eh_ipc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const eh_ipc = b.addExecutable(.{ .name = "eh-ipc", .root_module = ipc_mod });
    b.installArtifact(eh_ipc);
    addBinaryStep(b, "ipc", "Build only eh-ipc", eh_ipc);

    // Shared `eh` library module. Every standalone component that imports
    // it inherits the protocol bindings, fonts/text stack, and helpers.
    const eh_mod = shellModule(
        b,
        "src/eh.zig",
        target,
        optimize,
        &protocol_codes,
        &protocol_includes,
        .{ .pango = true, .c_sources = true },
    );

    // Unit tests use the same module graph as the shell, plus PipeWire for
    // the Audio Center backend tests.
    const test_root = b.option(
        []const u8,
        "test-root",
        "Test root source file (defaults to src/tests.zig)",
    ) orelse "src/tests.zig";
    const test_mod = shellModule(
        b,
        test_root,
        target,
        optimize,
        &protocol_codes,
        &protocol_includes,
        .{ .pango = true, .c_sources = true, .pipewire = true },
    );
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // All standalone component binaries. Each is installed by default and
    // also gets its own build step.
    inline for (binaries) |spec| {
        const mod = shellModule(
            b,
            spec.root,
            target,
            optimize,
            &protocol_codes,
            &protocol_includes,
            spec.options,
        );
        if (spec.imports_eh) mod.addImport("eh", eh_mod);
        const exe = b.addExecutable(.{ .name = spec.name, .root_module = mod });
        b.installArtifact(exe);
        addBinaryStep(b, spec.step, spec.description, exe);
    }

    // Icon theme pieces. The shell asks for `event-horizon-<stem>`, so the
    // installed names carry that prefix. Use:
    //   zig build install-icons --prefix ~/.local/share
    const icons_step = b.step(
        "install-icons",
        "Install src/resources/icons into the icon theme (use --prefix ~/.local/share)",
    );
    if (b.build_root.handle.openDir(b.graph.io, "src/resources/icons", .{ .iterate = true })) |icons_dir| {
        var dir = icons_dir;
        defer dir.close(b.graph.io);
        var it = dir.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
            const stem = entry.name[0 .. entry.name.len - ".svg".len];
            const install = b.addInstallFileWithDir(
                b.path(b.pathJoin(&.{ "src/resources/icons", entry.name })),
                .{ .custom = "icons/hicolor/scalable/apps" },
                b.fmt("event-horizon-{s}.svg", .{stem}),
            );
            icons_step.dependOn(&install.step);
        }
    } else |_| {}

    // Runtime data used by the native theme engine. `bundleRoot()` walks up
    // from the executable and looks for `<prefix>/share/event-horizon`,
    // so this layout is what installed binaries expect.
    const data_step = b.step("install-data", "Install matugen templates and the license");
    const matugen_install = b.addInstallDirectory(.{
        .source_dir = b.path("matugen"),
        .install_dir = .{ .custom = "share/event-horizon" },
        .install_subdir = "matugen",
    });
    const license_install = b.addInstallFile(
        b.path("LICENSE"),
        "share/licenses/event-horizon/LICENSE",
    );
    data_step.dependOn(&matugen_install.step);
    data_step.dependOn(&license_install.step);
    b.getInstallStep().dependOn(&matugen_install.step);
    b.getInstallStep().dependOn(&license_install.step);
}
