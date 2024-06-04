/// Data types for parsing Pixi .atlas JSON files
const std = @import("std");
const testing = std.testing;

pub const ParsedAtlas = std.json.Parsed(Atlas);
pub const ParsedLDTKCompatibility = std.json.Parsed(LDTKCompatibility);

pub const LDTKCompatibility = struct {
    /// Helper to parse a file given its bytes.
    ///
    /// The caller is responsible for calling deinit() when done with the result.
    pub fn parseSlice(allocator: std.mem.Allocator, bytes: []const u8) !ParsedLDTKCompatibility {
        var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        return std.json.parseFromTokenSource(LDTKCompatibility, allocator, &scanner, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.debug("parsing .json file failed at line {d} column {d}\n", .{ diagnostics.getLine(), diagnostics.getColumn() });
            return err;
        };
    }

    tilesets: []LDTKTileset,

    pub fn findSpriteByLayerSrc(self: LDTKCompatibility, layer_path: []const u8, sprite_src: [2]i64) ?LDTKSprite {
        for (self.tilesets) |tileset| {
            for (tileset.layer_paths) |current_layer_path| {
                // TODO: for some reason current_layer_path can have spaces instead of underscores
                // in layer name:
                //
                //         layer_path=pixi-ldtk/src/tiles/tileset_64x320__Layer_0.png
                // current_layer_path=pixi-ldtk/src/tiles/tileset_64x320__Layer 0.png
                // std.debug.print("layer_path={s} current_layer_path={s}\n", .{ layer_path, current_layer_path });
                // std.mem.replace(comptime T: type, input: []const T, needle: []const T, replacement: []const T, output: []T)
                const current_layer_path_fixed = std.mem.replaceOwned(u8, std.heap.page_allocator, current_layer_path, " ", "_") catch unreachable;

                if (std.mem.eql(u8, layer_path, current_layer_path_fixed)) {
                    for (tileset.sprites) |current_sprite| {
                        if (sprite_src[0] == current_sprite.src[0] and sprite_src[1] == current_sprite.src[1]) {
                            return current_sprite;
                        }
                    }
                }
            }
        }
        return null;
    }
};

pub const LDTKSprite = struct {
    name: [:0]const u8,
    src: [2]u32,
};

pub const LDTKTileset = struct {
    layer_paths: [][:0]const u8,
    sprite_size: [2]u32,
    sprites: []LDTKSprite,
};

/// This is the root of a pixi .atlas JSON file
pub const Atlas = struct {
    /// Helper to parse a file given its bytes.
    ///
    /// The caller is responsible for calling deinit() when done with the result.
    pub fn parseSlice(allocator: std.mem.Allocator, bytes: []const u8) !ParsedAtlas {
        var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        return std.json.parseFromTokenSource(Atlas, allocator, &scanner, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.debug("parsing .ldtk file failed at line {d} column {d}\n", .{ diagnostics.getLine(), diagnostics.getColumn() });
            return err;
        };

        // TODO: replace this function with std.json.parseFromSlice usage once that API supports
        // diagnostics: https://github.com/ziglang/zig/compare/master...json-diagnostics
        //
        // return try std.json.parseFromSlice(
        //     File,
        //     allocator,
        //     bytes,
        //     .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = true },
        // );
    }

    sprites: []Sprite,
    animations: []Animation,

    pub fn findSpriteIndex(self: Atlas, name: [:0]const u8) ?usize {
        for (self.sprites, 0..) |sprite, i| {
            if (std.mem.startsWith(u8, sprite.name, name)) {
                return i;
            }
        }
        return null;
    }
};

pub const Sprite = struct {
    name: [:0]const u8,
    source: [4]u32,
    origin: [2]i32,
};

pub const Animation = struct {
    name: [:0]const u8,
    start: usize,
    length: usize,
    fps: usize,
};

test {
    testing.refAllDeclsRecursive(@This());
}
