const std = @import("std");

// Builds tag_c — TagLib's C binding (+ helpers) — as one shared library for
// both platforms:
//   zig build -Drelease                             -> lib/libtag_c.so
//   zig build -Drelease -Dtarget=x86_64-windows-gnu -> bin/tag_c.dll
// (zig prefixes the ELF soname with "lib" only; PE DLLs keep the bare name.)
// C++ runtime is linked in statically; zlib off, identically on both.
// CI (.github/workflows/libtag_c.yml) builds both targets on tags taiko-*.
// Sources/includes are discovered by walking the tree; the two headers CMake
// would generate (config.h, taglib_config.h) come from addConfigHeader — no
// committed "gen/", no CMake needed.

const Dir = std.Io.Dir;

// Roots scanned for *.cpp sources; every directory under them is also made
// available as an include path.
const source_roots = [_][]const u8{
    "taglib",
    "bindings/c",
    "3rdparty/utfcpp/source",
};

const CollectResult = struct {
    files: [][]const u8,
    includes: [][]const u8,
};

fn collectSources(b: *std.Build) !CollectResult {
    const gpa = b.allocator;
    var files = std.ArrayList([]const u8).empty;
    var includes = std.ArrayList([]const u8).empty;

    for (source_roots) |root| {
        const abs = b.path(root).getPath(b);
        var dir = try Dir.openDirAbsolute(b.graph.io, abs, .{ .iterate = true });
        defer dir.close(b.graph.io);

        var walker = try Dir.walk(dir, gpa);
        defer walker.deinit();

        while (try walker.next(b.graph.io)) |entry| {
            // Walk paths are relative to the walked root; re-root them.
            const rel_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.path });
            switch (entry.kind) {
                .directory => try includes.append(gpa, rel_path),
                .file => if (std.mem.endsWith(u8, entry.basename, ".cpp"))
                    try files.append(gpa, rel_path),
                else => gpa.free(rel_path),
            }
        }
    }

    // Walk order follows readdir; sort for a deterministic command line.
    std.mem.sort([]const u8, files.items, {}, lessThan);
    std.mem.sort([]const u8, includes.items, {}, lessThan);

    // The roots themselves are include dirs too.
    var all_includes = std.ArrayList([]const u8).empty;
    for (source_roots) |root| try all_includes.append(gpa, root);
    try all_includes.appendSlice(gpa, includes.items);

    return .{ .files = try files.toOwnedSlice(gpa), .includes = try all_includes.toOwnedSlice(gpa) };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const lib = b.addLibrary(.{
        // Bare "tag_c": zig adds the "lib" prefix to the ELF soname itself.
        .name = "tag_c",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .pic = true,
            .strip = true,
            .link_libcpp = true,
        }),
    });

    const sources = collectSources(b) catch |err| {
        std.debug.print("libtag_c: scanning sources failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    lib.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = sources.files,
        .flags = &.{"-std=c++17"},
    });
    for (sources.includes) |d| lib.root_module.addIncludePath(b.path(d));

    // Headers CMake would generate; zlib off (compressed ID3v2 frames are a rare
    // legacy case and both platforms must behave identically).
    const config_h = b.addConfigHeader(.{
        .include_path = "config.h",
        .style = .blank,
    }, .{
        .HAVE_GCC_BYTESWAP = true,
    });
    lib.root_module.addConfigHeader(config_h);

    const taglib_config_h = b.addConfigHeader(.{
        .include_path = "taglib_config.h",
        .style = .blank,
    }, .{
        .TAGLIB_WITH_APE = true,
        .TAGLIB_WITH_ASF = true,
        .TAGLIB_WITH_DSF = true,
        .TAGLIB_WITH_MATROSKA = true,
        .TAGLIB_WITH_MOD = true,
        .TAGLIB_WITH_MP4 = true,
        .TAGLIB_WITH_RIFF = true,
        .TAGLIB_WITH_SHORTEN = true,
        .TAGLIB_WITH_TRUEAUDIO = true,
        .TAGLIB_WITH_VORBIS = true,
    });
    lib.root_module.addConfigHeader(taglib_config_h);

    lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    lib.root_module.addCMacro("TAGLIB_STATIC", "1");

    b.installArtifact(lib);
}
