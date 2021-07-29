const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("kisa", "src/main.zig");
    exe.addPackagePath("zzz", "zzz/src/main.zig");
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

    const test_step = b.step("test", "Run tests");

    {
        const test_cases = b.addTest("src/main.zig");
        test_cases.addPackagePath("zzz", "zzz/src/main.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/state.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
    }
}
