const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const assets = @import("assets");

const pixi = @import("pixi.zig");
const ldtk = @import("ldtk.zig");

const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

// The name of the module that the mach.Core will schedule .init, .deinit, and .tick for
pub const name = .app;
pub const Mod = mach.Mod(@This());

pub const systems = .{
    .init = .{ .handler = init },
    .deinit = .{ .handler = deinit },
    .after_init = .{ .handler = afterInit },
    .tick = .{ .handler = tick },
    .end_frame = .{ .handler = endFrame },
    .audio_state_change = .{ .handler = audioStateChange },
    .update_scene = .{ .handler = updateScene },
    .update_effects = .{ .handler = updateEffects },
};

pub const components = .{
    .is_bgm = .{ .type = void },
    .is_sfx = .{ .type = void },
    .is_start_scene = .{ .type = void },
    .is_game_scene = .{ .type = void },
    .is_logo = .{ .type = void },
    .pixi_sprite = .{ .type = pixi.Sprite },
    .after_play_change_scene = .{ .type = Scene },
    .effect_timer = .{ .type = mach.Timer },
    .is_flipped = .{ .type = bool },
    .position = .{ .type = Vec3 },
};

const Scene = enum {
    none,
    start,
    game,
};

const start_scale = 3.0;
const world_scale = 2.0;

const foxnne_debug = false;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

player: mach.EntityID,
direction: Vec2 = vec2(0, 0),
last_facing_direction: Vec2 = vec2(0, 0),
player_position: Vec3 = vec3(0, 0, 0), // z == player layer
player_wants_to_attack: bool = false,
attack_cooldown: f32 = 1.0,
attack_cooldown_timer: mach.Timer,
is_attacking: bool = false,
timer: mach.Timer,
delta_timer: mach.Timer,
spawn_timer: mach.Timer,
fps_timer: mach.Timer,
player_anim_timer: mach.Timer,
player_anim_frame: isize = -1,
frame_count: usize,
rand: std.rand.DefaultPrng,
time: f32,
allocator: std.mem.Allocator,
pipeline: mach.EntityID,
text_pipeline: mach.EntityID,
frame_encoder: *gpu.CommandEncoder = undefined,
frame_render_pass: *gpu.RenderPassEncoder = undefined,
parsed_atlas: pixi.ParsedFile,
parsed_level: ldtk.ParsedFile,
scene: Scene = .start,
prev_scene: Scene = .none,

fn deinit(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
) !void {
    sprite_pipeline.schedule(.deinit);
    audio.schedule(.deinit);
    text.schedule(.deinit);
    text_pipeline.schedule(.deinit);
    core.schedule(.deinit);
    app.state().parsed_atlas.deinit();
    app.state().parsed_level.deinit();
}

fn init(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
) !void {
    // Make the window fullscreen before it opens, if you want:
    // try core.set(core.state().main_window, .fullscreen, true);
    try core.set(core.state().main_window, .width, 1920.0 * (3.0 / 4.0));
    try core.set(core.state().main_window, .height, 1080.0 * (3.0 / 4.0));

    core.schedule(.init);
    sprite_pipeline.schedule(.init);
    audio.schedule(.init);
    text.schedule(.init);
    text_pipeline.schedule(.init);
    app.schedule(.after_init);
}

fn afterInit(
    entities: *mach.Entities.Mod,
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
) !void {
    // Configure the audio module to send our app's .audio_state_change event when an entity's sound
    // finishes playing.
    audio.state().on_state_change = app.system(.audio_state_change);

    // Create a sprite rendering pipeline
    const allocator = gpa.allocator();
    const pipeline = try entities.new();
    try sprite_pipeline.set(pipeline, .texture, try loadTexture(core, allocator));
    sprite_pipeline.schedule(.update);

    // Create a text rendering pipeline
    const text_pipeline_id = try entities.new();
    try text_pipeline.set(text_pipeline_id, .is_pipeline, {});
    text_pipeline.schedule(.update);

    // Load pixi atlas file
    const parsed_atlas = try pixi.File.parseSlice(allocator, assets.sprites_atlas);
    std.debug.print("loaded sprite atlas: {} sprites, {} animations\n", .{ parsed_atlas.value.sprites.len, parsed_atlas.value.animations.len });

    // Load .ldtk level file
    const parsed_level = try ldtk.File.parseSlice(allocator, assets.level_ldtk);
    const level = blk: {
        for (parsed_level.value.worlds[0].levels) |level| {
            if (std.mem.eql(u8, level.identifier, "Level_0")) break :blk level;
        }
        @panic("could not find level");
    };

    std.debug.print("loaded level: {s} {}x{}px, layers: {}\n", .{ level.identifier, level.pxWid, level.pxHei, level.layerInstances.?.len });
    for (level.layerInstances.?) |layer| {
        std.debug.print(" layer: {s}, type={s}, visible={}, grid_size={}px, {}x{} (grid-based size)\n", .{
            layer.__identifier,
            @tagName(layer.__type),
            layer.visible,
            layer.__gridSize,
            layer.__cWid,
            layer.__cHei,
        });
        std.debug.print("        pxTotalOffset={},{}, entities={}, grid_tiles={}, tileset={?s}\n", .{
            layer.__pxTotalOffsetX,
            layer.__pxTotalOffsetY,
            layer.entityInstances.len,
            layer.gridTiles.len,
            layer.__tilesetRelPath,
        });
    }

    const player = try entities.new();
    app.init(.{
        .player = player,
        .attack_cooldown_timer = try mach.Timer.start(),
        .timer = try mach.Timer.start(),
        .delta_timer = try mach.Timer.start(),
        .spawn_timer = try mach.Timer.start(),
        .fps_timer = try mach.Timer.start(),
        .player_anim_timer = try mach.Timer.start(),
        .frame_count = 0,
        .rand = std.rand.DefaultPrng.init(1337),
        .time = 0,
        .allocator = allocator,
        .pipeline = pipeline,
        .text_pipeline = text_pipeline_id,
        .parsed_atlas = parsed_atlas,
        .parsed_level = parsed_level,
    });

    // Load the initial starting screen scene
    app.schedule(.update_scene);

    // We're ready for .tick to run
    core.schedule(.start);
}

fn audioStateChange(
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
    app: *Mod,
) !void {
    // Find audio entities that are no longer playing
    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .playings = mach.Audio.Mod.read(.playing),
    });
    while (q.next()) |v| {
        for (v.ids, v.playings) |id, playing| {
            if (playing) continue;

            if (app.get(id, .is_bgm)) |_| {
                // Repeat background music
                try audio.set(id, .index, 0);
                try audio.set(id, .playing, true);
            } else {
                // Free buffer
                app.state().allocator.free(audio.get(id, .samples).?);
                // Remove the entity for the old sound
                try entities.remove(id);
            }

            if (app.get(id, .after_play_change_scene)) |scene| {
                app.state().scene = scene;
                app.schedule(.update_scene);
            }
        }
    }
}

fn updateScene(
    sprite: *gfx.Sprite.Mod,
    app: *Mod,
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_style: *gfx.TextStyle.Mod,
) !void {
    if (app.state().prev_scene == app.state().scene) return;

    // Find and remove entities that belong to the previously active scene.
    switch (app.state().prev_scene) {
        .none => {},
        .start => {
            var q = try entities.query(.{
                .ids = mach.Entities.Mod.read(.id),
                .is_start_scene = Mod.read(.is_start_scene),
            });
            while (q.next()) |v| {
                for (v.ids) |id| {
                    if (audio.get(id, .samples)) |buffer| app.state().allocator.free(buffer);
                    try entities.remove(id);
                }
            }
        },
        .game => {
            var q = try entities.query(.{
                .ids = mach.Entities.Mod.read(.id),
                .is_game_scene = Mod.read(.is_game_scene),
            });
            while (q.next()) |v| {
                for (v.ids) |id| {
                    if (audio.get(id, .samples)) |buffer| app.state().allocator.free(buffer);
                    try entities.remove(id);
                }
            }
        },
    }
    app.state().prev_scene = app.state().scene;

    defer sprite.schedule(.update);
    defer text.schedule(.update);

    switch (app.state().scene) {
        .none => {},
        .start => {
            // Load our "prelude" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.prelude);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.state().allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try entities.new();
            try audio.set(bgm_entity, .samples, bgm.samples);
            try audio.set(bgm_entity, .channels, bgm.channels);
            try audio.set(bgm_entity, .playing, true);
            try audio.set(bgm_entity, .index, 0);
            try app.set(bgm_entity, .is_start_scene, {}); // This entity belongs to the start scene
            try app.set(bgm_entity, .is_bgm, {}); // Mark our audio entity is bgm, so we can distinguish it from sfx later.

            const grey_block_color = vec4(0.604, 0.584, 0.525, 1.0);
            const style1 = try entities.new();
            try text_style.set(style1, .font_size, 48 * gfx.px_per_pt); // 48pt
            try text_style.set(style1, .font_color, grey_block_color);
            try app.set(style1, .is_start_scene, {}); // This entity belongs to the start scene

            // Create some text
            const text_id = try entities.new();
            try text.set(text_id, .pipeline, app.state().text_pipeline);
            try text.set(text_id, .transform, Mat4x4.translate(vec3(-100, -360, 0)));
            try gfx.Text.allocPrintText(text, text_id, style1, "Press any key to start", .{});
            text.schedule(.update);
            try app.set(text_id, .is_start_scene, {}); // This entity belongs to the start scene

            // Create some text
            const style2 = try entities.new();
            try text_style.set(style2, .font_size, 28 * gfx.px_per_pt); // 28pt
            try text_style.set(style2, .font_color, grey_block_color);
            try app.set(style2, .is_start_scene, {}); // This entity belongs to the start scene

            // Create the "Lord of Zero" logo sprite
            var z_layer: f32 = 0;
            const atlas = app.state().parsed_atlas.value;
            for (atlas.sprites) |sprite_info| {
                if (!std.mem.startsWith(u8, sprite_info.name, "logo_0_")) continue;

                const x = sprite_info.source[0];
                const y = sprite_info.source[1];
                const width = sprite_info.source[2];
                const height = sprite_info.source[3];
                const origin = vec3(
                    @floatFromInt(sprite_info.origin[0]),
                    -@as(f32, @floatFromInt(sprite_info.origin[1])),
                    0,
                );

                const id = try entities.new();
                const scale = Mat4x4.scaleScalar(start_scale);
                const translate = Mat4x4.translate(vec3(
                    -220,
                    140,
                    z_layer,
                ));
                z_layer += 1;

                const org = Mat4x4.translate(vec3(0, -@as(f32, @floatFromInt(height)), 0).sub(&origin));
                try sprite.set(
                    id,
                    .transform,
                    translate.mul(&scale).mul(&org),
                );
                try sprite.set(id, .size, vec2(@floatFromInt(width), @floatFromInt(height)));
                try sprite.set(id, .uv_transform, Mat3x3.translate(vec2(@floatFromInt(x), @floatFromInt(y))));
                try sprite.set(id, .pipeline, app.state().pipeline);
                try app.set(id, .pixi_sprite, sprite_info);
                try app.set(id, .is_start_scene, {}); // This entity belongs to the start scene
                try app.set(id, .is_logo, {}); // This entity belongs to the start scene
            }
        },
        .game => {
            // Load our "Morning Breaks" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.morning_breaks);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.state().allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try entities.new();
            try audio.set(bgm_entity, .samples, bgm.samples);
            try audio.set(bgm_entity, .channels, bgm.channels);
            try audio.set(bgm_entity, .playing, true);
            try audio.set(bgm_entity, .index, 0);
            try app.set(bgm_entity, .is_game_scene, {}); // This entity belongs to the start scene
            try app.set(bgm_entity, .is_bgm, {}); // Mark our audio entity is bgm, so we can distinguish it from sfx later.

            // Create the "Wrench" player sprite
            var z_layer: f32 = 0;
            const atlas = app.state().parsed_atlas.value;
            for (atlas.sprites) |sprite_info| {
                if (!std.mem.startsWith(u8, sprite_info.name, "wrench_idle")) continue;

                const x = sprite_info.source[0];
                const y = sprite_info.source[1];
                const width = sprite_info.source[2];
                const height = sprite_info.source[3];

                const origin_x = sprite_info.origin[0];
                const origin_y = sprite_info.origin[1];
                const origin = vec3(@floatFromInt(origin_x), -@as(f32, @floatFromInt(origin_y)), 0);

                const scale = Mat4x4.scaleScalar(world_scale);
                const translate = Mat4x4.translate(vec3(
                    0,
                    0,
                    z_layer,
                ));
                z_layer += 1;
                const org = Mat4x4.translate(vec3(0, -@as(f32, @floatFromInt(height)), 0).sub(&origin));
                try sprite.set(
                    app.state().player,
                    .transform,
                    translate.mul(&scale).mul(&org),
                );
                try sprite.set(app.state().player, .size, vec2(@floatFromInt(width), @floatFromInt(height)));
                try sprite.set(app.state().player, .uv_transform, Mat3x3.translate(vec2(@floatFromInt(x), @floatFromInt(y))));
                try sprite.set(app.state().player, .pipeline, app.state().pipeline);
                try app.set(app.state().player, .is_game_scene, {});
                break;
            }
        },
    }
}

fn updateEffects(sprite: *gfx.Sprite.Mod, app: *Mod, entities: *mach.Entities.Mod) !void {

    // Find effect entities with timer
    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .timers = Mod.write(.effect_timer),
        .flips = Mod.read(.is_flipped),
        .positions = Mod.read(.position),
    });

    while (q.next()) |v| {
        for (v.ids, v.timers, v.flips, v.positions) |id, *timer, flip, position| {
            const attack_fx = id;
            const effect_animation_name = "ground_attack_main";
            const effect_dissolve_name = "ground_attack_dissolve_main";

            const atlas = app.state().parsed_atlas.value;
            const effect_animation_info: pixi.Animation = blk: {
                for (atlas.animations) |anim| {
                    if (std.mem.eql(u8, anim.name, effect_animation_name)) break :blk anim;
                }
                @panic("cannot find animation");
            };

            const dissolve_animation_info: pixi.Animation = blk: {
                for (atlas.animations) |anim| {
                    if (std.mem.eql(u8, anim.name, effect_dissolve_name)) break :blk anim;
                }
                @panic("cannot find animation");
            };

            // Determine the next player animation frame
            const animation_fps: f32 = @floatFromInt(effect_animation_info.fps);
            const i: usize = @intFromFloat(timer.read() * animation_fps);

            if (i > (effect_animation_info.length + dissolve_animation_info.length) - 2) {
                try entities.remove(id);
                continue;
            }

            const effect_sprite_info: pixi.Sprite = if (i > effect_animation_info.length)
                atlas.sprites[dissolve_animation_info.start + (i - effect_animation_info.length)]
            else
                atlas.sprites[effect_animation_info.start + i];

            var z_layer: f32 = 0;

            const effect_x: f32 = @floatFromInt(effect_sprite_info.source[0]);
            const effect_y: f32 = @floatFromInt(effect_sprite_info.source[1]);
            const effect_width: f32 = @floatFromInt(effect_sprite_info.source[2]);
            const effect_height: f32 = @floatFromInt(effect_sprite_info.source[3]);

            const origin_x = effect_sprite_info.origin[0];
            const origin_y = effect_sprite_info.origin[1];
            const origin = vec3(
                if (!flip) @floatFromInt(origin_x) else effect_width - @as(f32, @floatFromInt(origin_x)),
                -@as(f32, @floatFromInt(origin_y)),
                0,
            );

            const scale = Mat4x4.scaleScalar(world_scale);
            const translate = Mat4x4.translate(vec3(
                position.v[0],
                position.v[1],
                z_layer,
            ));
            z_layer += 1;
            const org = Mat4x4.translate(vec3(0, -effect_height, 0).sub(&origin));
            try sprite.set(
                attack_fx,
                .transform,
                translate.mul(&scale).mul(&org),
            );

            var uv_transform = Mat3x3.translate(vec2(effect_x, effect_y));
            if (flip) {
                const uv_flip_horizontally = Mat3x3.scale(vec2(-1, 1));
                const uv_origin_shift = Mat3x3.translate(vec2(effect_width, 0));
                const uv_translate = Mat3x3.translate(vec2(effect_x, effect_y));
                uv_transform = uv_origin_shift.mul(&uv_translate).mul(&uv_flip_horizontally);
            }
            try sprite.set(attack_fx, .size, vec2(effect_width, effect_height));
            try sprite.set(attack_fx, .uv_transform, uv_transform);
        }
    }
}

fn tick(
    core: *mach.Core.Mod,
    sprite: *gfx.Sprite.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    app: *Mod,
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
) !void {
    var iter = mach.core.pollEvents();
    var direction = app.state().direction;
    var player_wants_to_attack = app.state().player_wants_to_attack;
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => player_wants_to_attack = true,
                    else => {},
                }
                if (app.state().scene == .start) {
                    // Load our "Morning bells" sfx
                    const sfx_fbs = std.io.fixedBufferStream(assets.sfx.morning_bells);
                    const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                    const sfx = try mach.Audio.Opus.decodeStream(app.state().allocator, sfx_sound_stream);

                    // Create an audio entity to play our sfx
                    const sfx_entity = try entities.new();
                    try audio.set(sfx_entity, .samples, sfx.samples);
                    try audio.set(sfx_entity, .channels, sfx.channels);
                    try audio.set(sfx_entity, .playing, true);
                    try audio.set(sfx_entity, .index, 0);
                    try audio.set(sfx_entity, .volume, 0.3);
                    try app.set(sfx_entity, .is_start_scene, {}); // This entity belongs to the start scene
                    try app.set(sfx_entity, .is_sfx, {}); // Mark our audio entity is sfx, so we can distinguish it from bgm later.

                    // Change the scene to .game after the sfx has played
                    try app.set(sfx_entity, .after_play_change_scene, .game);
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] += 1,
                    .right => direction.v[0] -= 1,
                    .up => direction.v[1] -= 1,
                    .down => direction.v[1] += 1,
                    .space => player_wants_to_attack = false,
                    else => {},
                }
            },
            .close => core.schedule(.exit),
            else => {},
        }
    }
    const begin_moving = !app.state().is_attacking and app.state().direction.eql(&vec2(0, 0)) and !direction.eql(&vec2(0, 0));
    app.state().direction = direction;
    app.state().player_wants_to_attack = player_wants_to_attack;

    // Multiply by delta_time to ensure that movement is the same speed regardless of the frame rate.
    const delta_time = app.state().delta_timer.lap();

    switch (app.state().scene) {
        .none => {},
        .start => {
            // Make the logo sprites (there are multiple, one for each 'sprite layer' in pixi) bounce up and down slowly
            var q = try entities.query(.{
                .is_logo = Mod.read(.is_logo),
                .transforms = gfx.Sprite.Mod.write(.transform),
                .sprite_infos = Mod.read(.pixi_sprite),
            });
            while (q.next()) |v| {
                for (v.transforms, v.sprite_infos) |*transform, sprite_info| {
                    const logo_sprite_width = 256;
                    const logo_sprite_height = 160;
                    const height: f32 = @floatFromInt(sprite_info.source[3]);
                    const origin = vec3(
                        @floatFromInt(sprite_info.origin[0]),
                        -@as(f32, @floatFromInt(sprite_info.origin[1])),
                        0,
                    );

                    const scale = Mat4x4.scaleScalar(start_scale);
                    const translate = Mat4x4.translate(vec3(
                        -(logo_sprite_width * start_scale) / 2.0,
                        ((logo_sprite_height * start_scale) / 2.0) + (10 * math.sin((app.state().timer.read() / 8.0) * 2 * std.math.pi)),
                        transform.translation().z(),
                    ));
                    const org = Mat4x4.translate(vec3(0, -height, 0).sub(&origin));

                    transform.* = translate.mul(&scale).mul(&org);
                }
            }
        },
        .game => {
            const can_attack = app.state().attack_cooldown_timer.read() > app.state().attack_cooldown;
            const begin_attack = !app.state().is_attacking and can_attack and app.state().player_wants_to_attack;

            if (begin_attack) {
                app.state().attack_cooldown_timer.reset();
                app.state().is_attacking = true;
            }
            if (begin_moving or begin_attack) {
                app.state().player_anim_timer.reset();
                app.state().player_anim_frame = -1;
            }

            const animation_name = if (app.state().is_attacking)
                "wrench_attack_main"
            else if (app.state().direction.eql(&vec2(0, 0)))
                "wrench_upgrade_main"
            else
                "wrench_walk_main";

            // Render the next animation frame for Wrench
            const atlas = app.state().parsed_atlas.value;
            const animation_info: pixi.Animation = blk: {
                for (atlas.animations) |anim| {
                    if (std.mem.eql(u8, anim.name, animation_name)) break :blk anim;
                }
                @panic("cannot find animation");
            };

            var end_attack: bool = false;

            // Determine the next player animation frame
            const animation_fps: f32 = @floatFromInt(animation_info.fps);
            var i: usize = @intFromFloat(app.state().player_anim_timer.read() * animation_fps);
            if (i >= animation_info.length) {
                app.state().player_anim_timer.reset();
                i = 0;

                if (app.state().is_attacking) {
                    app.state().is_attacking = false;
                    end_attack = true;
                }
            }
            const sprite_info: pixi.Sprite = atlas.sprites[animation_info.start + i];

            const player = app.state().player;
            const x: f32 = @floatFromInt(sprite_info.source[0]);
            const y: f32 = @floatFromInt(sprite_info.source[1]);
            const width: f32 = @floatFromInt(sprite_info.source[2]);
            const height: f32 = @floatFromInt(sprite_info.source[3]);

            // Player moves in the direction of the keyboard input
            const dir = if (app.state().is_attacking) app.state().direction.mulScalar(0.5) else app.state().direction;
            if (!dir.eql(&vec2(0, 0))) {
                app.state().last_facing_direction = dir;
            }
            const speed = 250.0;
            const pos = app.state().player_position.add(
                &vec3(dir.v[0], dir.v[1], 0).mulScalar(speed).mulScalar(delta_time),
            );
            app.state().player_position = pos;

            const flipped: bool = (foxnne_debug and i % 2 == 0) or (!foxnne_debug and app.state().last_facing_direction.v[0] < 0);

            if (end_attack) {
                const attack_fx = try entities.new();
                const effect_animation_name = "ground_attack_main";

                const effect_animation_info: pixi.Animation = blk: {
                    for (atlas.animations) |anim| {
                        if (std.mem.eql(u8, anim.name, effect_animation_name)) break :blk anim;
                    }
                    @panic("cannot find animation");
                };

                const effect_sprite_info = atlas.sprites[effect_animation_info.start];

                var z_layer: f32 = 0;

                const effect_x: f32 = @floatFromInt(effect_sprite_info.source[0]);
                const effect_y: f32 = @floatFromInt(effect_sprite_info.source[1]);
                const effect_width: f32 = @floatFromInt(effect_sprite_info.source[2]);
                const effect_height: f32 = @floatFromInt(effect_sprite_info.source[3]);

                const origin_x = effect_sprite_info.origin[0];
                const origin_y = effect_sprite_info.origin[1];
                const origin = vec3(
                    if (!flipped) @floatFromInt(origin_x) else effect_width - @as(f32, @floatFromInt(origin_x)),
                    -@as(f32, @floatFromInt(origin_y)),
                    0,
                );

                const position: Vec3 = vec3(
                    if (app.state().last_facing_direction.v[0] >= 0) pos.v[0] + 64.0 else pos.v[0] - 64.0,
                    pos.v[1],
                    z_layer,
                );

                const scale = Mat4x4.scaleScalar(world_scale);
                const translate = Mat4x4.translate(position);
                z_layer += 1;
                const org = Mat4x4.translate(vec3(0, -effect_height, 0).sub(&origin));
                try sprite.set(
                    attack_fx,
                    .transform,
                    translate.mul(&scale).mul(&org),
                );

                var uv_transform = Mat3x3.translate(vec2(effect_x, effect_y));
                if (flipped) {
                    const uv_flip_horizontally = Mat3x3.scale(vec2(-1, 1));
                    const uv_origin_shift = Mat3x3.translate(vec2(effect_width, 0));
                    const uv_translate = Mat3x3.translate(vec2(effect_x, effect_y));
                    uv_transform = uv_origin_shift.mul(&uv_translate).mul(&uv_flip_horizontally);
                }

                try sprite.set(attack_fx, .size, vec2(effect_width, effect_height));
                try sprite.set(attack_fx, .uv_transform, uv_transform);
                try sprite.set(attack_fx, .pipeline, app.state().pipeline);
                try app.set(attack_fx, .is_game_scene, {});
                try app.set(attack_fx, .effect_timer, try mach.Timer.start());
                try app.set(attack_fx, .is_flipped, flipped);
                try app.set(attack_fx, .position, position);
            }

            const origin = vec3(
                if (!flipped) @floatFromInt(sprite_info.origin[0]) else width - @as(f32, @floatFromInt(sprite_info.origin[0])),
                -@as(f32, @floatFromInt(sprite_info.origin[1])),
                0,
            );

            const scale = Mat4x4.scaleScalar(world_scale);
            const translate = Mat4x4.translate(pos);
            const org = Mat4x4.translate(vec3(0, -height, 0).sub(&origin));
            try sprite.set(
                player,
                .transform,
                translate.mul(&scale).mul(&org),
            );
            try sprite.set(player, .size, vec2(width, height));

            // If the player is moving left instead of right, then flip the sprite so it renders
            // facing the left instead of its natural right-facing direction.
            var uv_transform = Mat3x3.translate(vec2(x, y));
            if (flipped) {
                const uv_flip_horizontally = Mat3x3.scale(vec2(-1, 1));
                const uv_origin_shift = Mat3x3.translate(vec2(width, 0));
                const uv_translate = Mat3x3.translate(vec2(x, y));
                uv_transform = uv_origin_shift.mul(&uv_translate).mul(&uv_flip_horizontally);
            }
            try sprite.set(player, .uv_transform, uv_transform);

            if (i != app.state().player_anim_frame) {
                // Player animation frame has changed
                app.state().player_anim_frame = @intCast(i);

                // If walking, play footstep sfx every 2nd frame
                if (!app.state().is_attacking and !dir.eql(&vec2(0, 0)) and i % 2 == 0) {
                    // Load our "footsteps" sfx
                    // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
                    const sfx_fbs = std.io.fixedBufferStream(assets.sfx.footsteps);
                    const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                    const sfx = try mach.Audio.Opus.decodeStream(app.state().allocator, sfx_sound_stream);

                    // Create an audio entity to play our sfx
                    const sfx_entity = try entities.new();
                    try audio.set(sfx_entity, .samples, sfx.samples);
                    try audio.set(sfx_entity, .channels, sfx.channels);
                    try audio.set(sfx_entity, .playing, true);
                    try audio.set(sfx_entity, .index, 0);
                    try audio.set(sfx_entity, .volume, 4.3);
                    try app.set(sfx_entity, .is_game_scene, {}); // This entity belongs to the start scene
                    try app.set(sfx_entity, .is_sfx, {}); // Mark our audio entity is sfx, so we can distinguish it from bgm later.
                }

                // If attacking, play attack noise on first frame
                if (app.state().is_attacking and i == 0) {
                    // Load our "freeze" sfx
                    // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
                    const sfx_fbs = std.io.fixedBufferStream(assets.sfx.freeze);
                    const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                    const sfx = try mach.Audio.Opus.decodeStream(app.state().allocator, sfx_sound_stream);

                    // Create an audio entity to play our sfx
                    const sfx_entity = try entities.new();
                    try audio.set(sfx_entity, .samples, sfx.samples);
                    try audio.set(sfx_entity, .channels, sfx.channels);
                    try audio.set(sfx_entity, .playing, true);
                    try audio.set(sfx_entity, .index, 0);
                    try audio.set(sfx_entity, .volume, 0.6);
                    try app.set(sfx_entity, .is_game_scene, {}); // This entity belongs to the start scene
                    try app.set(sfx_entity, .is_sfx, {}); // Mark our audio entity is sfx, so we can distinguish it from bgm later.
                }
            }
        },
    }
    sprite.schedule(.update);

    // Our aim will be for our virtual canvas to be two thirds 1920x1080px. For our game, we do not
    // want the player to see more or less horizontally, as that may give an unfair advantage, but
    // they can see more or less vertically as that will only be more clouds or ground texture. As
    // such, we make the width fixed and dynamically adjust the height of our virtual canvas to be
    // whatever is needed to match the actual window aspect ratio without any stretching.
    const window_width_px: f32 = @floatFromInt(mach.core.size().width);
    const window_height_px: f32 = @floatFromInt(mach.core.size().height);
    const width_px: f32 = 1920.0 * (3.0 / 4.0);
    const height_px: f32 = width_px * (window_height_px / window_width_px);
    const projection = math.Mat4x4.projection2D(.{
        .left = -width_px / 2,
        .right = width_px / 2,
        .bottom = -height_px / 2,
        .top = height_px / 2,
        .near = -0.1,
        .far = 100000,
    });
    const view_projection = projection.mul(&Mat4x4.translate(vec3(0, 0, 0)));
    try sprite_pipeline.set(app.state().pipeline, .view_projection, view_projection);
    try text_pipeline.set(app.state().pipeline, .view_projection, view_projection);

    // Perform pre-render work
    sprite_pipeline.schedule(.pre_render);
    text_pipeline.schedule(.pre_render);

    app.schedule(.update_effects);

    // Create a command encoder for this frame
    const label = @tagName(name) ++ ".tick";
    app.state().frame_encoder = core.state().device.createCommandEncoder(&.{ .label = label });

    // Grab the back buffer of the swapchain
    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    // Begin render pass
    const dark_gray = gpu.Color{ .r = 0.106, .g = 0.11, .b = 0.118, .a = 1 };
    const sky_blue = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    _ = sky_blue;
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = switch (app.state().scene) {
            .none => dark_gray,
            .start => dark_gray,
            .game => dark_gray,
        },
        .load_op = .clear,
        .store_op = .store,
    }};
    app.state().frame_render_pass = app.state().frame_encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));

    // Render our sprite batch
    sprite_pipeline.state().render_pass = app.state().frame_render_pass;
    sprite_pipeline.schedule(.render);

    // Render our text batch
    text_pipeline.state().render_pass = app.state().frame_render_pass;
    text_pipeline.schedule(.render);

    // Finish the frame once rendering is done.
    app.schedule(.end_frame);

    app.state().time += delta_time;
}

fn endFrame(app: *Mod, core: *mach.Core.Mod) !void {
    // Finish render pass
    app.state().frame_render_pass.end();
    const label = @tagName(name) ++ ".endFrame";
    var command = app.state().frame_encoder.finish(&.{ .label = label });
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    app.state().frame_encoder.release();
    app.state().frame_render_pass.release();

    // Present the frame
    core.schedule(.present_frame);

    // Every second, update the window title with the FPS
    if (app.state().fps_timer.read() >= 1.0) {
        try mach.Core.printTitle(
            core,
            core.state().main_window,
            "Lord of Zero [ FPS: {d} ]",
            .{app.state().frame_count},
        );
        core.schedule(.update);
        app.state().fps_timer.reset();
        app.state().frame_count = 0;
    }
    app.state().frame_count += 1;
}

fn loadTexture(core: *mach.Core.Mod, allocator: std.mem.Allocator) !*gpu.Texture {
    const device = core.state().device;
    const queue = core.state().queue;

    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, assets.sprites_png);
    defer img.deinit();
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(name) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
            .render_attachment = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }
    return texture;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
