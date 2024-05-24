pub const bgm = struct {
    pub const hatching_ziguanas = @embedFile("bgm/hatching_ziguanas.opus");
    pub const morning_breaks = @embedFile("bgm/morning_breaks.opus");
    pub const night_falls = @embedFile("bgm/night_falls.opus");
    pub const prelude = @embedFile("bgm/prelude.opus");
};

pub const sfx = struct {
    pub const morning_bells = @embedFile("sfx/morning_bells.opus");
};

pub const spritesheet_h_png = @embedFile("spritesheet_h.png");
pub const spritesheet_atlas = @embedFile("spritesheet.atlas");
pub const spritesheet_png = @embedFile("spritesheet.png");
