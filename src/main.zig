const std = @import("std");
const rl = @import("raylib");

var WINDOW_WIDTH: i32 = 1080;
var WINDOW_HEIGHT: i32 = 720;
const RENDER_WIDTH: i32 = 1080;
const RENDER_HEIGHT: i32 = 720;

const GRID_SIZE: usize = 25;
const TOP_PADDING: usize = 40;

const TILE_WIDTH: usize = 32;
const TILE_HEIGHT: usize = 16;

const tile_type = enum(u8) {
    tundra = 0,
    dirt,
    grass,
    rock,
    water = 10,
};

const Tile = struct {
    kind: tile_type = .tundra,
    y: f32 = 0,
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
        const sheet_rows = try std.math.divFloor(i32, sheet.width, TILE_WIDTH);

        for (self.tilemap, 0..) |tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            var screen_pos = try project_to_screen(x, y);

            const half_screen = try std.math.divFloor(f32, RENDER_WIDTH, 2);
            screen_pos.x += half_screen;
            screen_pos.y += TOP_PADDING;

            screen_pos.x -= @divTrunc(TILE_WIDTH, 2);

            var rand = std.Random.DefaultPrng.init(i);
            const r = try std.math.mod(u64, rand.next(), @intCast(sheet_rows));

            rl.drawTextureRec(
                sheet,
                .{
                    .x = @floatFromInt(TILE_WIDTH * r),
                    .y = @as(f32, @floatFromInt(@intFromEnum(tile.kind))) * TILE_WIDTH + tile.y,
                    .width = TILE_WIDTH,
                    .height = TILE_WIDTH,
                },
                screen_pos,
                .white,
            );
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
        const mouse_position = get_mouse_screen_position();
        state.scene.begin();
        rl.clearBackground(.dark_gray);
        try state.draw_tiles(sheet);

        var world_pos = mouse_position;
        const half_screen = try std.math.divFloor(f32, RENDER_WIDTH, 2);
        world_pos.x -= half_screen;
        world_pos.y -= TOP_PADDING;

        const grid_pos = try screen_to_grid(world_pos);

        // temporary
        for (&state.tilemap) |*tile| {
            tile.y = 0;
        }

        if (grid_pos.x > 0 and grid_pos.x < GRID_SIZE and grid_pos.y > 0 and grid_pos.y < GRID_SIZE) {
            const int_y: usize = @intFromFloat(grid_pos.y);
            const int_x: usize = @intFromFloat(grid_pos.x);
            var tile = &state.tilemap[int_y * GRID_SIZE + int_x];
            if (rl.isKeyDown(.q)) {
                tile.kind = .grass;
            }
            if (rl.isKeyDown(.e)) {
                tile.kind = .water;
            }

            tile.y = 4;
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

fn get_mouse_screen_position() rl.Vector2 {
    const mouse_position = rl.getMousePosition();
    return mouse_position.multiply(.{
        .x = @as(f32, @floatFromInt(RENDER_WIDTH)) / @as(f32, @floatFromInt(WINDOW_WIDTH)),
        .y = @as(f32, @floatFromInt(RENDER_HEIGHT)) / @as(f32, @floatFromInt(WINDOW_HEIGHT)),
    });
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

fn project_to_screen(x: i32, y: i32) !rl.Vector2 {
    // This makes the grid skewed and look more "angled"
    return rl.Vector2{
        .x = @floatFromInt((x - y) * (try std.math.divFloor(i32, TILE_WIDTH, 2))),
        .y = @floatFromInt((x + y) * (try std.math.divFloor(i32, TILE_HEIGHT, 2))),
    };
}

fn screen_to_grid(screen_pos: rl.Vector2) !rl.Vector2 {
    const w = @as(f32, @floatFromInt(TILE_WIDTH));
    const h = @as(f32, @floatFromInt(TILE_HEIGHT));

    const a = w / 2.0;
    const b = -w / 2.0;
    const c = h / 2.0;
    const d = h / 2.0;

    const det = a * d - b * c;
    if (det == 0.0) return error.InvalidMatrix;

    const inv_a = d / det;
    const inv_b = -b / det;
    const inv_c = -c / det;
    const inv_d = a / det;

    return .{
        .x = screen_pos.x * inv_a + screen_pos.y * inv_b,
        .y = screen_pos.x * inv_c + screen_pos.y * inv_d,
    };
}
