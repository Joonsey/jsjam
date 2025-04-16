const std = @import("std");
const zlib = std.compress.zlib;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const File = std.fs.File;
const Reader = File.Reader;

pub const AsepriteImportError = error{
    InvalidFile,
    InvalidFrameHeader,
};

pub const ChunkType = enum(u16) {
    OldPaletteA = 0x0004,
    OldPaletteB = 0x0011,
    Layer = 0x2004,
    Cel = 0x2005,
    CelExtra = 0x2006,
    ColorProfile = 0x2007,
    Mask = 0x2016,
    Path = 0x2017,
    Tags = 0x2018,
    Palette = 0x2019,
    UserData = 0x2020,
    Slices = 0x2022,
    Tileset = 0x2023,
    _,
};

pub const ColorDepth = enum(u16) {
    indexed = 8,
    grayscale = 16,
    rgba = 32,
};

pub const PaletteFlags = packed struct {
    has_name: bool,

    padding: u15 = 0,
};

pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn deserializeOld(reader: Reader) !RGBA {
        return RGBA{
            .r = try reader.readInt(u8, .little),
            .g = try reader.readInt(u8, .little),
            .b = try reader.readInt(u8, .little),
            .a = 255,
        };
    }

    pub fn deserializeNew(reader: Reader) !RGBA {
        return RGBA{
            .r = try reader.readInt(u8, .little),
            .g = try reader.readInt(u8, .little),
            .b = try reader.readInt(u8, .little),
            .a = try reader.readInt(u8, .little),
        };
    }

    pub fn format(self: RGBA, comptime fmt: []const u8, options: std.fmt.FormatOptions, stream: anytype) !void {
        _ = fmt;
        _ = options;
        try stream.print("RGBA({d:>3}, {d:>3}, {d:>3}, {d:>3})", .{ self.r, self.g, self.b, self.a });
    }
};

pub const Palette = struct {
    colors: []RGBA,
    /// index for transparent color in indexed sprites
    transparent_index: u8,
    names: [][]const u8,

    pub fn deserializeOld(prev_pal: Palette, reader: Reader) !Palette {
        var pal = prev_pal;

        const packets = try reader.readInt(u16, .little);
        var skip: usize = 0;

        // var i: u16 = 0;
        // while (i < packets) : (i += 1) {
        for (0..packets) |_| {
            skip += try reader.readInt(u8, .little);
            const size: u16 = val: {
                const s = try reader.readInt(u8, .little);
                break :val if (s == 0) @as(u16, 256) else s;
            };

            for (pal.colors[skip .. skip + size], 0..) |*entry, j| {
                entry.* = try RGBA.deserializeOld(reader);
                pal.names[skip + j] = "";
            }
        }

        return pal;
    }

    pub fn deserializeNew(prev_pal: Palette, allocator: Allocator, reader: Reader) !Palette {
        var pal = prev_pal;

        const size = try reader.readInt(u32, .little);
        if (pal.colors.len != size) {
            pal.colors = try allocator.realloc(pal.colors, size);
            pal.names = try allocator.realloc(pal.names, size);
        }
        const from = try reader.readInt(u32, .little);
        const to = try reader.readInt(u32, .little);

        try reader.skipBytes(8, .{});

        for (pal.colors[from .. to + 1], 0..) |*entry, i| {
            const flags = try reader.readStruct(PaletteFlags);
            entry.* = try RGBA.deserializeNew(reader);
            if (flags.has_name)
                pal.names[from + i] = try read_slice(u8, u16, allocator, reader)
            else
                pal.names[from + i] = "";
        }

        return pal;
    }
};

pub const LayerFlags = packed struct {
    visible: bool,
    editable: bool,
    lock_movement: bool,
    background: bool,
    prefer_linked_cels: bool,
    collapsed: bool,
    reference: bool,

    padding: u9 = 0,
};

pub const LayerType = enum(u16) {
    normal,
    group,
    tilemap,
};

pub const LayerBlendMode = enum(u16) {
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,
    addition,
    subtract,
    divide,
};

pub const Layer = struct {
    flags: LayerFlags,
    type: LayerType,
    child_level: u16,
    blend_mode: LayerBlendMode,
    opacity: u8,
    name: []const u8,
    user_data: UserData,

    pub fn deserialize(allocator: Allocator, reader: Reader) !Layer {
        var result: Layer = undefined;
        result.flags = try reader.readStruct(LayerFlags);
        result.type = try reader.readEnum(LayerType, .little);
        result.child_level = try reader.readInt(u16, .little);
        try reader.skipBytes(4, .{});
        result.blend_mode = try reader.readEnum(LayerBlendMode, .little);
        result.opacity = try reader.readInt(u8, .little);
        try reader.skipBytes(3, .{});
        result.name = try read_slice(u8, u16, allocator, reader);
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };
        return result;
    }
};

pub const ImageCel = struct {
    width: u16,
    height: u16,
    pixels: []u8,

    pub fn deserialize(
        color_depth: ColorDepth,
        compressed: bool,
        allocator: Allocator,
        reader: Reader,
    ) !ImageCel {
        var result: ImageCel = undefined;
        result.width = try reader.readInt(u16, .little);
        result.height = try reader.readInt(u16, .little);

        const size: usize = @as(usize, @intCast(result.width)) *
            @as(usize, @intCast(result.height)) *
            @as(usize, @intCast(@intFromEnum(color_depth) / 8));
        result.pixels = try allocator.alloc(u8, size);
        errdefer allocator.free(result.pixels);

        if (compressed) {
            // TODO figure this out
            if (@import("builtin").target.os.tag == .emscripten) return result;
            var zlib_stream = zlib.decompressor(reader);
            _ = try zlib_stream.reader().readAll(result.pixels);
        } else {
            try reader.readNoEof(result.pixels);
        }

        return result;
    }
};

pub const LinkedCel = struct {
    frame: u16,

    pub fn deserialize(reader: Reader) !LinkedCel {
        return LinkedCel{ .frame = try reader.readInt(u16, .little) };
    }
};

pub const CelType = enum(u16) {
    raw_image,
    linked,
    compressed_image,
    compressed_tilemap,
};

pub const CelData = union(CelType) {
    raw_image: ImageCel,
    linked: LinkedCel,
    compressed_image: ImageCel,
    compressed_tilemap: void,
};

pub const Cel = struct {
    layer: u16,
    x: i16,
    y: i16,
    opacity: u8,
    data: CelData,
    extra: CelExtra,
    user_data: UserData,

    pub fn deserialize(color_depth: ColorDepth, allocator: Allocator, reader: Reader) !Cel {
        var result: Cel = undefined;
        result.layer = try reader.readInt(u16, .little);
        result.x = try reader.readInt(i16, .little);
        result.y = try reader.readInt(i16, .little);
        result.opacity = try reader.readInt(u8, .little);

        const cel_type = try reader.readEnum(CelType, .little);
        try reader.skipBytes(7, .{});
        result.data = switch (cel_type) {
            .raw_image => CelData{
                .raw_image = try ImageCel.deserialize(color_depth, false, allocator, reader),
            },
            .linked => CelData{
                .linked = try LinkedCel.deserialize(reader),
            },
            .compressed_image => CelData{
                .compressed_image = try ImageCel.deserialize(color_depth, true, allocator, reader),
            },
            .compressed_tilemap => CelData{
                .compressed_tilemap = void{},
            },
        };

        result.extra = CelExtra{ .x = 0, .y = 0, .width = 0, .height = 0 };
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };

        return result;
    }
};

pub const CelExtraFlags = packed struct {
    precise_bounds: bool,

    padding: u31 = 0,
};

/// This contains values stored in fixed point numbers stored in u32's, do not try to use these values directly
pub const CelExtra = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn isEmpty(self: CelExtra) bool {
        return @as(u128, @bitCast(self)) == 0;
    }

    pub fn deserialize(reader: Reader) !CelExtra {
        const flags = try reader.readStruct(CelExtraFlags);
        if (flags.precise_bounds) {
            return CelExtra{
                .x = try reader.readInt(u32, .little),
                .y = try reader.readInt(u32, .little),
                .width = try reader.readInt(u32, .little),
                .height = try reader.readInt(u32, .little),
            };
        } else {
            return CelExtra{
                .x = 0,
                .y = 0,
                .width = 0,
                .height = 0,
            };
        }
    }
};

pub const ColorProfileType = enum(u16) {
    none,
    srgb,
    icc,
};

pub const ColorProfileFlags = packed struct {
    special_fixed_gamma: bool,

    padding: u15 = 0,
};

pub const ColorProfile = struct {
    type: ColorProfileType,
    flags: ColorProfileFlags,
    /// this is a fixed point value stored in a u32, do not try to use it directly
    gamma: u32,
    icc_data: []const u8,

    pub fn deserialize(allocator: Allocator, reader: Reader) !ColorProfile {
        var result: ColorProfile = undefined;
        result.type = try reader.readEnum(ColorProfileType, .little);
        result.flags = try reader.readStruct(ColorProfileFlags);
        result.gamma = try reader.readInt(u32, .little);
        try reader.skipBytes(8, .{});
        // zig fmt: off
        result.icc_data = if (result.type == .icc)
                              try read_slice(u8, u32, allocator, reader)
                          else
                              &[0]u8{};
        // zig fmt: on
        return result;
    }
};

pub const AnimationDirection = enum(u8) {
    forward,
    reverse,
    pingpong,
};

pub const Tag = struct {
    from: u16,
    to: u16,
    direction: AnimationDirection,
    color: [3]u8,
    name: []const u8,
    user_data: UserData,

    pub fn deserialize(allocator: Allocator, reader: Reader) !Tag {
        var result: Tag = undefined;
        result.from = try reader.readInt(u16, .little);
        result.to = try reader.readInt(u16, .little);
        result.direction = try reader.readEnum(AnimationDirection, .little);
        try reader.skipBytes(8, .{});
        result.color = try reader.readBytesNoEof(3);
        try reader.skipBytes(1, .{});
        result.name = try read_slice(u8, u16, allocator, reader);
        return result;
    }

    pub fn deserializeAll(allocator: Allocator, reader: Reader) ![]Tag {
        const len = try reader.readInt(u16, .little);
        try reader.skipBytes(8, .{});
        const result = try allocator.alloc(Tag, len);
        errdefer allocator.free(result);
        for (result) |*tag| {
            tag.* = try Tag.deserialize(allocator, reader);
        }
        return result;
    }
};

pub const UserDataFlags = packed struct {
    has_text: bool,
    has_color: bool,

    padding: u14 = 0,
};

pub const UserData = struct {
    text: []const u8,
    color: [4]u8,

    pub const empty = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };

    pub fn isEmpty(user_data: UserData) bool {
        return user_data.text.len == 0 and @as(u32, @bitCast(user_data.color)) == 0;
    }

    pub fn deserialize(allocator: Allocator, reader: Reader) !UserData {
        var result: UserData = undefined;
        const flags = try reader.readStruct(UserDataFlags);
        // zig fmt: off
        result.text = if (flags.has_text)
                          try read_slice(u8, u16, allocator, reader)
                      else
                          "";
        result.color = if (flags.has_color)
                           try reader.readBytesNoEof(4)
                       else
                           [4]u8{ 0, 0, 0, 0 };
        // zig fmt: on
        return result;
    }
};

const UserDataChunks = union(enum) {
    Layer: *Layer,
    Cel: *Cel,
    Slice: *Slice,
    Tag: *Tag,

    pub fn new(pointer: anytype) UserDataChunks {
        const name = comptime value: {
            const type_name = @typeName(@typeInfo(@TypeOf(pointer)).pointer.child);
            var iterator = std.mem.splitBackwardsAny(u8, type_name, ".");
            break :value iterator.first();
        };
        return @unionInit(UserDataChunks, name, pointer);
    }

    pub fn setUserData(self: UserDataChunks, user_data: UserData) void {
        switch (self) {
            .Layer => |p| p.*.user_data = user_data,
            .Cel => |p| p.*.user_data = user_data,
            .Slice => |p| p.*.user_data = user_data,
            .Tag => |p| p.*.user_data = user_data,
        }
    }
};

pub const SliceFlags = packed struct {
    nine_patch: bool,
    has_pivot: bool,

    padding: u30 = 0,
};

pub const SliceKey = struct {
    frame: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    center: struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
    pivot: struct {
        x: i32,
        y: i32,
    },

    pub fn deserialize(flags: SliceFlags, reader: Reader) !SliceKey {
        var result: SliceKey = undefined;
        result.frame = try reader.readInt(u32, .little);
        result.x = try reader.readInt(i32, .little);
        result.y = try reader.readInt(i32, .little);
        result.width = try reader.readInt(u32, .little);
        result.height = try reader.readInt(u32, .little);
        result.center = if (flags.nine_patch) .{
            .x = try reader.readInt(i32, .little),
            .y = try reader.readInt(i32, .little),
            .width = try reader.readInt(u32, .little),
            .height = try reader.readInt(u32, .little),
        } else .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };
        result.pivot = if (flags.has_pivot) .{
            .x = try reader.readInt(i32, .little),
            .y = try reader.readInt(i32, .little),
        } else .{
            .x = 0,
            .y = 0,
        };
        return result;
    }
};

pub const Slice = struct {
    flags: SliceFlags,
    name: []const u8,
    keys: []SliceKey,
    user_data: UserData,

    pub fn deserialize(allocator: Allocator, reader: Reader) !Slice {
        var result: Slice = undefined;
        const key_len = try reader.readInt(u32, .little);
        result.flags = try reader.readStruct(SliceFlags);
        try reader.skipBytes(4, .{});
        result.name = try read_slice(u8, u16, allocator, reader);
        errdefer allocator.free(result.name);
        result.keys = try allocator.alloc(SliceKey, key_len);
        errdefer allocator.free(result.keys);
        for (result.keys) |*key| {
            key.* = try SliceKey.deserialize(result.flags, reader);
        }
        result.user_data = UserData{ .text = "", .color = [4]u8{ 0, 0, 0, 0 } };
        return result;
    }
};

pub const Frame = struct {
    /// frame duration in miliseconds
    duration: u16,
    /// images contained within the frame
    cels: []Cel,

    pub const magic: u16 = 0xF1FA;
};

pub const FileHeaderFlags = packed struct {
    layer_with_opacity: bool,

    padding: u31 = 0,
};

pub const AsepriteImport = struct {
    width: u16,
    height: u16,
    color_depth: ColorDepth,
    flags: FileHeaderFlags,
    pixel_width: u8,
    pixel_height: u8,
    grid_x: i16,
    grid_y: i16,
    /// zero if no grid
    grid_width: u16,
    /// zero if no grid
    grid_height: u16,
    palette: Palette,
    color_profile: ColorProfile,
    layers: []Layer,
    slices: []Slice,
    tags: []Tag,
    frames: []Frame,

    pub const magic: u16 = 0xA5E0;

    pub fn deserialize(allocator: Allocator, reader: Reader) !AsepriteImport {
        var result: AsepriteImport = undefined;
        try reader.skipBytes(4, .{});
        if (magic != try reader.readInt(u16, .little)) {
            return error.InvalidFile;
        }

        const frame_count = try reader.readInt(u16, .little);
        result.width = try reader.readInt(u16, .little);
        result.height = try reader.readInt(u16, .little);
        result.color_depth = try reader.readEnum(ColorDepth, .little);
        result.flags = try reader.readStruct(FileHeaderFlags);
        try reader.skipBytes(10, .{});
        const transparent_index = try reader.readInt(u8, .little);
        try reader.skipBytes(3, .{});
        var color_count = try reader.readInt(u16, .little);
        result.pixel_width = try reader.readInt(u8, .little);
        result.pixel_height = try reader.readInt(u8, .little);
        result.grid_x = try reader.readInt(i16, .little);
        result.grid_y = try reader.readInt(i16, .little);
        result.grid_width = try reader.readInt(u16, .little);
        result.grid_height = try reader.readInt(u16, .little);

        if (color_count == 0)
            color_count = 256;

        if (result.pixel_width == 0 or result.pixel_height == 0) {
            result.pixel_width = 1;
            result.pixel_height = 1;
        }

        try reader.skipBytes(84, .{});

        result.palette = Palette{
            .colors = try allocator.alloc(RGBA, color_count),
            .transparent_index = transparent_index,
            .names = try allocator.alloc([]const u8, color_count),
        };
        errdefer {
            allocator.free(result.palette.colors);
            allocator.free(result.palette.names);
        }

        result.slices = &.{};
        result.tags = &.{};

        result.frames = try allocator.alloc(Frame, frame_count);
        errdefer allocator.free(result.frames);

        var layers = try ArrayListUnmanaged(Layer).initCapacity(allocator, 1);
        errdefer layers.deinit(allocator);
        var slices = try ArrayListUnmanaged(Slice).initCapacity(allocator, 0);
        errdefer slices.deinit(allocator);
        var using_new_palette = false;
        var last_with_user_data: ?UserDataChunks = null;

        for (result.frames) |*frame| {
            var cels = try ArrayListUnmanaged(Cel).initCapacity(allocator, 0);
            errdefer cels.deinit(allocator);
            var last_cel: ?*Cel = null;

            try reader.skipBytes(4, .{});
            if (Frame.magic != try reader.readInt(u16, .little)) {
                return error.InvalidFrameHeader;
            }
            const old_chunks = try reader.readInt(u16, .little);
            frame.duration = try reader.readInt(u16, .little);
            try reader.skipBytes(2, .{});
            const new_chunks = try reader.readInt(u32, .little);
            const chunks = if (old_chunks == 0xFFFF and old_chunks < new_chunks)
                new_chunks
            else
                old_chunks;

            // var i: u32 = 0;
            // while (i < chunks) : (i += 1) {
            var tag_user_data_idx: usize = 0;
            var iterate_tag_user_data: bool = false;
            for (0..chunks) |_| {
                const chunk_start = try reader.context.getPos();
                const chunk_size = try reader.readInt(u32, .little);
                const chunk_end = chunk_start + chunk_size;

                const chunk_type = try reader.readEnum(ChunkType, .little);
                switch (chunk_type) {
                    .OldPaletteA, .OldPaletteB => {
                        if (!using_new_palette)
                            result.palette = try Palette.deserializeOld(result.palette, reader);
                    },
                    .Layer => {
                        try layers.append(allocator, try Layer.deserialize(allocator, reader));
                        last_with_user_data = UserDataChunks.new(&layers.items[layers.items.len - 1]);
                    },
                    .Cel => {
                        try cels.append(
                            allocator,
                            try Cel.deserialize(
                                result.color_depth,
                                allocator,
                                reader,
                            ),
                        );
                        last_cel = &cels.items[cels.items.len - 1];
                        last_with_user_data = UserDataChunks.new(last_cel.?);
                    },
                    .CelExtra => {
                        const extra = try CelExtra.deserialize(reader);
                        if (last_cel) |c| {
                            c.extra = extra;
                            last_cel = null;
                        } else {
                            std.log.err("{s}", .{"Found extra cel chunk without cel to attach it to!"});
                        }
                    },
                    .ColorProfile => {
                        result.color_profile = try ColorProfile.deserialize(allocator, reader);
                    },
                    .Tags => {
                        result.tags = try Tag.deserializeAll(allocator, reader);
                        iterate_tag_user_data = true;
                    },
                    .Palette => {
                        using_new_palette = true;
                        result.palette = try Palette.deserializeNew(
                            result.palette,
                            allocator,
                            reader,
                        );
                    },
                    .UserData => {
                        const user_data = try UserData.deserialize(allocator, reader);
                        if (last_with_user_data) |chunk| {
                            chunk.setUserData(user_data);
                            last_with_user_data = null;
                        } else if (iterate_tag_user_data) {
                            result.tags[tag_user_data_idx].user_data = user_data;
                            tag_user_data_idx += 1;
                            if (tag_user_data_idx >= result.tags.len) {
                                iterate_tag_user_data = false;
                            }
                        } else {
                            std.log.err("{s}", .{"Found user data chunk without chunk to attach it to!"});
                        }
                    },
                    .Slices => {
                        try slices.append(allocator, try Slice.deserialize(allocator, reader));
                        last_with_user_data = UserDataChunks.new(&slices.items[slices.items.len - 1]);
                    },
                    else => std.log.err("{s}: {x}", .{ "Unsupported chunk type", chunk_type }),
                }
                try reader.context.seekTo(chunk_end);
            }

            frame.cels = try cels.toOwnedSlice(allocator);
            errdefer allocator.free(frame.cels);
        }
        result.layers = try layers.toOwnedSlice(allocator);
        result.slices = try slices.toOwnedSlice(allocator);
        return result;
    }

    pub fn free(self: AsepriteImport, allocator: Allocator) void {
        allocator.free(self.palette.colors);
        for (self.palette.names) |name| {
            if (name.len > 0)
                allocator.free(name);
        }
        allocator.free(self.palette.names);
        allocator.free(self.color_profile.icc_data);

        for (self.layers) |layer| {
            allocator.free(layer.name);
            allocator.free(layer.user_data.text);
        }
        allocator.free(self.layers);

        for (self.slices) |slice| {
            allocator.free(slice.name);
            allocator.free(slice.keys);
            allocator.free(slice.user_data.text);
        }
        allocator.free(self.slices);

        for (self.tags) |tag| {
            allocator.free(tag.name);
        }
        allocator.free(self.tags);

        for (self.frames) |frame| {
            for (frame.cels) |cel| {
                allocator.free(cel.user_data.text);
                switch (cel.data) {
                    .raw_image => |raw| allocator.free(raw.pixels),
                    .compressed_image => |compressed| allocator.free(compressed.pixels),
                    else => {},
                }
            }
            allocator.free(frame.cels);
        }
        allocator.free(self.frames);
    }
};

fn read_slice(comptime SliceT: type, comptime LenT: type, allocator: Allocator, reader: Reader) ![]SliceT {
    const len = (try reader.readInt(LenT, .little)) * @sizeOf(SliceT);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try reader.readNoEof(bytes);
    return std.mem.bytesAsSlice(SliceT, bytes);
}

pub fn import(allocator: Allocator, reader: Reader) !AsepriteImport {
    return AsepriteImport.deserialize(allocator, reader);
}
