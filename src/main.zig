const std = @import("std");
const rl = @import("raylib");

var WINDOW_WIDTH: i32 = 1080;
var WINDOW_HEIGHT: i32 = 720;
const RENDER_WIDTH: i32 = 1080;
const RENDER_HEIGHT: i32 = 720;

const GRID_SIZE: usize = 45;

const tile_type = enum(u8) {
    tundra = 0,
    dirt,
    grass,
    rock,
};

const Tile = struct {
    kind: tile_type = .tundra,
};

const State = struct {
    tilemap: [GRID_SIZE * GRID_SIZE]Tile,
    scene: rl.RenderTexture,

    pub fn init(_: std.mem.Allocator) !State {
        return .{
            .tilemap = std.mem.zeroes([GRID_SIZE * GRID_SIZE]Tile),
            .scene = try rl.loadRenderTexture(RENDER_WIDTH, RENDER_HEIGHT),
        };
    }

    pub fn draw_tiles(self: State, sheet: rl.Texture) !void {
        const tile_width = 32;
        const tile_height = 16;

        const sheet_rows = try std.math.divFloor(i32, sheet.width, tile_width);

        for (self.tilemap, 0..) |tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            var screen_pos = try project_to_screen(x, y, tile_width, tile_height);

            const half_screen = try std.math.divFloor(f32, RENDER_WIDTH, 2);
            screen_pos.x += half_screen;
            screen_pos.y += 20;

            var rand = std.Random.DefaultPrng.init(i);
            const r = try std.math.mod(u64, rand.next(), @intCast(sheet_rows));

            rl.drawTextureRec(sheet, .{ .x = @floatFromInt(tile_width * r), .y = @as(f32, @floatFromInt(@intFromEnum(tile.kind))) * tile_width, .width = tile_width, .height = tile_width }, screen_pos, .white);
        }
    }

    pub fn deinit(_: State, _: std.mem.Allocator) void {}
};

pub fn main() anyerror!void {
    setup_window();
    defer rl.closeWindow();

    const sheet = try rl.loadTexture("spritesheet.png");

    rl.setTargetFPS(60);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var state = try State.init(allocator);
    defer state.deinit(allocator);

    while (!rl.windowShouldClose()) {
        state.scene.begin();
        rl.clearBackground(.dark_gray);
        try state.draw_tiles(sheet);

        if (rl.isKeyPressed(.e) or rl.isKeyDown(.q)) {
            const x = std.crypto.random.intRangeAtMost(u32, 0, GRID_SIZE);
            const y = std.crypto.random.intRangeAtMost(u32, 0, GRID_SIZE);

            if (x * y == GRID_SIZE * GRID_SIZE) {
                var random_tile = &state.tilemap[x * y - 1];
                random_tile.kind = .grass;
            } else {
                var random_tile = &state.tilemap[x * y];
                random_tile.kind = .grass;
            }
        }

        state.scene.end();

        draw_final_scene(state.scene);
    }
}

/// updates the global WINDOW_WIDTH and WINDOW_HEIGHT variables
fn setup_window() void {
    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "jsjam");
    const monitor = rl.getCurrentMonitor();
    WINDOW_WIDTH = rl.getMonitorWidth(monitor);
    WINDOW_HEIGHT = rl.getMonitorHeight(monitor);
    rl.setWindowSize(WINDOW_WIDTH, WINDOW_HEIGHT);
}

/// where we draw the final texture on to the screen
/// it is drawn at a fixed resolution regardless of screen size / dimensions
fn draw_final_scene(scene: rl.RenderTexture) void {
    rl.beginDrawing();
    rl.drawTexturePro(scene.texture, .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(RENDER_WIDTH),
        .height = @floatFromInt(-RENDER_HEIGHT),
    }, .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(WINDOW_WIDTH),
        .height = @floatFromInt(WINDOW_HEIGHT),
    }, rl.Vector2.zero(), 0, .white);
    rl.endDrawing();
}

fn project_to_screen(x: i32, y: i32, tile_width: i32, tile_height: i32) !rl.Vector2 {
    // This makes the grid skewed and look more "angled"
    return rl.Vector2{
        .x = @floatFromInt((x - y) * (try std.math.divFloor(i32, tile_width, 2))),
        .y = @floatFromInt((x + y) * (try std.math.divFloor(i32, tile_height, 2))),
    };
}
