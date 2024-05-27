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

pub const sprites_h_png = @embedFile("sprites_h.png");
pub const sprites_atlas = @embedFile("sprites.atlas");
pub const sprites_png = @embedFile("sprites.png");

// Note: the application itself doesn't use the tileset, LDTK does.
// pub const tileset_h_png = @embedFile("tileset_h.png");
// pub const tileset_atlas = @embedFile("tileset.atlas");
// pub const tileset_png = @embedFile("tileset.png");
