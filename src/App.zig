const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const time = mach.time;
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

const App = @This();

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .tick,
    .deinit,
    .deinit2,
    .audioStateChange,
    .pollInput,
    .changeScene,
    .updateScene,
    .updateSceneStart,
    .updateSceneGame,
    .updateAnims,
    .updateSfx,
    .updateCamera,
    .renderFrame,
};

pub const mach_tags = .{
    .is_start_scene,
    .is_game_scene,
    .is_bgm,
    .is_sfx,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ mach.Audio, .init },
    .{ gfx.Text, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ mach.Audio, .deinit },
    .{ App, .deinit2 },
});

pub const tick = mach.schedule(.{
    .{ App, .pollInput },
    .{ App, .updateScene },
    .{ App, .updateAnims },
    .{ App, .updateSfx },
    .{ App, .updateCamera },
    .{ App, .renderFrame },
});

const Scene = enum {
    none,
    start,
    game,
};

const start_scale = 3.0;
const world_scale = 2.0;

// Initialized by App.init
allocator: std.mem.Allocator,
window_id: mach.ObjectID,
direction: Vec2 = vec2(0, 0),
last_direction: Vec2 = vec2(0, 0),
last_facing_direction: Vec2 = vec2(0, 0),
player_position: Vec3 = vec3(0, 0, 0), // z == player layer
camera_position: Vec3 = vec3(0, 0, 0),
player_wants_to_attack: bool = false,
player_wants_to_run: bool = false,
attack_cooldown: f32 = 1.0,
attack_cooldown_timer: time.Timer,
is_attacking: bool = false,
timer: time.Timer,
delta_timer: time.Timer,
spawn_timer: time.Timer,
fps_timer: time.Timer,
player_sprite_timer: time.Timer,
delta_time: f32 = 0,
player_anim_frame: isize = -1,
frame_count: usize = 0,
fps: usize = 0,
rand: std.Random.DefaultPrng,
world_time: f32 = 0,
scene: Scene = .start,
prev_scene: Scene = .none,

// Initializewd by setupPipeline
player_id: mach.ObjectID = undefined,
rtt_card_pipeline_id: mach.ObjectID = undefined,
rtt_card_id: mach.ObjectID = undefined,
sprite_pipeline_id: mach.ObjectID = undefined,
text_pipeline_id: mach.ObjectID = undefined,
info_text_id: mach.ObjectID = undefined,
parsed_atlas: pixi.ParsedAtlas = undefined,
parsed_level: ldtk.ParsedFile = undefined,
parsed_ldtk_compatibility: pixi.ParsedLDTKCompatibility = undefined,
rtt_texture_view: *gpu.TextureView = undefined,

pub fn init(
    core: *mach.Core,
    audio: *mach.Audio,
    app: *App,
    app_mod: mach.Mod(App),
) !void {
    core.on_tick = app_mod.id.tick;
    core.on_exit = app_mod.id.deinit;

    // Configure the audio module to call our App.audioStateChange function when a sound buffer
    // finishes playing.
    audio.on_state_change = app_mod.id.audioStateChange;

    const window_id = try core.windows.new(.{
        .title = "Lord of Zero",
        .width = 1920.0 * (3.0 / 4.0),
        .height = 1080.0 * (3.0 / 4.0),
        // Make the window fullscreen before it opens, if you want:
        // .fullscreen = true,
    });

    // TODO(allocator): find a better way to get an allocator here
    const allocator = std.heap.c_allocator;

    app.* = .{
        .allocator = allocator,
        .window_id = window_id,
        .attack_cooldown_timer = try time.Timer.start(),
        .timer = try time.Timer.start(),
        .delta_timer = try time.Timer.start(),
        .spawn_timer = try time.Timer.start(),
        .fps_timer = try time.Timer.start(),
        .player_sprite_timer = try time.Timer.start(),
        .rand = std.Random.DefaultPrng.init(1337),
    };
}

pub fn deinit2(
    app: *App,
    text: *gfx.Text,
) void {
    // TODO: properly cleanup:
    // card.schedule(.deinit);
    // sprite_pipeline.schedule(.deinit);
    // audio.schedule(.deinit);
    // text.schedule(.deinit);
    // text_pipeline.schedule(.deinit);
    // core.schedule(.deinit);
    text.objects.delete(app.info_text_id);
    app.parsed_atlas.deinit();
    app.parsed_level.deinit();
    app.rtt_texture_view.release();
}

fn setupPipeline(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    card: *Card,
    text: *gfx.Text,
    window_id: mach.ObjectID,
) !void {
    const window = core.windows.getValue(window_id);

    // Load pixi atlas file
    app.parsed_atlas = try pixi.Atlas.parseSlice(app.allocator, assets.lordofzero_atlas);
    std.debug.print("loaded sprite atlas: {} sprites, {} animations\n", .{
        app.parsed_atlas.value.sprites.len,
        app.parsed_atlas.value.animations.len,
    });

    app.parsed_ldtk_compatibility = try pixi.LDTKCompatibility.parseSlice(app.allocator, assets.pixi_ldtk_json);

    // Preload .ldtk level file
    app.parsed_level = try ldtk.File.parseSlice(app.allocator, assets.level_ldtk);

    // Create the texture we'll render our scene to for post-processing effects.
    const fb_width = window.framebuffer_width;
    const fb_height = window.framebuffer_height;
    const rtt_texture = window.device.createTexture(&gpu.Texture.Descriptor.init(.{
        .size = .{ .width = fb_width, .height = fb_height },
        .format = .bgra8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true, .render_attachment = true },
    }));
    app.rtt_texture_view = rtt_texture.createView(null);
    // TODO: cleanup/remove
    // rtt_texture_view.reference();

    // Create render-to-texture card
    const pass1 = try std.fs.cwd().readFileAllocOptions(app.allocator, "src/pass1.wgsl", std.math.maxInt(usize), null, @alignOf(u8), 0);
    app.rtt_card_pipeline_id = try card.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture_view = app.rtt_texture_view,
        .texture_view_size = vec2(
            @floatFromInt(rtt_texture.getWidth()),
            @floatFromInt(rtt_texture.getHeight()),
        ),
        .shader = window.device.createShaderModuleWGSL("pass1.wgsl", pass1),
        .blend_state = gpu.BlendState{},
    });
    app.rtt_card_id = try card.objects.new(.{
        .transform = Mat4x4.translate(vec3(0, 0, 0)),
        .uv_transform = Mat3x3.translate(vec2(0, 0)),
        .size = vec2(
            @floatFromInt(rtt_texture.getWidth()),
            @floatFromInt(rtt_texture.getHeight()),
        ),
    });

    // Load the initial starting screen scene
    app_mod.call(.changeScene);

    // Create a sprite rendering pipeline
    app.sprite_pipeline_id = try sprite.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture = try loadTexture(window.device, window.queue, app.allocator, assets.lordofzero_png),
    });

    // Create a text rendering pipeline
    app.text_pipeline_id = try text.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
    });
}

/// Called on the high-priority audio OS thread when the audio driver needs more audio samples, so
/// this callback should be fast to respond.
pub fn audioStateChange(audio: *mach.Audio, app: *App) !void {
    audio.buffers.lock();
    defer audio.buffers.unlock();

    // Find audio objects that are no longer playing
    var buffers = audio.buffers.slice();
    while (buffers.next()) |buf_id| {
        if (audio.buffers.get(buf_id, .playing)) continue;

        if (audio.buffers.hasTag(buf_id, App, .is_bgm)) {
            // Repeat background music
            audio.buffers.set(buf_id, .index, 0);
            audio.buffers.set(buf_id, .playing, true);
        } else {
            // Remove the audio buffer that is no longer playing
            const samples = audio.buffers.get(buf_id, .samples);
            audio.buffers.delete(buf_id);
            app.allocator.free(samples);

            // TODO(audio)
            // // If any entity had this sound as a child_sfx, then remove it now so there is no
            // // dangling reference.
            // var q2 = try entities.query(.{
            //     .ids = mach.Entities.Mod.read(.id),
            //     .child_sfx = Mod.read(.child_sfx),
            // });
            // while (q2.next()) |v2| {
            //     for (v2.ids, v2.child_sfx) |entity_id, child_sfx| {
            //         if (child_sfx == id) {
            //             try app.remove(entity_id, .child_sfx);
            //         }
            //     }
            // }
        }

        // TODO(audio)
        // if (app.get(id, .after_play_change_scene)) |scene| {
        //     app.scene = scene;
        //     app.schedule(.change_scene);
        // }
    }
}

// HERE

pub fn changeScene(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    card: *Card,
    core: *mach.Core,
) !void {
    _ = text; // autofix
    _ = card; // autofix
    if (app.prev_scene == app.scene) return;

    // Find and remove entities that belong to the previously active scene.
    switch (app.prev_scene) {
        .none => {},
        .start => {
            // TODO(query)
            //         var q = try entities.query(.{
            //             .ids = mach.Entities.Mod.read(.id),
            //             .is_start_scene = Mod.read(.is_start_scene),
            //         });
            //         while (q.next()) |v| {
            //             for (v.ids) |id| {
            //                 if (audio.get(id, .samples)) |buffer| app.allocator.free(buffer);
            //                 try entities.remove(id);
            //             }
            //         }
        },
        .game => {
            // TODO(query)
            //         var q = try entities.query(.{
            //             .ids = mach.Entities.Mod.read(.id),
            //             .is_game_scene = Mod.read(.is_game_scene),
            //         });
            //         while (q.next()) |v| {
            //             for (v.ids) |id| {
            //                 if (audio.get(id, .samples)) |buffer| app.allocator.free(buffer);
            //                 try entities.remove(id);
            //             }
            //         }
        },
    }
    app.prev_scene = app.scene;

    switch (app.scene) {
        .none => {},
        .start => {
            // Load our "prelude" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.prelude);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try audio.buffers.new(.{
                .samples = bgm.samples,
                .channels = bgm.channels,
                .playing = true,
            });
            try audio.buffers.setTag(bgm_entity, App, .is_start_scene, null);
            try audio.buffers.setTag(bgm_entity, App, .is_bgm, null);

            // TODO(text)
            //         const grey_block_color = vec4(0.604, 0.584, 0.525, 1.0);
            //         const style1 = try entities.new();
            //         try text_style.set(style1, .font_size, 48 * gfx.px_per_pt); // 48pt
            //         try text_style.set(style1, .font_color, grey_block_color);
            //         try app.set(style1, .is_start_scene, {}); // This entity belongs to the start scene

            //         // Create some text
            //         const text_id = try entities.new();
            //         try text.set(text_id, .pipeline, app.text_pipeline);
            //         try text.set(text_id, .transform, Mat4x4.translate(vec3(-100, -360, 0)));
            //         try gfx.Text.allocPrintText(text, text_id, style1, "Press any key to start", .{});
            //         text.schedule(.update);
            //         try app.set(text_id, .is_start_scene, {}); // This entity belongs to the start scene

            //         // Create some text
            //         const style2 = try entities.new();
            //         try text_style.set(style2, .font_size, 28 * gfx.px_per_pt); // 28pt
            //         try text_style.set(style2, .font_color, grey_block_color);
            //         try app.set(style2, .is_start_scene, {}); // This entity belongs to the start scene

            // TODO(rendering)
            //         // Create the "Lord of Zero" logo sprite
            //         var z_layer: f32 = 0;
            //         const atlas = app.parsed_atlas.value;
            //         for (atlas.sprites) |sprite_info| {
            //             if (!std.mem.startsWith(u8, sprite_info.name, "logo_0_")) continue;

            //             const logo_sprite = try entities.new();
            //             const position = vec3(
            //                 -220,
            //                 140,
            //                 z_layer,
            //             );
            //             z_layer += 1;

            //             try SpriteCalc.apply(sprite, logo_sprite, .{
            //                 .sprite_info = sprite_info,
            //                 .pos = position,
            //                 .scale = Vec3.splat(start_scale),
            //                 .flipped = false,
            //             });

            //             try sprite.set(logo_sprite, .pipeline, app.pipeline);
            //             try app.set(logo_sprite, .pixi_sprite, sprite_info);
            //             try app.set(logo_sprite, .is_start_scene, {}); // This entity belongs to the start scene
            //             try app.set(logo_sprite, .is_logo, {}); // This entity belongs to the start scene
            //         }

            //         const lordofzero_png_texture = try loadTexture(core, app.allocator, assets.lordofzero_png);
            //         defer lordofzero_png_texture.release();
            //         const bg_card = try entities.new();
            //         try card.set(bg_card, .shader, window.device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl")));
            //         try card.set(bg_card, .texture_view, lordofzero_png_texture.createView(null));
            //         try card.set(bg_card, .texture_view_size, vec2(@floatFromInt(lordofzero_png_texture.getWidth()), @floatFromInt(lordofzero_png_texture.getHeight())));
            //         try card.set(bg_card, .transform, Mat4x4.translate(vec3(-1920 / 2, -1080 / 2, 0)));
            //         try card.set(bg_card, .uv_transform, Mat3x3.translate(vec2(0, 0)));
            //         try card.set(bg_card, .size, vec2(1920, 1080));
            //         try card.set(bg_card, .render_pass_id, 0);
            //         try app.set(bg_card, .is_start_scene, {}); // This entity belongs to the start scene
            //         card.schedule(.update_pipelines);
        },
        .game => {
            // Load our "Morning Breaks" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.night_falls);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try audio.buffers.new(.{
                .samples = bgm.samples,
                .channels = bgm.channels,
                .playing = true,
            });
            try audio.buffers.setTag(bgm_entity, App, .is_game_scene, null);
            try audio.buffers.setTag(bgm_entity, App, .is_bgm, null);

            // Find the LDTK level "Level_0"
            const level = blk: {
                for (app.parsed_level.value.worlds[0].levels) |level| {
                    if (std.mem.eql(u8, level.identifier, "Level_0")) break :blk level;
                }
                @panic("could not find level");
            };

            // Create the "Wrench" player sprite
            app.player_position = blk: {
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
            const atlas: pixi.Atlas = app.parsed_atlas.value;
            const pixi_ldtk: pixi.LDTKCompatibility = app.parsed_ldtk_compatibility.value;
            for (atlas.sprites) |sprite_info| {
                if (!std.mem.startsWith(u8, sprite_info.name, "wrench_idle")) continue;

                app.player_id = try sprite.objects.new(.{
                    .transform = undefined,
                    .size = undefined,
                    .uv_transform = undefined,
                });
                try sprite.pipelines.setParent(app.player_id, app.sprite_pipeline_id);
                try SpriteCalc.apply(sprite, app.player_id, .{
                    .sprite_info = sprite_info,
                    .pos = app.player_position,
                    .scale = Vec3.splat(world_scale),
                    .flipped = false,
                });
                // TODO(important)
                // try app.set(app.player_id, .is_game_scene, {});
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
                    for (app.parsed_level.value.defs.layers) |layer_def| {
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

                    const device = core.windows.get(app.window_id, .device);
                    const queue = core.windows.get(app.window_id, .queue);
                    const lordofzero_png_texture = try loadTexture(device, queue, app.allocator, assets.lordofzero_png);
                    defer lordofzero_png_texture.release();

                    // TODO(rendering)
                    // const bg_card = try entities.new();
                    // try card.set(bg_card, .shader, window.device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl")));
                    // try card.set(bg_card, .texture_view, lordofzero_png_texture.createView(null));
                    // try card.set(bg_card, .texture_view_size, vec2(@floatFromInt(lordofzero_png_texture.getWidth()), @floatFromInt(lordofzero_png_texture.getHeight())));
                    // try card.set(bg_card, .transform, Mat4x4.translate(vec3(0, -layer_height * world_scale, 0)));
                    // try card.set(bg_card, .uv_transform, Mat3x3.translate(vec2(0, 0)));
                    // try card.set(bg_card, .size, vec2(layer_width * world_scale, layer_height * world_scale));
                    // try card.set(bg_card, .render_pass_id, 0);
                    // try app.set(bg_card, .is_game_scene, {}); // This entity belongs to the start scene

                    // card.schedule(.update_pipelines);
                }

                building_tiles: for (layer.gridTiles) |tile| {
                    // Find the pixi sprite corresponding to this tile
                    if (pixi_ldtk.findSpriteByLayerSrc(layer.__tilesetRelPath.?, tile.src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            _ = sprite_index; // autofix
                            // TODO(rendering)
                            // const tile_sprite = try entities.new();
                            // const pos = vec3(
                            //     @as(f32, @floatFromInt(tile.px[0])) * world_scale,
                            //     -@as(f32, @floatFromInt(tile.px[1])) * world_scale,
                            //     z_layer,
                            // );
                            // z_layer -= 1;

                            // const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            // const anim_frame = if (anim_info) |anim| app.rand.random().uintLessThan(usize, @min(2, anim.length)) else 0;
                            // const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            // try SpriteCalc.apply(sprite, tile_sprite, .{
                            //     .sprite_info = sprite_info,
                            //     .pos = pos,
                            //     .scale = Vec3.splat(world_scale),
                            //     .flipped = false,
                            // });
                            // try sprite.set(tile_sprite, .pipeline, app.pipeline);
                            // try app.set(tile_sprite, .pixi_sprite, sprite_info);
                            // try app.set(tile_sprite, .is_game_scene, {});
                            // try app.set(tile_sprite, .is_tile, {}); // This entity is an LDTK tile
                            // try app.set(tile_sprite, .sprite_flipped, false);
                            // try app.set(tile_sprite, .position, pos);

                            // if (anim_info) |anim| {
                            //     try app.set(tile_sprite, .sprite_anim, anim);
                            //     try app.set(tile_sprite, .sprite_timer, @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            // }
                            // if (parallax) |p| {
                            //     try app.set(tile_sprite, .parallax, p);
                            // }
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

                    const is_grimble = blk: {
                        for (entity_instance.__tags) |tag| {
                            if (std.mem.eql(u8, tag, "grimble")) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    _ = is_grimble; // autofix

                    const tilesetRelPath = blk: {
                        for (app.parsed_level.value.defs.tilesets) |tileset_def| {
                            if (tileset_def.uid != tile.tilesetUid) continue;
                            break :blk tileset_def.relPath;
                        }
                        @panic("failed to find tileset for entity");
                    };

                    // Find the pixi sprite corresponding to the entity tile
                    const tile_src: [2]i64 = .{ tile.x, tile.y };
                    if (pixi_ldtk.findSpriteByLayerSrc(tilesetRelPath.?, tile_src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            _ = sprite_index; // autofix
                            // TODO(rendering)
                            // const tile_sprite = try entities.new();
                            // const pos = vec3(
                            //     @as(f32, @floatFromInt(entity_instance.px[0])) * world_scale,
                            //     -@as(f32, @floatFromInt(entity_instance.px[1])) * world_scale,
                            //     z_layer,
                            // );
                            // z_layer -= 1;

                            // const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            // const anim_frame = if (anim_info) |anim| app.rand.random().uintLessThan(
                            //     usize,
                            //     if (is_grimble)
                            //         // Grimble animations are very out of sync with eachother
                            //         anim.length
                            //     else
                            //         // Other animations are only slightly out of sync with eachother
                            //         @min(2, anim.length),
                            // ) else 0;
                            // const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            // try SpriteCalc.apply(sprite, tile_sprite, .{
                            //     .sprite_info = sprite_info,
                            //     .pos = pos,
                            //     .scale = Vec3.splat(world_scale),
                            //     .flipped = false,
                            // });

                            // if (is_grimble) try app.set(tile_sprite, .is_grimble, {});
                            // try sprite.set(tile_sprite, .pipeline, app.pipeline);
                            // try app.set(tile_sprite, .pixi_sprite, sprite_info);
                            // try app.set(tile_sprite, .is_game_scene, {});
                            // try app.set(tile_sprite, .is_entity, {}); // This entity is an LDTK entity
                            // try app.set(tile_sprite, .sprite_flipped, false);
                            // try app.set(tile_sprite, .position, pos);

                            // if (anim_info) |anim| {
                            //     try app.set(tile_sprite, .sprite_anim, anim);
                            //     try app.set(tile_sprite, .sprite_timer, if (is_grimble)
                            //         app.rand.random().float(f32) * 10.0
                            //     else
                            //         @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            // }
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

pub fn updateAnims(
    sprite: *gfx.Sprite,
    app: *App,
    audio: *mach.Audio,
) !void {
    _ = audio; // autofix
    _ = app; // autofix
    _ = sprite; // autofix

    // TODO(anim)
    // TODO(query)
    //     var q = try entities.query(.{
    //         .ids = mach.Entities.Mod.read(.id),
    //         .anims = Mod.read(.sprite_anim),
    //         .timers = Mod.write(.sprite_timer),
    //         .flips = Mod.read(.sprite_flipped),
    //         .positions = Mod.read(.position),
    //         .pixi_sprites = Mod.write(.pixi_sprite),
    //     });
    //     while (q.next()) |v| {
    //         for (v.ids, v.anims, v.timers, v.flips, v.positions, v.pixi_sprites) |id, anim, *timer, flip, position, *pixi_sprite| {
    //             const atlas = app.parsed_atlas.value;
    //             const anim_fps: f32 = @floatFromInt(anim.fps);

    //             timer.* += app.delta_time;
    //             var frame = @as(usize, @intFromFloat(timer.* * anim_fps));
    //             if (frame >= anim.length - 1) {
    //                 frame = if (anim.length - 1 == 0) 0 else frame % (anim.length - 1);
    //                 if (app.get(id, .sprite_delete_after_anim) != null) {
    //                     try entities.remove(id);
    //                     continue;
    //                 } else if (timer.* > 1.0 and app.get(id, .is_grimble) != null) {
    //                     timer.* -= 1.0;

    //                     // Load our "grimble" sfx
    //                     const sfx_fbs = std.io.fixedBufferStream(assets.sfx.grimble);
    //                     const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
    //                     const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

    // // TODO(audio):
    //                     // Create an audio entity to play our sfx
    // const sfx_entity = try audio.buffers.new(.{
    //     .samples = sfx.samples,
    //     .channels = sfx.channels,
    //     .playing = true,
    //     .volume = 0.2,
    // });
    // try audio.buffers.setTag(sfx_entity, App, .is_game_scene, null);
    // try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);
    //                     try app.set(sfx_entity, .position, position);
    //                     try app.set(id, .child_sfx, sfx_entity);
    //                 }
    //             }

    //             pixi_sprite.* = atlas.sprites[anim.start + frame];
    //             try SpriteCalc.apply(sprite, id, .{
    //                 .sprite_info = pixi_sprite.*,
    //                 .pos = position,
    //                 .scale = Vec3.splat(world_scale),
    //                 .flipped = flip,
    //             });
    //         }
    //     }
}

pub fn updateSfx(
    sprite: *gfx.Sprite,
    app: *App,
) !void {
    _ = app; // autofix
    _ = sprite; // autofix
    // TODO(audio)
    // TODO(query)
    // TODO: move monster position updates out of updateSfx
    //     // Update grimble positions first
    //     // TODO: move this to somewhere else, not in updateSfx
    //     var q2 = try entities.query(.{
    //         .ids = mach.Entities.Mod.read(.id),
    //         .flips = Mod.write(.sprite_flipped),
    //         .positions = Mod.write(.position),
    //         .pixi_sprites = Mod.read(.pixi_sprite),
    //         .is_grimbles = Mod.read(.is_grimble),
    //     });
    //     while (q2.next()) |v| {
    //         for (v.ids, v.flips, v.positions, v.pixi_sprites) |id, *flip, *position, pixi_sprite| {
    //             flip.* = app.player_position.x() < position.*.x();
    //             const flip_float: f32 = if (flip.*) -1.0 else 1.0;
    //             position.* = position.*.add(&vec3(flip_float * 250.0 * app.delta_time, 0, 0));
    //             try SpriteCalc.apply(sprite, id, .{
    //                 .sprite_info = pixi_sprite,
    //                 .pos = position.*,
    //                 .scale = Vec3.splat(world_scale),
    //                 .flipped = flip.*,
    //             });

    //             if (app.get(id, .child_sfx)) |sfx_entity| {
    //                 try app.set(sfx_entity, .position, position.*);
    //             }
    //         }
    //     }

    // TODO(query)
    //     // Update sfx
    //     var q = try entities.query(.{
    //         .volumes = mach.Audio.Mod.write(.volume),
    //         .positions = Mod.read(.position),
    //     });
    //     while (q.next()) |v| {
    //         for (v.volumes, v.positions) |*volume, position| {
    //             const player_pos = vec2(app.player_position.x(), 0);
    //             const sound_pos = vec2(position.x(), 0);
    //             // std.debug.print("player: {d:.02}, sfx: {d:.02}\n", .{ app.player_position.v, position.v });
    //             const dist = player_pos.dist(&sound_pos);
    //             volume.* = 1.0 - @min(1.0, dist / 1500.0);
    //         }
    //     }
}

pub fn pollInput(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    audio: *mach.Audio,
    card: *Card,
    text: *gfx.Text,
) !void {
    const label = @tagName(mach_module) ++ ".pollInput";
    _ = label; // autofix
    const window = core.windows.getValue(app.window_id);
    _ = window; // autofix

    var direction = app.direction;
    var player_wants_to_attack = app.player_wants_to_attack;
    var player_wants_to_run = app.player_wants_to_run;
    while (core.nextEvent()) |event| {
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
                if (app.scene == .start) {
                    // Load our "Morning bells" sfx
                    const sfx_fbs = std.io.fixedBufferStream(assets.sfx.morning_bells);
                    const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                    const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

                    // Create an audio entity to play our sfx
                    const sfx_entity = try audio.buffers.new(.{
                        .samples = sfx.samples,
                        .channels = sfx.channels,
                        .playing = true,
                        .volume = 0.3,
                    });
                    try audio.buffers.setTag(sfx_entity, App, .is_start_scene, null);
                    try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);

                    // TODO(audio)
                    // // Change the scene to .game after the sfx has played
                    // try app.set(sfx_entity, .after_play_change_scene, .game);
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
            .window_open => |ev| try setupPipeline(core, app, app_mod, sprite, card, text, ev.window_id),
            .close => core.exit(),
            else => {},
        }
    }
    app.last_direction = app.direction;
    app.direction = direction;
    app.player_wants_to_attack = player_wants_to_attack;
    app.player_wants_to_run = player_wants_to_run;

    const dt = app.delta_timer.lap();
    app.delta_time = dt;
    app.world_time += dt;
}

pub fn updateScene(
    app: *App,
    app_mod: mach.Mod(App),
) !void {
    switch (app.scene) {
        .none => {},
        .start => app_mod.call(.updateSceneStart),
        .game => app_mod.call(.updateSceneGame),
    }
}

pub fn updateSceneStart(
    app: *App,
) !void {
    _ = app; // autofix
    _ = app; // autofix
    // TODO(query)
    //     // Make the logo sprites (there are multiple, one for each 'sprite layer' in pixi) bounce up and down slowly
    //     var q = try entities.query(.{
    //         .is_logo = Mod.read(.is_logo),
    //         .transforms = gfx.Sprite.Mod.write(.transform),
    //         .sprite_infos = Mod.read(.pixi_sprite),
    //     });
    //     while (q.next()) |v| {
    //         for (v.transforms, v.sprite_infos) |*transform, sprite_info| {
    //             const pos = vec3(
    //                 0,
    //                 (10 * math.sin((app.timer.read() / 8.0) * 2 * std.math.pi)),
    //                 transform.translation().z(),
    //             );
    //             const calc = SpriteCalc.init(.{
    //                 .sprite_info = sprite_info,
    //                 .pos = pos,
    //                 .scale = Vec3.splat(start_scale),
    //                 .flipped = false,
    //             });
    //             transform.* = calc.transform;
    //         }
    //     }
}

pub fn updateSceneGame(
    app: *App,
    sprite: *gfx.Sprite,
    audio: *mach.Audio,
) !void {
    _ = audio; // autofix
    _ = sprite; // autofix
    _ = app; // autofix
    _ = audio; // autofix
    _ = sprite; // autofix
    _ = app; // autofix
    // TODO(anim)
    //     const can_attack = app.attack_cooldown_timer.read() > app.attack_cooldown;
    //     const begin_moving = !app.is_attacking and app.last_direction.eql(&vec2(0, 0)) and !app.direction.eql(&vec2(0, 0));
    //     const begin_attack = !app.is_attacking and can_attack and app.player_wants_to_attack;

    //     if (begin_attack) {
    //         app.attack_cooldown_timer.reset();
    //         app.is_attacking = true;
    //     }
    //     if (begin_moving or begin_attack) {
    //         app.player_sprite_timer.reset();
    //         app.player_anim_frame = -1;
    //     }

    //     const animation_name = if (app.is_attacking)
    //         "wrench_attack_main"
    //     else if (app.direction.eql(&vec2(0, 0)))
    //         "wrench_upgrade_main"
    //     else
    //         "wrench_walk_main";

    //     // Render the next animation frame for Wrench
    //     const atlas = app.parsed_atlas.value;
    //     const animation_info = animationByName(atlas, animation_name).?;

    //     var end_attack: bool = false;

    //     // Determine the next player animation frame
    //     var animation_fps: f32 = @floatFromInt(animation_info.fps);
    //     if (app.player_wants_to_run) animation_fps *= 2;
    //     var i: usize = @intFromFloat(app.player_sprite_timer.read() * animation_fps);
    //     if (i >= animation_info.length) {
    //         app.player_sprite_timer.reset();
    //         i = 0;

    //         if (app.is_attacking) {
    //             app.is_attacking = false;
    //             end_attack = true;
    //         }
    //     }

    //     // Player moves in the direction of the keyboard input
    //     const dir = if (app.is_attacking) app.direction.mulScalar(0.5) else app.direction;
    //     if (!dir.eql(&vec2(0, 0))) {
    //         app.last_facing_direction = dir;
    //     }
    //     const base_speed = 250.0;
    //     const speed: f32 = if (app.player_wants_to_run) base_speed * 10.0 else base_speed;
    //     const pos = app.player_position.add(
    //         &vec3(dir.v[0], 0, 0).mulScalar(speed).mulScalar(app.delta_time),
    //     );
    //     app.player_position = pos;

    //     // If the player is moving left instead of right, then flip the sprite so it renders
    //     // facing the left instead of its natural right-facing direction.
    //     const flipped: bool = app.last_facing_direction.v[0] < 0;
    //     const player = app.player;
    //     try SpriteCalc.apply(sprite, player, .{
    //         .sprite_info = atlas.sprites[animation_info.start + i],
    //         .pos = pos,
    //         .scale = Vec3.splat(world_scale),
    //         .flipped = flipped,
    //     });

    //     if (end_attack) {
    //         const attack_fx = try entities.new();
    //         const anim_info = animationByName(atlas, "ground_attack_main").?;

    //         const z_layer: f32 = 0;
    //         const position: Vec3 = vec3(
    //             if (app.last_facing_direction.v[0] >= 0) pos.v[0] - (48.0 * world_scale) else pos.v[0] + (48.0 * world_scale),
    //             pos.v[1] + (256.0 * world_scale),
    //             z_layer,
    //         );

    //         const sprite_info = atlas.sprites[anim_info.start];
    //         try SpriteCalc.apply(sprite, attack_fx, .{
    //             .sprite_info = sprite_info,
    //             .pos = position,
    //             .scale = Vec3.splat(world_scale),
    //             .flipped = flipped,
    //         });
    //         try sprite.set(attack_fx, .pipeline, app.pipeline);
    //         try app.set(attack_fx, .is_game_scene, {});
    //         try app.set(attack_fx, .sprite_anim, animationByName(atlas, "ground_attack_main").?);
    //         try app.set(attack_fx, .sprite_delete_after_anim, {});
    //         try app.set(attack_fx, .sprite_timer, 0);
    //         try app.set(attack_fx, .sprite_flipped, flipped);
    //         try app.set(attack_fx, .pixi_sprite, sprite_info);
    //         try app.set(attack_fx, .position, position);
    //     }

    //     if (i != app.player_anim_frame) {
    //         // Player animation frame has changed
    //         app.player_anim_frame = @intCast(i);

    //         // If walking, play footstep sfx every 2nd frame
    //         if (!app.is_attacking and !dir.eql(&vec2(0, 0)) and
    //             ((app.player_wants_to_run and i % 1 == 0) or (!app.player_wants_to_run and i % 2 == 0)))
    //         {
    //             // Load our "footsteps" sfx
    //             // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
    //             const sfx_fbs = std.io.fixedBufferStream(assets.sfx.footsteps);
    //             const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
    //             const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

    //             // Create an audio entity to play our sfx
    //             const sfx_entity = try entities.new();
    //             try audio.set(sfx_entity, .samples, sfx.samples);
    //             try audio.set(sfx_entity, .channels, sfx.channels);
    //             try audio.set(sfx_entity, .playing, true);
    //             try audio.set(sfx_entity, .index, 0);
    //             try audio.set(sfx_entity, .volume, 3.3);
    //             try app.set(sfx_entity, .is_game_scene, {}); // This entity belongs to the start scene
    //             try app.set(sfx_entity, .is_sfx, {}); // Mark our audio entity is sfx, so we can distinguish it from bgm later.
    //         }

    //         // If attacking, play attack noise on first frame
    //         if (app.is_attacking and i == 0) {
    //             // Load our "freeze" sfx
    //             // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
    //             const sfx_fbs = std.io.fixedBufferStream(assets.sfx.freeze);
    //             const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
    //             const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

    //             // Create an audio entity to play our sfx
    //             const sfx_entity = try entities.new();
    //             try audio.set(sfx_entity, .samples, sfx.samples);
    //             try audio.set(sfx_entity, .channels, sfx.channels);
    //             try audio.set(sfx_entity, .playing, true);
    //             try audio.set(sfx_entity, .index, 0);
    //             try audio.set(sfx_entity, .volume, 0.6);
    //             try app.set(sfx_entity, .is_game_scene, {}); // This entity belongs to the start scene
    //             try app.set(sfx_entity, .is_sfx, {}); // Mark our audio entity is sfx, so we can distinguish it from bgm later.
    //         }
    //     }
}

pub fn updateCamera(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    app: *App,
    card: *Card,
) !void {
    // Our aim will be for our virtual canvas to be two thirds 1920x1080px. For our game, we do not
    // want the player to see more or less horizontally, as that may give an unfair advantage, but
    // they can see more or less vertically as that will only be more clouds or ground texture. As
    // such, we make the width fixed and dynamically adjust the height of our virtual canvas to be
    // whatever is needed to match the actual window aspect ratio without any stretching.
    const window_width_px: f32 = @floatFromInt(core.windows.get(app.window_id, .width));
    const window_height_px: f32 = @floatFromInt(core.windows.get(app.window_id, .height));
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
    const camera_target = switch (app.scene) {
        .none => vec3(0, 0, 0),
        .start => vec3(0, 0, 0),
        .game => vec3(
            math.clamp(app.player_position.x(), map_left, map_right),
            app.player_position.y() + (height_px / 4),
            0,
        ),
    };
    const camera_target_diff = camera_target.sub(&app.camera_position);
    const camera_lag_seconds = 0.5;
    app.camera_position = app.camera_position.add(&camera_target_diff.mulScalar(app.delta_time / camera_lag_seconds));

    const view = Mat4x4.translate(app.camera_position.mulScalar(-1));
    const view_projection = projection.mul(&view);
    sprite.pipelines.set(app.sprite_pipeline_id, .view_projection, view_projection);
    text.pipelines.set(app.text_pipeline_id, .view_projection, view_projection);
    card.pipelines.set(app.rtt_card_pipeline_id, .view_projection, view_projection);

    // TODO(query)
    //     {
    //         var q = try entities.query(.{
    //             .ids = mach.Entities.Mod.read(.id),
    //             .card_transforms = Card.Mod.read(.transform),
    //         });
    //         while (q.next()) |v| {
    //             for (v.ids) |card_id| {
    //                 if (app.get(card_id, .is_rtt_card) == null) {
    //                     try card.set(card_id, .view_projection, view_projection);
    //                 } else {
    //                     try card.set(card_id, .view_projection, projection);
    //                     try card.set(card_id, .transform, Mat4x4.translate(vec3(
    //                         -width_px / 2,
    //                         -height_px / 2,
    //                         0,
    //                     )));
    //                     try card.set(card_id, .size, vec2(width_px, height_px));
    //                 }
    //             }
    //         }
    //     }

    // TODO(query)
    //     var q = try entities.query(.{
    //         .ids = mach.Entities.Mod.read(.id),
    //         .parallaxes = Mod.read(.parallax),
    //         .flips = Mod.read(.sprite_flipped),
    //         .positions = Mod.read(.position),
    //         .pixi_sprites = Mod.read(.pixi_sprite),
    //     });
    //     while (q.next()) |v| {
    //         for (v.ids, v.parallaxes, v.flips, v.positions, v.pixi_sprites) |id, parallax, flip, position, pixi_sprite| {
    //             // TODO: cleanup and/or remove this code
    //             //
    //             // const atlas = app.parsed_atlas.value;
    //             // const anim_fps: f32 = @floatFromInt(anim.fps);

    //             // timer.* += app.delta_time;
    //             // var frame = @as(usize, @intFromFloat(timer.* * anim_fps));

    //             // if (frame > anim.length - 1) {
    //             //     if (app.get(id, .sprite_delete_after_anim) != null) {
    //             //         try entities.remove(id);
    //             //         continue;
    //             //     } else {
    //             //         frame = frame % anim.length;
    //             //     }
    //             // }

    //             // var parallax2 = parallax;
    //             // if (parallax2[0] != 0) {
    //             //     parallax2[0] = 0.3;
    //             //     parallax2[1] = 0.3;
    //             // }
    //             // const win_width = 1920.0 * (3.0 / 4.0);
    //             // std.debug.print("camera position: {d:.02}\n", .{app.camera_position.v});

    //             const win_width = 0;
    //             const parallax2 = parallax;
    //             try SpriteCalc.apply(sprite, id, .{
    //                 .sprite_info = pixi_sprite,
    //                 .pos = position.sub(&app.camera_position.add(&vec3(-(win_width * 8.0), 0, 0)).mul(&vec3(parallax2[0], parallax2[1], 1))),
    //                 .scale = Vec3.splat(world_scale),
    //                 .flipped = flip,
    //             });
    //         }
    //     }
}

pub fn renderFrame(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
    card: *Card,
    card_mod: mach.Mod(Card),
    app: *App,
) !void {
    // Create a command encoder for this frame
    const label = @tagName(mach_module) ++ ".renderFrame";
    const encoder = core.windows.get(app.window_id, .device).createCommandEncoder(&.{ .label = label });

    // First render pass
    {
        const dark_gray = gpu.Color{ .r = 0.106, .g = 0.11, .b = 0.118, .a = 1 };
        const sky_blue = gpu.Color{ .r = 0.529, .g = 0.808, .b = 0.922, .a = 1 };
        _ = sky_blue; // autofix

        // Begin a render pass that will render our scene to a texture (rtt == render to texture)
        const rtt_color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = app.rtt_texture_view,
            .clear_value = switch (app.scene) {
                .none => dark_gray,
                .start => dark_gray,
                .game => dark_gray,
            },
            .load_op = .clear,
            .store_op = .store,
        }};
        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &rtt_color_attachments,
        }));

        // Render sprites
        sprite.pipelines.set(app.sprite_pipeline_id, .render_pass, render_pass);
        sprite_mod.call(.tick);

        // Render text
        text.pipelines.set(app.text_pipeline_id, .render_pass, render_pass);
        text_mod.call(.tick);

        // Render cards
        // TODO(important): only render card with render_pass_id = 0 here
        card.pipelines.set(app.rtt_card_pipeline_id, .render_pass, render_pass);
        card_mod.call(.tick);

        // Finish render pass
        render_pass.end();
        render_pass.release();
    }

    // Second render pass
    {
        // Grab the back buffer of the swapchain
        // TODO(Core)
        const back_buffer_view = core.windows.get(app.window_id, .swap_chain).getCurrentTextureView().?;
        defer back_buffer_view.release();

        // Begin second render pass
        const color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .clear_value = std.mem.zeroes(gpu.Color),
            .load_op = .clear,
            .store_op = .store,
        }};

        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &color_attachments,
        }));

        // Render cards
        // TODO(important): only render card with render_pass_id = 1 here
        card.pipelines.set(app.rtt_card_pipeline_id, .render_pass, render_pass);
        card_mod.call(.tick);

        // Finish render pass
        render_pass.end();
        render_pass.release();
    }

    // Finish the frame
    {
        var command = encoder.finish(&.{ .label = label });
        core.windows.get(app.window_id, .queue).submit(&[_]*gpu.CommandBuffer{command});
        command.release();

        // Multiply by delta_time to ensure that movement is the same speed regardless of the frame rate.
        const delta_time = app.timer.lap();

        app.frame_count += 1;
        app.world_time += delta_time;

        // Every second, update the window title with the FPS
        if (app.fps_timer.read() >= 1.0) {
            app.fps_timer.reset();
            app.fps = app.frame_count;
            app.frame_count = 0;
        }
    }
}

// TODO(sprite): don't require users to copy / write this helper themselves
fn loadTexture(device: *gpu.Device, queue: *gpu.Queue, allocator: std.mem.Allocator, png_bytes: []const u8) !*gpu.Texture {
    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, png_bytes);
    defer img.deinit();
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(mach_module) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
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

    fn apply(sprite: *gfx.Sprite, object_id: mach.ObjectID, in: Input) !void {
        const calc = SpriteCalc.init(in);
        sprite.objects.set(object_id, .transform, calc.transform);
        sprite.objects.set(object_id, .uv_transform, calc.uv_transform);
        sprite.objects.set(object_id, .size, calc.size);
    }
};
