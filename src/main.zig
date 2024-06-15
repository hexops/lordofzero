const mach = @import("mach");

// The global list of Mach modules registered for use in our application.
pub const modules = .{
    mach.Core,
    mach.gfx.sprite_modules,
    mach.Audio,
    mach.gfx.text_modules,
    @import("App.zig"),
};

pub fn main() !void {
    // Initialize mach.Core
    try mach.core.initModule();

    // Main loop
    while (try mach.core.tick()) {}
}

pub const use_sysgpu = switch (@import("builtin").target.os.tag) {
    .macos => true,
    else => false,
};
