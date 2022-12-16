const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const asio = gitClone(b);

    const exe = b.addExecutable("asio-qsort", null);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addIncludePath("vendor/asio/asio/include");
    exe.addCSourceFile("src/qsort.cpp", &.{ "-Oz", "-Wall", "-std=c++14" });
    exe.linkLibCpp();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    const git_step = b.step("git", "Run git clone asio");
    git_step.dependOn(&asio.step);
}

fn gitClone(b: *std.build.Builder) *std.build.RunStep {
    return b.addSystemCommand(&[_][]const u8{ "git", "clone", "https://github.com/chriskohlhoff/asio", "vendor/asio" });
}
