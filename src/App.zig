const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const assets = @import("assets");

const Card = @import("Card.zig");
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
    // Systems mach.Core will schedule to run:
    .init = .{ .handler = init },
    .deinit = .{ .handler = deinit },
    .tick = .{ .handler = tick },

    // Systems that run in response to some event
    .after_init = .{ .handler = afterInit },
    .audio_state_change = .{ .handler = audioStateChange },
    .change_scene = .{ .handler = changeScene },

    // Systems that may run each frame
    .poll_input = .{ .handler = pollInput },
    .update_start_scene = .{ .handler = updateStartScene },
    .update_game_scene = .{ .handler = updateGameScene },
    .update_camera = .{ .handler = updateCamera },
    .update_anims = .{ .handler = updateAnims },
    .render_frame = .{ .handler = renderFrame },
    .post_process = .{ .handler = postProcess },
    .finish_frame = .{ .handler = finishFrame },
};

pub const components = .{
    .is_bgm = .{ .type = void },
    .is_sfx = .{ .type = void },
    .is_start_scene = .{ .type = void },
    .is_game_scene = .{ .type = void },
    .is_logo = .{ .type = void },
    .is_tile = .{ .type = void },
    .is_entity = .{ .type = void },
    .is_rtt_card = .{ .type = void },
    .pixi_sprite = .{ .type = pixi.Sprite },
    .after_play_change_scene = .{ .type = Scene },
    .sprite_anim = .{ .type = pixi.Animation },
    .sprite_delete_after_anim = .{ .type = void },
    .sprite_timer = .{ .type = f32 },
    .sprite_flipped = .{ .type = bool },
    .parallax = .{ .type = [2]f32 },
    .position = .{ .type = Vec3 },
};

const Scene = enum {
    none,
    start,
    game,
};

const start_scale = 3.0;
const world_scale = 2.0;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

player: mach.EntityID,
direction: Vec2 = vec2(0, 0),
last_direction: Vec2 = vec2(0, 0),
last_facing_direction: Vec2 = vec2(0, 0),
player_position: Vec3 = vec3(0, 0, 0), // z == player layer
camera_position: Vec3 = vec3(0, 0, 0),
player_wants_to_attack: bool = false,
player_wants_to_run: bool = false,
attack_cooldown: f32 = 1.0,
attack_cooldown_timer: mach.Timer,
is_attacking: bool = false,
timer: mach.Timer,
delta_timer: mach.Timer,
spawn_timer: mach.Timer,
fps_timer: mach.Timer,
player_sprite_timer: mach.Timer,
delta_time: f32 = 0,
player_anim_frame: isize = -1,
frame_count: usize,
rand: std.rand.DefaultPrng,
time: f32,
allocator: std.mem.Allocator,
pipeline: mach.EntityID,
text_pipeline: mach.EntityID,
frame_encoder: *gpu.CommandEncoder = undefined,
frame_render_pass: *gpu.RenderPassEncoder = undefined,
parsed_atlas: pixi.ParsedAtlas,
parsed_level: ldtk.ParsedFile,
parsed_ldtk_compatibility: pixi.ParsedLDTKCompatibility,
scene: Scene = .game,
prev_scene: Scene = .none,
rtt_texture_view: *gpu.TextureView,

fn deinit(
    core: *mach.Core.Mod,
    card: *Card.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
) !void {
    card.schedule(.deinit);
    sprite_pipeline.schedule(.deinit);
    audio.schedule(.deinit);
    text.schedule(.deinit);
    text_pipeline.schedule(.deinit);
    core.schedule(.deinit);
    app.state().parsed_atlas.deinit();
    app.state().parsed_level.deinit();
    app.state().rtt_texture_view.release();
}

fn init(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    card: *Card.Mod,
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
    card.schedule(.init);
    app.schedule(.after_init);
}

fn afterInit(
    entities: *mach.Entities.Mod,
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    app: *Mod,
    audio: *mach.Audio.Mod,
    card: *Card.Mod,
) !void {
    // Configure the audio module to send our app's .audio_state_change event when an entity's sound
    // finishes playing.
    audio.state().on_state_change = app.system(.audio_state_change);

    // Create a sprite rendering pipelines
    const allocator = gpa.allocator();

    const pipeline = try entities.new();
    try sprite_pipeline.set(pipeline, .texture, try loadTexture(core, allocator, assets.lordofzero_png));

    sprite_pipeline.schedule(.update);

    // Create a text rendering pipeline
    const text_pipeline_id = try entities.new();
    try text_pipeline.set(text_pipeline_id, .is_pipeline, {});
    text_pipeline.schedule(.update);

    // Load pixi atlas file
    const parsed_atlas = try pixi.Atlas.parseSlice(allocator, assets.lordofzero_atlas);
    std.debug.print("loaded sprite atlas: {} sprites, {} animations\n", .{ parsed_atlas.value.sprites.len, parsed_atlas.value.animations.len });

    const parsed_ldtk_compatibility = try pixi.LDTKCompatibility.parseSlice(allocator, assets.pixi_ldtk_json);

    // Preload .ldtk level file
    const parsed_level = try ldtk.File.parseSlice(allocator, assets.level_ldtk);

    // Create the texture we'll render our scene to for post-processing effects.
    const fb_width = core.get(core.state().main_window, .framebuffer_width).?;
    const fb_height = core.get(core.state().main_window, .framebuffer_height).?;
    const rtt_texture = core.state().device.createTexture(&gpu.Texture.Descriptor.init(.{
        .size = .{ .width = fb_width, .height = fb_height },
        .format = .bgra8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true, .render_attachment = true },
    }));
    const rtt_texture_view = rtt_texture.createView(null);

    // TODO: cleanup/remove
    // rtt_texture_view.reference();
    const rtt_card = try entities.new();
    try app.set(rtt_card, .is_rtt_card, {});

    const pass1 = try std.fs.cwd().readFileAllocOptions(std.heap.c_allocator, "src/pass1.wgsl", std.math.maxInt(usize), null, @alignOf(u8), 0);
    try card.set(rtt_card, .shader, core.state().device.createShaderModuleWGSL("pass1.wgsl", pass1));

    // try card.set(rtt_card, .shader, core.state().device.createShaderModuleWGSL("pass1.wgsl", @embedFile("pass1.wgsl")));
    try card.set(rtt_card, .texture_view, rtt_texture_view);
    try card.set(rtt_card, .texture_view_size, vec2(@floatFromInt(rtt_texture.getWidth()), @floatFromInt(rtt_texture.getHeight())));
    try card.set(rtt_card, .blend_state, gpu.BlendState{});

    try card.set(rtt_card, .uv_transform, Mat3x3.translate(vec2(0, 0)));
    try card.set(rtt_card, .render_pass_id, 1);
    try card.set(rtt_card, .transform, Mat4x4.translate(vec3(0, 0, 0)));
    // TODO: why can't we schedule this here
    // card.schedule(.update_pipelines);

    const player = try entities.new();
    app.init(.{
        .player = player,
        .attack_cooldown_timer = try mach.Timer.start(),
        .timer = try mach.Timer.start(),
        .delta_timer = try mach.Timer.start(),
        .spawn_timer = try mach.Timer.start(),
        .fps_timer = try mach.Timer.start(),
        .player_sprite_timer = try mach.Timer.start(),
        .frame_count = 0,
        .rand = std.rand.DefaultPrng.init(1337),
        .time = 0,
        .allocator = allocator,
        .pipeline = pipeline,
        .text_pipeline = text_pipeline_id,
        .parsed_atlas = parsed_atlas,
        .parsed_level = parsed_level,
        .parsed_ldtk_compatibility = parsed_ldtk_compatibility,
        .rtt_texture_view = rtt_texture_view,
    });

    // Load the initial starting screen scene
    app.schedule(.change_scene);

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
                app.schedule(.change_scene);
            }
        }
    }
}

fn changeScene(
    sprite: *gfx.Sprite.Mod,
    app: *Mod,
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
    text: *gfx.Text.Mod,
    text_style: *gfx.TextStyle.Mod,
    card: *Card.Mod,
    core: *mach.Core.Mod,
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

    // TODO: due to a bug in mach's module system we need this here. Need to investigate.
    @setEvalBranchQuota(10_000);

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

                const logo_sprite = try entities.new();
                const position = vec3(
                    -220,
                    140,
                    z_layer,
                );
                z_layer += 1;

                try SpriteCalc.apply(sprite, logo_sprite, .{
                    .sprite_info = sprite_info,
                    .pos = position,
                    .scale = Vec3.splat(start_scale),
                    .flipped = false,
                });

                try sprite.set(logo_sprite, .pipeline, app.state().pipeline);
                try app.set(logo_sprite, .pixi_sprite, sprite_info);
                try app.set(logo_sprite, .is_start_scene, {}); // This entity belongs to the start scene
                try app.set(logo_sprite, .is_logo, {}); // This entity belongs to the start scene
            }

            const lordofzero_png_texture = try loadTexture(core, app.state().allocator, assets.lordofzero_png);
            defer lordofzero_png_texture.release();
            const bg_card = try entities.new();
            try card.set(bg_card, .shader, core.state().device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl")));
            try card.set(bg_card, .texture_view, lordofzero_png_texture.createView(null));
            try card.set(bg_card, .texture_view_size, vec2(@floatFromInt(lordofzero_png_texture.getWidth()), @floatFromInt(lordofzero_png_texture.getHeight())));
            try card.set(bg_card, .transform, Mat4x4.translate(vec3(-1920 / 2, -1080 / 2, 0)));
            try card.set(bg_card, .uv_transform, Mat3x3.translate(vec2(0, 0)));
            try card.set(bg_card, .size, vec2(1920, 1080));
            try card.set(bg_card, .render_pass_id, 0);
            try app.set(bg_card, .is_start_scene, {}); // This entity belongs to the start scene
            card.schedule(.update_pipelines);
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

            // Find the LDTK level "Level_0"
            const level = blk: {
                for (app.state().parsed_level.value.worlds[0].levels) |level| {
                    if (std.mem.eql(u8, level.identifier, "Level_0")) break :blk level;
                }
                @panic("could not find level");
            };

            // Create the "Wrench" player sprite
            app.state().player_position = blk: {
                var z_layer: f32 = 0;
                for (level.layerInstances.?) |layer| {
                    for (layer.entityInstances) |layer_entity| {
                        for (layer_entity.__tags) |tag| {
                            if (!std.mem.eql(u8, tag, "player_start")) continue;

                            // TODO: account for optional layer offsets, if they exist
                            const entity_pos_x: f32 = @floatFromInt(layer_entity.px[0]);
                            const entity_pos_y: f32 = @floatFromInt(layer_entity.px[1]);
                            const entity_width: f32 = @floatFromInt(layer_entity.width);
                            const entity_height: f32 = @floatFromInt(layer_entity.height);
                            break :blk vec3(
                                (entity_pos_x + (entity_width / 2.0)) * world_scale,
                                -((entity_pos_y) + entity_height) * world_scale,
                                z_layer,
                            );
                        }
                    }
                    z_layer += 10000;
                }
                @panic("could not find entity in level tagged 'player_start'");
            };

            const atlas: pixi.Atlas = app.state().parsed_atlas.value;
            const pixi_ldtk: pixi.LDTKCompatibility = app.state().parsed_ldtk_compatibility.value;

            for (atlas.sprites) |sprite_info| {
                if (!std.mem.startsWith(u8, sprite_info.name, "wrench_idle")) continue;

                try SpriteCalc.apply(sprite, app.state().player, .{
                    .sprite_info = sprite_info,
                    .pos = app.state().player_position,
                    .scale = Vec3.splat(world_scale),
                    .flipped = false,
                });
                try sprite.set(app.state().player, .pipeline, app.state().pipeline);
                try app.set(app.state().player, .is_game_scene, {});
                break;
            }

            std.debug.print("loading level: {s} {}x{}px, layers: {}\n", .{ level.identifier, level.pxWid, level.pxHei, level.layerInstances.?.len });
            var z_layer: f32 = 0.0;
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
                if (!layer.visible) continue;
                if (layer.__pxTotalOffsetX != 0 or layer.__pxTotalOffsetY != 0) {
                    @panic("layer offsets not supported yet");
                }

                const parallax: ?[2]f32 = blk: {
                    for (app.state().parsed_level.value.defs.layers) |layer_def| {
                        if (layer_def.uid == layer.layerDefUid) {
                            if (layer_def.parallaxFactorX == 0 and layer_def.parallaxFactorY == 0) break :blk null;
                            if (layer_def.parallaxScaling) std.debug.panic("parallax /scaling/ is not supported, found enabled on layer: {s}", .{layer.__identifier});
                            break :blk .{ layer_def.parallaxFactorX, layer_def.parallaxFactorY };
                        }
                    }
                    break :blk null;
                };

                if (parallax != null) {
                    const layer_width: f32 = @floatFromInt(layer.__gridSize * layer.__cWid);
                    const layer_height: f32 = @floatFromInt(layer.__gridSize * layer.__cHei);
                    std.debug.print("making layer: {}x{}\n", .{ layer_width, layer_height });

                    const lordofzero_png_texture = try loadTexture(core, app.state().allocator, assets.lordofzero_png);
                    defer lordofzero_png_texture.release();
                    const bg_card = try entities.new();
                    try card.set(bg_card, .shader, core.state().device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl")));
                    try card.set(bg_card, .texture_view, lordofzero_png_texture.createView(null));
                    try card.set(bg_card, .texture_view_size, vec2(@floatFromInt(lordofzero_png_texture.getWidth()), @floatFromInt(lordofzero_png_texture.getHeight())));
                    try card.set(bg_card, .transform, Mat4x4.translate(vec3(0, -layer_height * world_scale, 0)));
                    try card.set(bg_card, .uv_transform, Mat3x3.translate(vec2(0, 0)));
                    try card.set(bg_card, .size, vec2(layer_width * world_scale, layer_height * world_scale));
                    try card.set(bg_card, .render_pass_id, 0);
                    try app.set(bg_card, .is_game_scene, {}); // This entity belongs to the start scene

                    card.schedule(.update_pipelines);
                }

                building_tiles: for (layer.gridTiles) |tile| {
                    // Find the pixi sprite corresponding to this tile
                    if (pixi_ldtk.findSpriteByLayerSrc(layer.__tilesetRelPath.?, tile.src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            const tile_sprite = try entities.new();
                            const pos = vec3(
                                @as(f32, @floatFromInt(tile.px[0])) * world_scale,
                                -@as(f32, @floatFromInt(tile.px[1])) * world_scale,
                                z_layer,
                            );
                            z_layer -= 1;

                            const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            const anim_frame = if (anim_info) |anim| app.state().rand.random().uintLessThan(usize, @min(2, anim.length)) else 0;
                            const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            try SpriteCalc.apply(sprite, tile_sprite, .{
                                .sprite_info = sprite_info,
                                .pos = pos,
                                .scale = Vec3.splat(world_scale),
                                .flipped = false,
                            });
                            try sprite.set(tile_sprite, .pipeline, app.state().pipeline);
                            try app.set(tile_sprite, .pixi_sprite, sprite_info);
                            try app.set(tile_sprite, .is_game_scene, {});
                            try app.set(tile_sprite, .is_tile, {}); // This entity is an LDTK tile
                            try app.set(tile_sprite, .sprite_flipped, false);
                            try app.set(tile_sprite, .position, pos);

                            if (anim_info) |anim| {
                                try app.set(tile_sprite, .sprite_anim, anim);
                                try app.set(tile_sprite, .sprite_timer, @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            }
                            if (parallax) |p| {
                                try app.set(tile_sprite, .parallax, p);
                            }
                        }
                    } else {
                        // std.debug.panic("failed to find sprite for tile: {}\n", .{tile});
                    }
                    continue :building_tiles;
                }

                building_entities: for (layer.entityInstances) |entity_instance| {
                    const tile = entity_instance.__tile orelse continue :building_entities;

                    for (entity_instance.__tags) |tag| {
                        if (std.mem.eql(u8, tag, "player_start") or std.mem.eql(u8, tag, "peasant_start") or std.mem.eql(u8, tag, "hidden")) {
                            continue :building_entities;
                        }
                    }

                    const tilesetRelPath = blk: {
                        for (app.state().parsed_level.value.defs.tilesets) |tileset_def| {
                            if (tileset_def.uid != tile.tilesetUid) continue;
                            break :blk tileset_def.relPath;
                        }
                        @panic("failed to find tileset for entity");
                    };

                    // Find the pixi sprite corresponding to the entity tile
                    const tile_src: [2]i64 = .{ tile.x, tile.y };
                    if (pixi_ldtk.findSpriteByLayerSrc(tilesetRelPath.?, tile_src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            const tile_sprite = try entities.new();
                            const pos = vec3(
                                @as(f32, @floatFromInt(entity_instance.px[0])) * world_scale,
                                -@as(f32, @floatFromInt(entity_instance.px[1])) * world_scale,
                                z_layer,
                            );
                            z_layer -= 1;

                            const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            const anim_frame = if (anim_info) |anim| app.state().rand.random().uintLessThan(usize, @min(2, anim.length)) else 0;
                            const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            try SpriteCalc.apply(sprite, tile_sprite, .{
                                .sprite_info = sprite_info,
                                .pos = pos,
                                .scale = Vec3.splat(world_scale),
                                .flipped = false,
                            });
                            try sprite.set(tile_sprite, .pipeline, app.state().pipeline);
                            try app.set(tile_sprite, .pixi_sprite, sprite_info);
                            try app.set(tile_sprite, .is_game_scene, {});
                            try app.set(tile_sprite, .is_entity, {}); // This entity is an LDTK entity
                            try app.set(tile_sprite, .sprite_flipped, false);
                            try app.set(tile_sprite, .position, pos);

                            if (anim_info) |anim| {
                                try app.set(tile_sprite, .sprite_anim, anim);
                                try app.set(tile_sprite, .sprite_timer, @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            }
                        }
                    } else {
                        std.debug.panic("failed to find sprite for entity tile: {}\n", .{tile});
                    }
                }

                z_layer += 10000;
            }
        },
    }
}

fn updateAnims(sprite: *gfx.Sprite.Mod, app: *Mod, entities: *mach.Entities.Mod) !void {
    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .anims = Mod.read(.sprite_anim),
        .timers = Mod.write(.sprite_timer),
        .flips = Mod.read(.sprite_flipped),
        .positions = Mod.read(.position),
        .pixi_sprites = Mod.write(.pixi_sprite),
    });
    while (q.next()) |v| {
        for (v.ids, v.anims, v.timers, v.flips, v.positions, v.pixi_sprites) |id, anim, *timer, flip, position, *pixi_sprite| {
            const atlas = app.state().parsed_atlas.value;
            const anim_fps: f32 = @floatFromInt(anim.fps);

            timer.* += app.state().delta_time;
            var frame = @as(usize, @intFromFloat(timer.* * anim_fps));

            if (frame > anim.length - 1) {
                if (app.get(id, .sprite_delete_after_anim) != null) {
                    try entities.remove(id);
                    continue;
                } else {
                    frame = frame % anim.length;
                }
            }

            pixi_sprite.* = atlas.sprites[anim.start + frame];
            try SpriteCalc.apply(sprite, id, .{
                .sprite_info = pixi_sprite.*,
                .pos = position,
                .scale = Vec3.splat(world_scale),
                .flipped = flip,
            });
        }
    }
}

fn tick(
    app: *Mod,
    sprite: *gfx.Sprite.Mod,
    card: *Card.Mod,
) !void {
    app.schedule(.poll_input);
    switch (app.state().scene) {
        .none => {},
        .start => app.schedule(.update_start_scene),
        .game => app.schedule(.update_game_scene),
    }
    app.schedule(.update_anims);
    sprite.schedule(.update);
    card.state().time = app.state().time;
    card.schedule(.update);
    app.schedule(.update_camera);
    app.schedule(.render_frame);
}

fn pollInput(
    core: *mach.Core.Mod,
    app: *Mod,
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
) !void {
    var iter = mach.core.pollEvents();
    var direction = app.state().direction;
    var player_wants_to_attack = app.state().player_wants_to_attack;
    var player_wants_to_run = app.state().player_wants_to_run;
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => player_wants_to_attack = true,
                    .left_shift => player_wants_to_run = true,
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
                    .left_shift => player_wants_to_run = false,
                    else => {},
                }
            },
            .close => core.schedule(.exit),
            else => {},
        }
    }
    app.state().last_direction = app.state().direction;
    app.state().direction = direction;
    app.state().player_wants_to_attack = player_wants_to_attack;
    app.state().player_wants_to_run = player_wants_to_run;

    const dt = app.state().delta_timer.lap();
    app.state().delta_time = dt;
    defer app.state().time += dt;
}

fn updateStartScene(
    app: *Mod,
    entities: *mach.Entities.Mod,
) !void {
    // Make the logo sprites (there are multiple, one for each 'sprite layer' in pixi) bounce up and down slowly
    var q = try entities.query(.{
        .is_logo = Mod.read(.is_logo),
        .transforms = gfx.Sprite.Mod.write(.transform),
        .sprite_infos = Mod.read(.pixi_sprite),
    });
    while (q.next()) |v| {
        for (v.transforms, v.sprite_infos) |*transform, sprite_info| {
            const pos = vec3(
                0,
                (10 * math.sin((app.state().timer.read() / 8.0) * 2 * std.math.pi)),
                transform.translation().z(),
            );
            const calc = SpriteCalc.init(.{
                .sprite_info = sprite_info,
                .pos = pos,
                .scale = Vec3.splat(start_scale),
                .flipped = false,
            });
            transform.* = calc.transform;
        }
    }
}

fn updateGameScene(
    sprite: *gfx.Sprite.Mod,
    app: *Mod,
    entities: *mach.Entities.Mod,
    audio: *mach.Audio.Mod,
) !void {
    const can_attack = app.state().attack_cooldown_timer.read() > app.state().attack_cooldown;
    const begin_moving = !app.state().is_attacking and app.state().last_direction.eql(&vec2(0, 0)) and !app.state().direction.eql(&vec2(0, 0));
    const begin_attack = !app.state().is_attacking and can_attack and app.state().player_wants_to_attack;

    if (begin_attack) {
        app.state().attack_cooldown_timer.reset();
        app.state().is_attacking = true;
    }
    if (begin_moving or begin_attack) {
        app.state().player_sprite_timer.reset();
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
    const animation_info = animationByName(atlas, animation_name).?;

    var end_attack: bool = false;

    // Determine the next player animation frame
    var animation_fps: f32 = @floatFromInt(animation_info.fps);
    if (app.state().player_wants_to_run) animation_fps *= 2;
    var i: usize = @intFromFloat(app.state().player_sprite_timer.read() * animation_fps);
    if (i >= animation_info.length) {
        app.state().player_sprite_timer.reset();
        i = 0;

        if (app.state().is_attacking) {
            app.state().is_attacking = false;
            end_attack = true;
        }
    }

    // Player moves in the direction of the keyboard input
    const dir = if (app.state().is_attacking) app.state().direction.mulScalar(0.5) else app.state().direction;
    if (!dir.eql(&vec2(0, 0))) {
        app.state().last_facing_direction = dir;
    }
    const base_speed = 250.0;
    const speed: f32 = if (app.state().player_wants_to_run) base_speed * 10.0 else base_speed;
    const pos = app.state().player_position.add(
        &vec3(dir.v[0], 0, 0).mulScalar(speed).mulScalar(app.state().delta_time),
    );
    app.state().player_position = pos;

    // If the player is moving left instead of right, then flip the sprite so it renders
    // facing the left instead of its natural right-facing direction.
    const flipped: bool = app.state().last_facing_direction.v[0] < 0;
    const player = app.state().player;
    try SpriteCalc.apply(sprite, player, .{
        .sprite_info = atlas.sprites[animation_info.start + i],
        .pos = pos,
        .scale = Vec3.splat(world_scale),
        .flipped = flipped,
    });

    if (end_attack) {
        const attack_fx = try entities.new();
        const anim_info = animationByName(atlas, "ground_attack_main").?;

        const z_layer: f32 = 0;
        const position: Vec3 = vec3(
            if (app.state().last_facing_direction.v[0] >= 0) pos.v[0] + 128.0 else pos.v[0] - 64.0,
            pos.v[1],
            z_layer,
        );

        const sprite_info = atlas.sprites[anim_info.start];
        try SpriteCalc.apply(sprite, attack_fx, .{
            .sprite_info = sprite_info,
            .pos = position,
            .scale = Vec3.splat(world_scale),
            .flipped = flipped,
        });
        try sprite.set(attack_fx, .pipeline, app.state().pipeline);
        try app.set(attack_fx, .is_game_scene, {});
        try app.set(attack_fx, .sprite_anim, animationByName(atlas, "ground_attack_main").?);
        try app.set(attack_fx, .sprite_delete_after_anim, {});
        try app.set(attack_fx, .sprite_timer, 0);
        try app.set(attack_fx, .sprite_flipped, flipped);
        try app.set(attack_fx, .pixi_sprite, sprite_info);
        try app.set(attack_fx, .position, position);
    }

    if (i != app.state().player_anim_frame) {
        // Player animation frame has changed
        app.state().player_anim_frame = @intCast(i);

        // If walking, play footstep sfx every 2nd frame
        if (!app.state().is_attacking and !dir.eql(&vec2(0, 0)) and
            ((app.state().player_wants_to_run and i % 1 == 0) or (!app.state().player_wants_to_run and i % 2 == 0)))
        {
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
            try audio.set(sfx_entity, .volume, 2.3);
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
}

fn updateCamera(
    entities: *mach.Entities.Mod,
    sprite: *gfx.Sprite.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    app: *Mod,
    card: *Card.Mod,
    core: *mach.Core.Mod,
) !void {
    _ = core; // autofix
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

    // Smooth camera following
    const map_left = 800;
    const map_right = 18950 * 3;
    const camera_target = switch (app.state().scene) {
        .none => vec3(0, 0, 0),
        .start => vec3(0, 0, 0),
        .game => vec3(
            math.clamp(app.state().player_position.x(), map_left, map_right),
            app.state().player_position.y() + (height_px / 4),
            0,
        ),
    };
    const camera_target_diff = camera_target.sub(&app.state().camera_position);
    const camera_lag_seconds = 0.5;
    app.state().camera_position = app.state().camera_position.add(&camera_target_diff.mulScalar(app.state().delta_time / camera_lag_seconds));

    const view = Mat4x4.translate(app.state().camera_position.mulScalar(-1));
    const view_projection = projection.mul(&view);
    try sprite_pipeline.set(app.state().pipeline, .view_projection, view_projection);
    try text_pipeline.set(app.state().pipeline, .view_projection, view_projection);

    {
        var q = try entities.query(.{
            .ids = mach.Entities.Mod.read(.id),
            .card_transforms = Card.Mod.read(.transform),
        });
        while (q.next()) |v| {
            for (v.ids) |card_id| {
                if (app.get(card_id, .is_rtt_card) == null) {
                    try card.set(card_id, .view_projection, view_projection);
                } else {
                    try card.set(card_id, .view_projection, projection);
                    try card.set(card_id, .transform, Mat4x4.translate(vec3(
                        -width_px / 2,
                        -height_px / 2,
                        0,
                    )));
                    try card.set(card_id, .size, vec2(width_px, height_px));
                }
            }
        }
    }

    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .parallaxes = Mod.read(.parallax),
        .flips = Mod.read(.sprite_flipped),
        .positions = Mod.read(.position),
        .pixi_sprites = Mod.read(.pixi_sprite),
    });
    while (q.next()) |v| {
        for (v.ids, v.parallaxes, v.flips, v.positions, v.pixi_sprites) |id, parallax, flip, position, pixi_sprite| {
            // TODO: cleanup and/or remove this code
            //
            // const atlas = app.state().parsed_atlas.value;
            // const anim_fps: f32 = @floatFromInt(anim.fps);

            // timer.* += app.state().delta_time;
            // var frame = @as(usize, @intFromFloat(timer.* * anim_fps));

            // if (frame > anim.length - 1) {
            //     if (app.get(id, .sprite_delete_after_anim) != null) {
            //         try entities.remove(id);
            //         continue;
            //     } else {
            //         frame = frame % anim.length;
            //     }
            // }

            // var parallax2 = parallax;
            // if (parallax2[0] != 0) {
            //     parallax2[0] = 0.3;
            //     parallax2[1] = 0.3;
            // }
            // const win_width = 1920.0 * (3.0 / 4.0);
            // std.debug.print("camera position: {d:.02}\n", .{app.state().camera_position.v});

            const win_width = 0;
            const parallax2 = parallax;
            try SpriteCalc.apply(sprite, id, .{
                .sprite_info = pixi_sprite,
                .pos = position.sub(&app.state().camera_position.add(&vec3(-(win_width * 8.0), 0, 0)).mul(&vec3(parallax2[0], parallax2[1], 1))),
                .scale = Vec3.splat(world_scale),
                .flipped = flip,
            });
        }
    }
}

fn renderFrame(
    core: *mach.Core.Mod,
    sprite_pipeline: *gfx.SpritePipeline.Mod,
    text_pipeline: *gfx.TextPipeline.Mod,
    card: *Card.Mod,
    app: *Mod,
) !void {
    // Create a command encoder for this frame
    const label = @tagName(name) ++ ".tick";
    app.state().frame_encoder = core.state().device.createCommandEncoder(&.{ .label = label });

    const dark_gray = gpu.Color{ .r = 0.106, .g = 0.11, .b = 0.118, .a = 1 };
    const sky_blue = gpu.Color{ .r = 0.529, .g = 0.808, .b = 0.922, .a = 1 };
    _ = sky_blue; // autofix

    // Begin a render pass that will render our scene to a texture (rtt == render to texture)
    const rtt_color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = app.state().rtt_texture_view,
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
        .color_attachments = &rtt_color_attachments,
    }));

    // Perform pre-render work
    card.schedule(.pre_render);
    sprite_pipeline.schedule(.pre_render);
    text_pipeline.schedule(.pre_render);

    // Render our sprite batch
    sprite_pipeline.state().render_pass = app.state().frame_render_pass;
    sprite_pipeline.schedule(.render);

    // Render our text batch
    text_pipeline.state().render_pass = app.state().frame_render_pass;
    text_pipeline.schedule(.render);

    // Render cards
    card.state().render_pass_id = 0;
    card.state().render_pass = app.state().frame_render_pass;
    card.schedule(.render);

    app.schedule(.post_process);
}

fn postProcess(
    card: *Card.Mod,
    app: *Mod,
) !void {
    const label = @tagName(name) ++ ".tick";

    app.state().frame_render_pass.end();
    app.state().frame_render_pass.release();

    // Grab the back buffer of the swapchain
    const back_buffer_view = mach.core.swap_chain.getCurrentTextureView().?;
    defer back_buffer_view.release();

    // Begin render pass
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    }};
    app.state().frame_render_pass = app.state().frame_encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));

    // Perform pre-render work
    card.schedule(.pre_render);

    // Render cards
    card.state().render_pass_id = 1;
    card.state().render_pass = app.state().frame_render_pass;
    card.schedule(.render);

    app.schedule(.finish_frame);
}

fn finishFrame(app: *Mod, core: *mach.Core.Mod) !void {
    // Finish render pass
    app.state().frame_render_pass.end();
    const label = @tagName(name) ++ ".finishFrame";
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

fn loadTexture(core: *mach.Core.Mod, allocator: std.mem.Allocator, png_bytes: []const u8) !*gpu.Texture {
    const device = core.state().device;
    const queue = core.state().queue;

    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, png_bytes);
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

fn animationByName(atlas: pixi.Atlas, anim_name: []const u8) ?pixi.Animation {
    for (atlas.animations) |anim| if (std.mem.eql(u8, anim.name, anim_name)) return anim;
    return null;
}

fn animationBySpriteIndex(atlas: pixi.Atlas, sprite_index: usize) ?pixi.Animation {
    for (atlas.animations) |anim| {
        if (sprite_index >= anim.start and sprite_index <= (anim.start + anim.length - 1)) return anim;
    }
    return null;
}

const SpriteCalc = struct {
    transform: Mat4x4,
    uv_transform: Mat3x3,
    size: Vec2,

    pub const Input = struct {
        sprite_info: pixi.Sprite,
        pos: Vec3,
        scale: Vec3,
        flipped: bool,
    };

    fn init(in: Input) SpriteCalc {
        const x: f32 = @floatFromInt(in.sprite_info.source[0]);
        const y: f32 = @floatFromInt(in.sprite_info.source[1]);
        const width: f32 = @floatFromInt(in.sprite_info.source[2]);
        const height: f32 = @floatFromInt(in.sprite_info.source[3]);
        const origin_x: f32 = @floatFromInt(in.sprite_info.origin[0]);
        const origin_y: f32 = @floatFromInt(in.sprite_info.origin[1]);

        const origin = Mat4x4.translate(vec3(
            if (!in.flipped) -origin_x else -width + origin_x,
            -height + origin_y,
            0,
        ));
        const scale = Mat4x4.scale(in.scale);
        const translate = Mat4x4.translate(in.pos);

        var uv_transform = Mat3x3.translate(vec2(x, y));
        if (in.flipped) {
            const uv_flip_horizontally = Mat3x3.scale(vec2(-1, 1));
            const uv_origin_shift = Mat3x3.translate(vec2(width, 0));
            const uv_translate = Mat3x3.translate(vec2(x, y));
            uv_transform = uv_origin_shift.mul(&uv_translate).mul(&uv_flip_horizontally);
        }

        return .{
            .transform = translate.mul(&scale).mul(&origin),
            .uv_transform = uv_transform,
            .size = vec2(width, height),
        };
    }

    fn apply(sprite: *gfx.Sprite.Mod, entity: mach.EntityID, in: Input) !void {
        const calc = SpriteCalc.init(in);
        try sprite.set(entity, .transform, calc.transform);
        try sprite.set(entity, .uv_transform, calc.uv_transform);
        try sprite.set(entity, .size, calc.size);
    }
};
