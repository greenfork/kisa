const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    var target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("kisa", "src/client.zig");
    exe.use_stage1 = true;
    exe.addPackagePath("kisa", "src/kisa.zig");

    const sqlite = b.addStaticLibrary("sqlite", null);
    sqlite.addCSourceFile("deps/zig-sqlite/c/sqlite3.c", &[_][]const u8{"-std=c99"});
    sqlite.linkLibC();
    exe.linkLibrary(sqlite);
    exe.addPackagePath("sqlite", "deps/zig-sqlite/sqlite.zig");
    exe.addIncludeDir("deps/zig-sqlite/c");

    target.setGnuLibCVersion(2, 28, 0);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_all = b.step("test", "Run tests");
    {
        const test_cases = b.addTest("src/client.zig");
        test_cases.use_stage1 = true;
        test_cases.addPackagePath("kisa", "src/kisa.zig");
        test_cases.linkLibrary(sqlite);
        test_cases.addPackagePath("sqlite", "deps/zig-sqlite/sqlite.zig");
        test_cases.addIncludeDir("deps/zig-sqlite/c");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_all.dependOn(&test_cases.step);
    }
}
