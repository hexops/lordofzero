// Helps to load:
//
// Pixi .atlas JSON files
// LDTK 'Super Simple Export' JSON metadata files
// LDTK 'Super Simple Export' CSV int grid files

const std = @import("std");

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

pub const Atlas = struct {
    sprites: []Sprite,
    animations: []Animation,
    parsed: *std.json.Parsed(Atlas.Data),

    const Data = struct {
        sprites: []Sprite,
        animations: []Animation,
    };

    pub fn init(allocator: std.mem.Allocator, json: []const u8) !Atlas {
        var parsed = try allocator.create(std.json.Parsed(Atlas.Data));
        errdefer parsed.deinit();
        parsed.* = try std.json.parseFromSlice(
            Atlas.Data,
            allocator,
            json,
            .{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true },
        );
        return .{
            .sprites = parsed.value.sprites,
            .animations = parsed.value.animations,
            .parsed = parsed,
        };
    }

    pub fn deinit(atlas: Atlas) void {
        atlas.parsed.deinit();
    }
};

pub const LDTK = struct {
    width: u32,
    height: u32,
    layers: [][:0]u8,
    entities: struct {
        entity_kind: []Entity,
    },

    const Entity = struct {
        id: [:0]u8,
        iid: [:0]u8,
        x: u32,
        y: u32,
    };

    pub fn initFromFile(allocator: std.mem.Allocator, file: [:0]const u8) !LDTK {
        const read = try std.fs.cwd().readFileAlloc(allocator, file, 1024 * 1024);
        defer allocator.free(read);

        const parsed = try std.json.parseFromSlice(
            LDTK,
            allocator,
            read,
            .{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        var layers = std.ArrayList([:0]u8).init(allocator);
        for (parsed.value.layers) |layer| {
            try layers.append(try allocator.dupeZ(u8, layer));
        }

        var entities = std.ArrayList(Entity).init(allocator);
        for (parsed.value.entities.entity_kind) |entity| {
            try entities.append(.{
                .id = try allocator.dupeZ(u8, entity.id),
                .iid = try allocator.dupeZ(u8, entity.iid),
                .x = entity.x,
                .y = entity.y,
            });
        }

        return .{
            .width = parsed.value.width,
            .height = parsed.value.height,
            .entities = .{ .entity_kind = try entities.toOwnedSlice() },
            .layers = try layers.toOwnedSlice(),
        };
    }

    pub fn deinit(ldtk: LDTK, allocator: std.mem.Allocator) void {
        for (ldtk.layers) |layer| allocator.free(layer);
        allocator.free(ldtk.layers);

        for (ldtk.entities.entity_kind) |entity| {
            allocator.free(entity.id);
            allocator.free(entity.iid);
        }
        allocator.free(ldtk.entities.entity_kind);
    }

    pub fn getEntity(ldtk: LDTK, id: []const u8, iid: []const u8) ?Entity {
        for (ldtk.entities.entity_kind) |entity| {
            if (std.mem.eql(u8, entity.id, id) and std.mem.eql(u8, entity.iid, iid)) {
                return entity;
            }
        }

        return null;
    }
};

pub const CSV = struct {
    data: []u8,
    row_stride: u32,

    pub fn initFromFile(allocator: std.mem.Allocator, file: [:0]const u8) !CSV {
        const read = try std.fs.cwd().readFileAlloc(allocator, file, 1024);
        defer allocator.free(read);

        var data = std.ArrayList(u8).init(allocator);

        var row_stride: u32 = 0;
        var first_row = true;
        for (read) |c| switch (c) {
            '0'...'9' => try data.append(c - '0'),
            ',' => {
                if (first_row) {
                    row_stride += 1;
                }
            },
            '\n' => first_row = false,
            ' ' => {},
            else => unreachable,
        };

        return .{
            .data = try data.toOwnedSlice(),
            .row_stride = row_stride,
        };
    }

    pub fn deinit(csv: CSV, allocator: std.mem.Allocator) void {
        allocator.free(csv.data);
    }

    pub fn get(csv: CSV, row: u32, col: u32) u8 {
        return csv.data[row * csv.row_stride + col];
    }
};

test {
    const atlas = try Atlas.initFromFile(std.testing.allocator, "pixi.json");
    defer atlas.deinit(std.testing.allocator);

    const ldtk = try LDTK.initFromFile(std.testing.allocator, "ldtk.json");
    defer ldtk.deinit(std.testing.allocator);

    const csv = try CSV.initFromFile(std.testing.allocator, "data.csv");
    defer csv.deinit(std.testing.allocator);

    std.debug.print("entity: {}\n", .{ldtk.getEntity("Myentity", "36988e50-fec0-11ee-b0da-cb73983803c9").?.x});
    std.debug.print("strid: {}\n", .{csv.row_stride});
    std.debug.print("xy: {}\n", .{csv.get(13, 0)});
}
