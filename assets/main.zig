pub const bgm = struct {
    pub const hatching_ziguanas = @embedFile("bgm/hatching_ziguanas.opus");
    pub const morning_breaks = @embedFile("bgm/morning_breaks.opus");
    pub const night_falls = @embedFile("bgm/night_falls.opus");
    pub const prelude = @embedFile("bgm/prelude.opus");
};

pub const sfx = struct {
    pub const fire = @embedFile("sfx/fire.opus");
    pub const footsteps = @embedFile("sfx/footsteps.opus");
    pub const freeze = @embedFile("sfx/freeze.opus");
    pub const morning_bells = @embedFile("sfx/morning_bells.opus");
};

pub const level_ldtk = @embedFile("level.ldtk");

pub const lordofzero_h_png = @embedFile("lordofzero_h.png");
pub const lordofzero_atlas = @embedFile("lordofzero.atlas");
pub const lordofzero_png = @embedFile("lordofzero.png");

pub const pixi_ldtk_json = @embedFile("pixi-ldtk.json");
