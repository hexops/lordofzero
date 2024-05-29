/// Data types for parsing LDTK .ldtk JSON files
///
/// Goals:
///
/// * Load .ldtk JSON project files
/// * Support loading LDTK files, but not e.g. modifying and re-serialization of them. LDTK files
///   have many JSON fields for internal editor state, and we only parse the 'minimal' subset needed
///   for loading any LDTK level file into a game.
/// * Support only the modern version of LDTK JSON, with 'Multi-Worlds in the project advanced settings'
///   enabled. We do not support reading e.g. deprecated fields.
/// * Do not support 'Super Simple Export' - this is a different, less interesting LDTK export format.
///
const std = @import("std");
const testing = std.testing;

pub const ParsedFile = std.json.Parsed(File);

/// This is the root of any Project JSON file. It contains:
/// - the project settings,
/// - an array of levels,
/// - a group of definitions (that can probably be safely ignored for most users).
pub const File = struct {
    /// Helper to parse a file given its bytes.
    ///
    /// The caller is responsible for calling deinit() when done with the result.
    pub fn parseSlice(allocator: std.mem.Allocator, bytes: []const u8) !ParsedFile {
        var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        return std.json.parseFromTokenSource(File, allocator, &scanner, .{
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

    /// Unique project identifier (string)
    iid: []const u8,

    /// Project background color (string)
    bgColor: []const u8,

    /// This array will be empty, unless you enable the Multi-Worlds in the project advanced settings.
    /// - in current version, a LDtk project file can only contain a single world with multiple
    ///   levels in it. In this case, levels and world layout related settings are stored in the
    ///   root of the JSON.
    /// - with "Multi-worlds" enabled, there will be a `worlds` array in root, each world containing
    ///   levels and layout settings. Basically, it's pretty much only about moving the `levels`
    ///   array to the `worlds` array, along with world layout related values (eg. `worldGridWidth` etc).
    /// If you want to start supporting this future update easily, please refer to this documentation: https://github.com/deepnight/ldtk/issues/231
    worlds: []*World,

    /// All instances of entities that have their `exportToToc` flag enabled are listed in this array.
    toc: []TableOfContentEntry,

    /// A structure containing all the definitions of this project
    defs: Definitions,

    /// File format version (string)
    jsonVersion: []const u8,

    /// If TRUE, one file will be saved for the project (incl. all its definitions) and one file in
    /// a sub-folder for each level.
    externalLevels: bool,
};

/// This object represents a custom sub rectangle in a Tileset image.
pub const TilesetRect = struct {
    /// UID of the tileset
    tilesetUid: i64,

    /// Width in pixels
    w: i64,

    /// Height in pixels
    h: i64,

    /// X pixels coordinate of the top-left corner in the Tileset image
    x: i64,

    /// Y pixels coordinate of the top-left corner in the Tileset image
    y: i64,
};

/// Field instance
pub const FieldInstance = struct {
    /// Reference of the **Field definition** UID
    defUid: i64,

    /// Type of the field, such as `Int`, `Float`, `String`, `Enum(my_enum_name)`, `Bool`, etc.
    ///
    /// NOTE: if you enable the advanced option **Use Multilines type**, you will have "*Multilines*"
    /// instead of "*String*" when relevant.
    __type: []const u8,

    /// Field definition identifier
    __identifier: []const u8,

    /// Optional TilesetRect used to display this field (this can be the field own Tile, or some
    /// other Tile guessed from the value, like an Enum).
    __tile: ?TilesetRect,

    /// Actual value of the field instance. The value type varies, depending on `__type`:
    ///
    /// - For **classic types** (ie. Integer, Float, Boolean, String, Text and FilePath), you just
    ///   get the actual value with the expected type.
    /// - For **Color**, the value is an hexadecimal string using "#rrggbb" format.
    /// - For **Enum**, the value is a String representing the selected enum value.
    /// - For **Point**, the value is a GridPoint object.
    /// - For **Tile**, the value is a TilesetRect object.
    /// - For **EntityRef**, the value is an EntityReferenceInfos object.
    ///
    /// If the field is an array, then this `__value` will also be a JSON array.
    __value: std.json.Value,
};

/// Entity instance
pub const EntityInstance = struct {
    /// Unique instance identifier
    iid: []const u8,

    /// Reference of the **Entity definition** UID
    defUid: i64,

    /// Pixel coordinates (`[x,y]` format) in current level coordinate space.
    /// Don't forget optional layer offsets, if they exist!
    px: [2]i64,

    /// An array of all custom fields and their values.
    fieldInstance: []FieldInstance,

    /// Entity width in pixels. For non-resizable entities, it will be the same as Entity definition.
    width: i64,

    /// Entity height in pixels. For non-resizable entities, it will be the same as Entity definition.
    height: i64,

    /// Entity definition identifier
    __identifier: []const u8,

    /// Optional TilesetRect used to display this entity (it could either be the default Entity
    /// tile, or some tile provided by a field value, like an Enum).
    __tile: ?TilesetRect = null,

    /// X world coordinate in pixels. Only available in GridVania or Free world layouts.
    __worldX: ?i64 = null,

    /// Y world coordinate in pixels Only available in GridVania or Free world layouts.
    __worldY: ?i64 = null,

    /// The entity "smart" color, guessed from either Entity definition, or one its field instances.
    __smartColor: []const u8,

    /// Grid-based coordinates (`[x,y]` format)
    __grid: [][2]i64,

    /// Pivot coordinates  (`[x,y]` format, values are from 0 to 1) of the Entity
    __pivot: [][2]i64,

    /// Array of tags defined in this Entity definition
    __tags: [][]const u8,
};

/// Definitions
pub const Definitions = struct {
    /// All tilesets
    tilesets: []TilesetDef,

    /// All layer definitions
    layers: []LayerDef,

    /// All internal enums
    enums: []EnumDef,

    /// Note: external enums are exactly the same as `enums`, except they have a `relPath` to point
    /// to an external source file.
    externalEnums: []EnumDef,

    /// All entities definitions, including their custom fields
    entities: []EntityDef,
};

/// Enum tag value
///
/// In a tileset definition, enum based tag infos
pub const EnumTagValue = struct {
    tileIds: []i64,

    // string
    enumValueId: []const u8,
};

/// Entity definition
pub const EntityDef = struct {
    pub const TileRenderMode = enum {
        Cover,
        FitInside,
        Repeat,
        Stretch,
        FullSizeCropped,
        FullSizeUncropped,
        NineSlice,
    };

    /// Unique Int identifier
    uid: i64,

    /// User defined unique identifier (string)
    identifier: []const u8,

    /// Tileset ID used for optional tile display
    tilesetId: ?i64 = null,

    /// Pivot X coordinate (from 0 to 1.0)
    pivotX: f32,

    /// Base entity color (string)
    color: []const u8,

    /// An object representing a rectangle from an existing Tileset
    tileRect: ?TilesetRect = null,

    /// An enum describing how the the Entity tile is rendered inside the Entity bounds.
    tileRenderMode: TileRenderMode,

    /// An array of 4 dimensions for the up/right/down/left borders (in this order) when using
    /// 9-slice mode for `tileRenderMode`.
    ///
    /// If the tileRenderMode is not NineSlice, then this array is empty.
    ///
    /// See: https://en.wikipedia.org/wiki/9-slice_scaling
    nineSliceBorders: []i64,

    /// This tile overrides the one defined in `tileRect` in the UI
    uiTileRect: ?TilesetRect = null,

    /// Pixel height
    height: i64,

    /// Pivot Y coordinate (from 0 to 1.0)
    pivotY: f32,

    /// Pixel width
    width: i64,
};

/// IntGrid value group definition
pub const IntGridValueGroupDef = struct {
    /// Group unique ID
    uid: i64,

    /// User defined string identifier
    identifier: ?[]const u8 = null,

    /// User defined color
    color: ?[]const u8 = null,
};

pub const TocInstanceData = struct {
    worldX: i64,
    worldY: i64,
    widPx: i64,
    heiPx: i64,

    /// An object containing the values of all entity fields with the `exportToToc` option enabled.
    /// This object typing depends on actual field value types.
    fields: std.json.Value,

    /// IID information of this instance
    iids: EntityReferenceInfos,
};

/// Nearby level info
pub const NeighbourLevel = struct {
    /// Neighbour Instance Identifier (string)
    levelIid: []const u8,

    /// A lowercase string tipping on the level location (`n`orth, `s`outh, `w`est, `e`ast).
    ///
    /// Since 1.4.0, this value can also be `<` (neighbour depth is lower), `>` (neighbour depth is
    /// greater) or `o` (levels overlap and share the same world depth).  Since 1.5.3, this value
    /// can also be `nw`,`ne`,`sw` or `se` for levels only touching corners.
    dir: []const u8,
};

pub const LayerInstance = struct {
    /// Unique layer instance identifier (string)
    iid: []const u8,

    /// X offset in pixels to render this layer, usually 0 (IMPORTANT: this should be added to the
    /// `LayerDef` optional offset, so you should probably prefer using `__pxTotalOffsetX` which
    /// contains the total offset value)
    pxOffsetX: i64,

    /// Y offset in pixels to render this layer, usually 0 (IMPORTANT: this should be added to the
    /// `LayerDef` optional offset, so you should probably prefer using `__pxTotalOffsetX` which
    /// contains the total offset value)
    pxOffsetY: i64,

    /// Reference to the UID of the level containing this layer instance
    levelId: i64,

    /// An array containing all tiles generated by Auto-layer rules. The array is already sorted in
    /// display order (ie. 1st tile is beneath 2nd, which is beneath 3rd etc.).
    ///
    /// Note: if multiple tiles are stacked in the same cell as the result of different rules, all
    /// tiles behind opaque ones will be discarded.
    autoLayerTiles: []Tile,

    /// A list of all values in the IntGrid layer, stored in CSV format (Comma Separated Values).
    ///
    /// Order is from left to right, and top to bottom (ie. first row from left to right, followed
    /// by second row, etc).
    ///
    /// `0` means "empty cell" and IntGrid values start at 1.
    ///
    /// The array size is `__cWid` x `__cHei` cells.
    intGridCsv: []i64,

    /// This layer can use another tileset by overriding the tileset UID here.
    overrideTilesetUid: ?i64 = null,

    /// Layer instance visibility
    visible: bool,

    /// Entity instances
    entityInstances: []EntityInstance,

    /// Reference the Layer definition UID
    layerDefUid: i64,

    gridTiles: []Tile,

    /// Grid-based height
    __cHei: i64,

    /// The relative path to corresponding Tileset, if any.
    __tilesetRelPath: ?[]const u8,

    /// Layer type
    __type: LayerType,

    /// Layer definition identifier
    __identifier: []const u8,

    /// Grid size
    __gridSize: i64,

    /// Total layer Y pixel offset, including both instance and definition offsets.
    __pxTotalOffsetY: i64,

    /// Layer opacity as Float [0-1]
    __opacity: f32,

    /// Total layer X pixel offset, including both instance and definition offsets.
    __pxTotalOffsetX: i64,

    /// Grid-based width,
    __cWid: i64,

    /// The definition UID of corresponding Tileset, if any.
    __tilesetDefUid: ?i64,
};

/// A World contains multiple levels, and it has its own layout settings.
pub const World = struct {
    const Layout = enum {
        Free,
        GridVania,
        LinearHorizontal,
        LinearVertical,
    };

    /// Unique instance identifer (string)
    iid: []const u8,

    /// User defined unique identifier (string)
    identifier: []const u8,

    /// Width of the world grid in pixels.
    worldGridWidth: i64,

    /// Height of the world grid in pixels.
    worldGridHeight: i64,

    /// An enum that describes how levels are organized in this project (ie. linearly or in a 2D
    /// space).
    worldLayout: ?Layout = null,

    /// All levels from this world
    /// . The order of this array is only relevant in `linear_horizontal`
    /// and `linear_vertical` world layouts (see `world_layout` value). Otherwise, you should refer
    /// to the `worldX`,`worldY` coordinates of each Level.
    levels: []Level,
};

/// Reference to an Entity instance
///
/// This object describes the "location" of an Entity instance in the project worlds.
pub const EntityReferenceInfos = struct {
    /// IID of the World containing the refered EntityInstance
    worldIid: []const u8,

    /// IID of the refered EntityInstance
    entityIid: []const u8,

    /// IID of the LayerInstance containing the refered EntityInstance
    layerIid: []const u8,

    /// IID of the Level containing the refered EntityInstance
    levelIid: []const u8,
};

/// Tile custom metadata
///
/// In a tileset definition, user defined meta-data of a tile.
pub const TileCustomMetadata = struct {
    tileId: []i64,

    /// string
    data: []const u8,
};

/// Tileset definition
///
/// The `Tileset` definition is the most important part among project definitions. It contains some
/// extra informations about each integrated tileset. If you only had to parse one definition
/// section, that would be the one.
pub const TilesetDef = struct {
    pub const EmbedAtlas = enum {
        LdtkIcons,
    };

    /// Unique Int identifier
    uid: i64,

    /// User defined unique identifier
    identifier: []const u8,

    /// Image width in pixels
    pxWid: i64,

    /// Image height in pixels
    pxHei: i64,

    /// Space in pixels between all tiles
    spacing: i64,

    tileGridSize: i64,

    /// An array of custom tile metadata
    customData: []TileCustomMetadata,

    /// Optional Enum definition UID used for this tileset meta-data
    tagsSourceEnumWid: ?i64 = null,

    /// Distance in pixels from image borders,
    padding: i64,

    /// Tileset tags using Enum values specified by `tags_source_enum_id`. This array contains 1
    /// element per Enum value, which contains an array of all Tile IDs that are tagged with it.
    enumTags: []EnumTagValue,

    /// An array of user-defined tags to organize the Tilesets
    tags: [][]const u8,

    /// If this value is set, then it means that this atlas uses an internal LDtk atlas image
    /// instead of a loaded one.
    embedAtlas: ?EmbedAtlas = null,

    /// Path to the source file, relative to the current project JSON file
    ///
    /// It can be null if no image was provided, or when using an embed atlas.
    relPath: ?[]const u8 = null,

    /// Grid-based height
    __cHei: i64,

    /// Grid-based width
    __cWid: i64,
};

/// Enum value definition
pub const EnumDefValues = struct {
    /// Enum value (string)
    id: []const u8,

    /// Optional color
    color: i64,

    /// Optional tileset rectangle to represents this value
    tileRect: ?TilesetRect = null,
};

/// Tile instance
///
/// This structure represents a single tile from a given Tileset.
pub const Tile = struct {
    /// Pixel coordinates of the tile in the **layer** (`[x,y]` format). Don't forget optional
    /// layer offsets, if they exist!
    px: [2]i64,

    /// Pixel coordinates of the tile in the **tileset** (`[x,y]` format)
    src: [2]i64,

    /// "Flip bits", a 2-bits integer to represent the mirror transformations of the tile.
    ///
    /// - Bit 0 = X flip
    /// - Bit 1 = Y flip
    ///
    /// Examples: f=0 (no flip), f=1 (X flip only), f=2 (Y flip only), f=3 (both flips)
    f: u2, // packed struct { x_flip: u1, y_flip: u1 },

    /// The *Tile ID* in the corresponding tileset.
    t: i64,

    /// Alpha/opacity of the tile (0-1, defaults to 1)
    a: f32,
};

/// Layer definition
pub const LayerDef = struct {
    /// Unique Int identifier
    uid: i64,

    /// User defined unique identifier string
    identifier: []const u8,

    /// X offset of the layer, in pixels (IMPORTANT: this should be added to the `LayerInstance` optional offset)
    pxOffsetX: i64,

    /// Y offset of the layer, in pixels (IMPORTANT: this should be added to the `LayerInstance` optional offset)
    pxOffsetY: i64,

    /// Opacity of the layer (0 to 1.0)
    displayOpacity: f32,

    /// Parallax horizontal factor (from -1 to 1, defaults to 0) which affects the scrolling speed of this layer,
    /// creating a fake 3D (parallax) effect.
    parallaxFactorX: f32,

    /// Parallax vertical factor (from -1 to 1, defaults to 0) which affects the scrolling speed of this layer,
    /// creating a fake 3D (parallax) effect.
    parallaxFactorY: f32,

    /// Reference to the default Tileset UID being used by this layer definition.
    ///
    /// **WARNING**: some layer *instances* might use a different tileset. So most of the time, you
    /// should probably use the `__tilesetDefUid` value found in layer instances.
    tilesetDefUid: ?i64 = null,

    /// If true (default), a layer with a parallax factor will also be scaled up/down accordingly.
    parallaxScaling: bool,

    /// An array that defines extra optional info for each IntGrid value.
    ///
    /// WARNING: the array order is not related to actual IntGrid values! As user can re-order
    /// IntGrid values freely, you may value "2" before value "1" in this array.
    intGridValues: []IntGridValueDef,

    /// Group informations for IntGrid values
    intGridValuesGroups: []IntGridValueGroupDef,

    /// Width and height of the grid in pixels
    gridSize: i64,

    /// Type of the layer
    __type: LayerType,
};

pub const LayerType = enum {
    IntGrid,
    Entities,
    Tiles,
    AutoLayers,
};

/// Level background position
///
/// Level background image position info
pub const LevelBgPosInfos = struct {
    /// An array of 4 float values describing the cropped sub-rectangle of the displayed background
    /// image. This cropping happens when original is larger than the level bounds.
    ///
    /// Array format: `[ cropX, cropY, cropWidth, cropHeight ]`
    cropRect: [4]f32,

    /// An array containing the `[scaleX,scaleY]` values of the **cropped** background image,
    /// depending on `bgPos` option.
    scale: [2]f32,

    /// An array containing the `[x,y]` pixel coordinates of the top-left corner of the **cropped**
    /// background image, depending on `bgPos` option.
    topLeftPx: [2]i64,
};

/// Level
///
/// This section contains all the level data. It can be found in 2 distinct forms, depending on
/// Project current settings:
///
/// - If "*Separate level files*" is **disabled** (default): full level data is *embedded* inside
///   the main Project JSON file,
/// - If "*Separate level files*" is **enabled**: level data is stored in *separate* standalone
///   `.ldtkl` files (one per level). In this case, the main Project JSON file will still contain
///   most level data, except heavy sections, like the `layerInstances` array (which will be null).
///   The `externalRelPath` string points to the `ldtkl` file.  A `ldtkl` file is just a JSON file
///   containing exactly what is described below.
pub const Level = struct {
    /// Unique instance identifier string
    iid: []const u8,

    /// Unique Int identifier
    uid: i64,

    /// User defined unique identifier string
    identifier: []const u8,

    /// World X coordinate in pixels.
    ///
    /// Only relevant for world layouts where level spatial positioning is manual (ie. GridVania,
    /// Free). For Horizontal and Vertical layouts, the value is always -1 here.
    worldX: i64,

    /// World Y coordinate in pixels.
    ///
    /// Only relevant for world layouts where level spatial positioning is manual (ie. GridVania,
    /// Free). For Horizontal and Vertical layouts, the value is always -1 here.
    worldY: i64,

    /// Width of the level in pixels
    pxWid: i64,

    /// Height of the level in pixels
    pxHei: i64,

    /// The *optional* relative path to the level background image.
    bgRelPath: ?[]const u8 = null,

    /// This value is not null if the project option "*Save levels separately*" is enabled. In this
    /// case, this **relative** path points to the level Json file.
    externalRelPath: ?[]const u8 = null,

    /// An array containing this level custom field values.
    fieldInstances: []FieldInstance,

    /// An array containing all Layer instances.
    ///
    /// **IMPORTANT**: if the project option "*Save levels separately*" is enabled, this field will
    /// be `null`.
    ///
    /// This array is **sorted in display order**: the 1st layer is the top-most and the last is
    /// behind.
    layerInstances: ?[]LayerInstance = null,

    /// Index that represents the "depth" of the level in the world. Default is 0, greater means
    /// "above", lower means "below".
    ///
    /// This value is mostly used for display only and is intended to make stacking of levels easier
    /// to manage.
    worldDepth: i64,

    /// An array listing all other levels touching this one on the world map.
    ///
    /// Only relevant for world layouts where level spatial positioning is manual (ie. GridVania,
    /// Free). For Horizontal and Vertical layouts, this array is always empty.
    __neighbours: []NeighbourLevel,

    /// Background color of the level (same as `bgColor`, except the default value is automatically
    /// used here if its value is `null`)
    __bgColor: []const u8,

    /// Position informations of the background image, if there is one.
    __bgPos: ?LevelBgPosInfos = null,
};

/// Table of content entry
pub const TableOfContentEntry = struct {
    identifier: []const u8,

    instancesData: []TocInstanceData,
};

/// Enum definition
pub const EnumDef = struct {
    /// Unique Int identifier
    uid: i64,

    /// User defined unique identifier string
    identifier: []const u8,

    /// Relative path to the external file providing this Enum
    externalRelPath: ?[]const u8 = null,

    /// All possible enum values, with their optional Tile infos.
    values: []EnumDefValues,

    /// Tileset UID if provided
    iconTilesetUid: ?i64 = null,

    /// An array of user-defined tags to organize the Enums
    tags: [][]const u8,
};

/// Grid point
///
/// This object is just a grid-based coordinate used in Field values.
pub const GridPoint = struct {
    /// Y grid-based coordinate
    cy: i64,

    /// X grid-based coordinate
    cx: i64,
};

/// IntGrid value definition
pub const IntGridValueDef = struct {
    /// User defined unique identifier string
    identifier: ?[]const u8,

    /// The IntGrid value itself
    value: i64,

    /// Parent group identifier (0 if none)
    groupUid: i64,

    tile: ?[]TilesetRect,
    color: []const u8,
};

test {
    testing.refAllDeclsRecursive(@This());
}
