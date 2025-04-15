const std = @import("std");
const rl = @import("raylib");
const tatl = @import("tatl.zig");

const AnimationTexture = struct {
    x: i16,
    y: i16,
    texture: rl.Texture,
};

const AnimationFrame = struct {
    texture_cels: []AnimationTexture,
    duration: u16,
};
const TextureMap = std.StringHashMap(usize);

pub const AnimationState = enum {
    walk,
    run,
    idle,
};

const FrameSlice = struct {
    from: usize,
    to: usize,
};

fn make_tag_map(aseprite: tatl.AsepriteImport, map: *std.AutoHashMap(AnimationState, FrameSlice)) !void {
    for (0..aseprite.tags.len) |i| {
        const tag = aseprite.tags[i];
        if (std.meta.stringToEnum(AnimationState, tag.name)) |tag_name| {
            try map.put(tag_name, FrameSlice{ .from = tag.from, .to = tag.to });
        }
    }
}

fn img_cel_to_raylib_texture(cel: tatl.ImageCel) rl.Texture {
    const img = rl.Image{
        .data = @ptrCast(cel.pixels.ptr),
        .width = @intCast(cel.width),
        .height = @intCast(cel.height),
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    // THIS WILL SEGFAULT IF CALLED BEFORE rl.InitWindow
    return rl.loadTextureFromImage(img) catch @panic("");
}

pub const Animator = struct {
    texture_map: TextureMap,
    animation_frames: []AnimationFrame,
    tag_map: std.AutoHashMap(AnimationState, FrameSlice),
    canvas_size: rl.Vector2,

    pub fn load(aseprite: tatl.AsepriteImport, allocator: std.mem.Allocator) !Animator {
        var texture_map = TextureMap.init(allocator);
        var textures = try std.ArrayList(AnimationTexture).initCapacity(allocator, aseprite.layers.len);
        var animation_frames = try std.ArrayList(AnimationFrame).initCapacity(allocator, aseprite.frames.len);
        try animation_frames.resize(aseprite.frames.len);

        for (0..aseprite.frames.len) |i| {
            try textures.resize(aseprite.layers.len);
            const frame = aseprite.frames[i];
            for (frame.cels) |cel| {
                textures.items[cel.layer] = switch (cel.data) {
                    .raw_image, .compressed_image => |img| .{ .texture = img_cel_to_raylib_texture(img), .x = cel.x, .y = cel.y },
                    else => undefined,
                };
            }
            animation_frames.items[i] = .{ .duration = frame.duration, .texture_cels = try textures.toOwnedSlice() };
        }

        for (0..aseprite.layers.len) |i| {
            const layer = aseprite.layers[i];
            try texture_map.put(layer.name, i);
        }

        var map = std.AutoHashMap(AnimationState, FrameSlice).init(allocator);
        try make_tag_map(aseprite, &map);
        return .{
            .texture_map = texture_map,
            .tag_map = map,
            .animation_frames = try animation_frames.toOwnedSlice(),
            .canvas_size = .{
                .x = @floatFromInt(aseprite.width),
                .y = @floatFromInt(aseprite.height),
            },
        };
    }

    pub fn get_frames(self: @This(), key: AnimationState) []AnimationFrame {
        const tag = self.tag_map.get(key) orelse std.debug.panic("animation missing! {}", .{key});
        return self.animation_frames[tag.from..tag.to];
    }

    pub fn get_texture(self: @This(), name: []const u8) ?usize {
        return self.texture_map.get(name);
    }
};
