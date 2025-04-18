const std = @import("std");
const rl = @import("raylib");
const tatl = @import("tatl.zig");
const animator = @import("animator.zig");
const path = @import("path.zig");

var WINDOW_WIDTH: i32 = 1080;
var WINDOW_HEIGHT: i32 = 720;
const RENDER_WIDTH: i32 = 1080;
const RENDER_HEIGHT: i32 = 720;

const GRID_SIZE: usize = 45;
const TOP_PADDING: usize = 0;

const TILE_WIDTH: usize = 32;
const TILE_HEIGHT: usize = 16;

const tile_type = enum(u8) {
    tundra = 0,
    path,
    grass,
    rock,
    water = 10,
};

// what is on top of a tile
const tile_occupation = enum(u8) {
    generic_but_occupied = 0,
    bush,
    rock,
};

const Tile = struct {
    kind: tile_type = .tundra,
    y: f32 = 0,
    occupation: ?tile_occupation = null,

    pub fn occupied(tile: Tile) bool {
        return tile.kind == .water or tile.occupation != null;
    }
};

const Direction = enum {
    SW,
    NW,
    SE,
    NE,

    fn from_direction(dx: f32, dy: f32) Direction {
        if (dx > 0) {
            return .SE;
        } else if (dx < 0) {
            return .NW;
        } else if (dy < 0) {
            return .NE;
        } else {
            return .SW;
        }
    }
};

const StagAnimationStates = enum {
    walk,
    run,
    idle,
};

const StagAgentState = enum {
    migrating_leading,
    migrating_following,
    grazing,
    moving_to_graze,
};

const Stag = struct {
    animator: *animator.Animator(StagAnimationStates),
    frame: usize = 0,
    frame_time: u16 = 0,
    direction: Direction = .NE,
    animation_state: StagAnimationStates = .idle,
    position: rl.Vector2,
    path: ?path.Path = null,
    path_step: u16 = 0,
    agent_state: StagAgentState = .grazing,

    pub fn set_animation(self: *Stag, state: StagAnimationStates) void {
        self.animation_state = state;
        self.frame = 0;
        self.frame_time = 0;
    }

    pub fn draw(self: Stag) void {
        const frames = self.animator.get_frames(self.animation_state);
        const tex_idx = self.animator.get_texture(@tagName(self.direction)).?;

        const cel = frames[self.frame].texture_cels[tex_idx];
        const screen_pos = project_to_screen(self.position.x, self.position.y);
        rl.drawTexture(cel.texture, @as(i32, @intFromFloat(screen_pos.x - @divTrunc(self.animator.canvas_size.x, 2))) + cel.x, @as(i32, @intFromFloat(screen_pos.y - @divTrunc(self.animator.canvas_size.y, 2))) + cel.y, .white);
        //
        //rl.drawText(@tagName(self.agent_state), @intFromFloat(screen_pos.x), @intFromFloat(screen_pos.y), 12, .white);
    }

    fn move_to_do_at_target(self: *Stag, dt: u16, cb: fn (*Stag) void) void {
        if (self.path) |route| {
            if (self.path_step < route.path.len) {
                const target = route.path[self.path_step];

                if (self.position.distance(target) < 0.1) {
                    self.position = target;
                    self.path_step += 1;
                } else {
                    const dx = target.x - self.position.x;
                    const dy = target.y - self.position.y;
                    self.direction = Direction.from_direction(dx, dy);
                }

                self.position = self.position.moveTowards(target, 4 * @as(f32, @floatFromInt(dt)) / 1000);
            } else {
                cb(self);
            }
        }
    }

    fn move_to_graze_at_target(self: *Stag) void {
        self.path = null;
        self.set_animation(.idle);
        self.agent_state = .grazing;
    }

    pub fn update(self: *Stag, dt: u16, state: *State) void {
        const frames = self.animator.get_frames(self.animation_state);
        const current_frame = frames[self.frame];
        if (self.frame_time + dt > current_frame.duration) {
            self.frame = (self.frame + 1) % (frames.len);
            self.frame_time = 0;
        } else {
            self.frame_time += dt;
        }

        switch (self.agent_state) {
            .migrating_leading => {},
            .migrating_following => {},
            .moving_to_graze => {
                self.move_to_do_at_target(dt, move_to_graze_at_target);
            },
            .grazing => {
                // right after first loop is completed
                std.debug.assert(self.animation_state == .idle);
                if (self.frame == 0 and self.frame_time == 0) {
                    for (0..5) |_| {
                        const x = std.crypto.random.intRangeAtMost(i32, -3, 3);
                        const y = std.crypto.random.intRangeAtMost(i32, -3, 3);

                        const random_pos: rl.Vector2 = .{ .x = self.position.x + @as(f32, @floatFromInt(x)), .y = self.position.y + @as(f32, @floatFromInt(y)) };
                        if (state.get_tile_at(@intFromFloat(random_pos.x), @intFromFloat(random_pos.y))) |tile| {
                            if (tile.occupied()) continue;
                            self.path = path.Path.find(state.allocator, state.collisions, self.position, random_pos) catch null;
                            self.path_step = 0;
                            self.set_animation(.walk);
                            self.agent_state = .moving_to_graze;
                            return;
                        }
                    }
                }
            },
        }
    }
};

const Ripple = struct {
    x: i32,
    y: i32,
    radius: usize,

    interval_frames: i32,
    frame_count: usize = 0,
    current_wave: usize = 1,
    strength: f32 = 9,

    on_tile_fn: *const fn (*Ripple, *Tile) void = offset_tile,

    pub fn update(self: *Ripple, state: *State) void {
        self.frame_count += 1;
        if (self.frame_count >= self.interval_frames) {
            self.ripple(state);
            self.current_wave += 1;
            self.frame_count = 0;
        }
    }

    pub fn offset_tile_and_change_tile_to_water(self: *Ripple, tile: *Tile) void {
        tile.y = self.strength;
        tile.kind = .water;
    }

    pub fn offset_tile(self: *Ripple, tile: *Tile) void {
        tile.y = self.strength;
    }

    fn ripple(self: *Ripple, state: *State) void {
        const radius: usize = self.current_wave;
        const ix: i32 = self.x;
        const iy: i32 = self.y;
        state.do_for_tile_at_radius(radius, ix, iy, *Ripple, self, self.on_tile_fn);
    }
};

const State = struct {
    tilemap: [GRID_SIZE * GRID_SIZE]Tile,
    scene: rl.RenderTexture,
    collisions: [][]bool = undefined,
    allocator: std.mem.Allocator,
    stags: std.ArrayListUnmanaged(Stag),
    ripples: std.ArrayListUnmanaged(Ripple),

    pub fn init(allocator: std.mem.Allocator) !State {
        const collisions = try allocator.alloc([]bool, GRID_SIZE);
        for (collisions) |*row| {
            row.* = try allocator.alloc(bool, GRID_SIZE);
            // this is cancer but must be done for wasm support
            for (row.*) |*cell| {
                cell.* = false;
            }
        }

        var tilemap: [GRID_SIZE * GRID_SIZE]Tile = undefined;
        for (0..tilemap.len) |i| {
            // this is cancer but must be done for wasm support
            tilemap[i] = Tile{ .kind = .tundra, .occupation = null, .y = 0 };
        }

        return .{
            .tilemap = tilemap,
            .scene = try rl.loadRenderTexture(RENDER_WIDTH, RENDER_HEIGHT),
            .collisions = collisions,
            .allocator = allocator,
            .stags = .{},
            .ripples = .{},
        };
    }

    pub fn do_for_tile_at_radius(self: *State, radius: usize, ix: i32, iy: i32, T: type, instance: T, callback: *const fn (T, *Tile) void) void {
        for (0..radius * 2 + 1) |double_x| {
            for (0..radius * 2 + 1) |double_y| {
                const x: i32 = @as(i32, @intCast(double_x)) - @as(i32, @intCast(radius));
                const y: i32 = @as(i32, @intCast(double_y)) - @as(i32, @intCast(radius));
                if (@max(@abs(x), @abs(y)) == radius) {
                    const i: i32 = x + ix;
                    const j: i32 = y + iy;
                    if (self.get_tile_at(i, j)) |tile_found| {
                        callback(instance, tile_found);
                    }
                }
            }
        }
    }

    pub fn get_tile_at(self: *State, x: i32, y: i32) ?*Tile {
        if (x < 0 or x > GRID_SIZE) return null;
        if (y < 0 or y > GRID_SIZE) return null;
        const idx = @as(usize, @intCast(x)) + GRID_SIZE * @as(usize, @intCast(y));
        if (idx >= GRID_SIZE * GRID_SIZE) return null;
        return &self.tilemap[idx];
    }

    pub fn update(self: *State, dt: u16) !void {
        for (&self.tilemap, 0..) |*tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            switch (tile.kind) {
                .tundra => {
                    // these are on purpose independent
                    const uptick = std.crypto.random.float(f32) > 0.94;
                    const crit = std.crypto.random.float(f32) > 0.98;
                    if (self.get_tile_at(x, y + 1)) |above| {
                        if (above.kind == .water and uptick) {
                            tile.kind = .grass;
                            if (crit) {
                                tile.occupation = .bush;
                            }
                            continue;
                        }
                    }
                    if (self.get_tile_at(x, y - 1)) |below| {
                        if (below.kind == .water and uptick) {
                            tile.kind = .grass;
                            if (crit) {
                                tile.occupation = .bush;
                            }
                            continue;
                        }
                    }
                    if (self.get_tile_at(x - 1, y)) |left| {
                        if (left.kind == .water and uptick) {
                            tile.kind = .grass;
                            if (crit) {
                                tile.occupation = .bush;
                            }
                            continue;
                        }
                    }
                    if (self.get_tile_at(x + 1, y)) |right| {
                        if (right.kind == .water and uptick) {
                            tile.kind = .grass;
                            if (crit) {
                                tile.occupation = .bush;
                            }
                            continue;
                        }
                    }
                },
                .path => {
                    // these are on purpose independent
                    const uptick = std.crypto.random.float(f32) > 0.96;
                    if (self.get_tile_at(x, y + 1)) |above| {
                        if (above.kind == .water and uptick) {
                            tile.kind = .water;
                            continue;
                        }
                    }
                    if (self.get_tile_at(x, y - 1)) |below| {
                        if (below.kind == .water and uptick) {
                            tile.kind = .water;
                            continue;
                        }
                    }
                    if (self.get_tile_at(x - 1, y)) |left| {
                        if (left.kind == .water and uptick) {
                            tile.kind = .water;
                            continue;
                        }
                    }
                    if (self.get_tile_at(x + 1, y)) |right| {
                        if (right.kind == .water and uptick) {
                            tile.kind = .water;
                            continue;
                        }
                    }
                },
                else => {},
            }
        }

        for (self.tilemap, 0..) |tile, i| {
            const x: usize = try std.math.mod(usize, i, GRID_SIZE);
            const y: usize = try std.math.divFloor(usize, i, GRID_SIZE);
            self.collisions[y][x] = tile.occupied();
        }

        for (self.stags.items) |*stag| {
            stag.update(dt, self);
        }
    }

    pub fn draw_tiles(self: State, sheet: rl.Texture) !void {
        const sheet_rows = try std.math.divFloor(i32, sheet.width, TILE_WIDTH);

        for (self.tilemap, 0..) |tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            var screen_pos = project_to_screen(@floatFromInt(x), @floatFromInt(y));

            screen_pos.x -= @divTrunc(TILE_WIDTH, 2);
            screen_pos.y += tile.y;

            var rand = std.Random.DefaultPrng.init(i);
            const r = try std.math.mod(u64, rand.next(), @intCast(sheet_rows));

            rl.drawTextureRec(
                sheet,
                .{
                    .x = @floatFromInt(TILE_WIDTH * r),
                    .y = @as(f32, @floatFromInt(@intFromEnum(tile.kind))) * TILE_WIDTH,
                    .width = TILE_WIDTH,
                    .height = TILE_WIDTH,
                },
                screen_pos,
                .white,
            );

            if (tile.occupation) |occupation| {
                switch (occupation) {
                    .bush => {
                        const source_r: usize = @intCast(sheet_rows - 3 + @as(i32, @intCast(@mod(rand.next(), 3))));
                        screen_pos.y -= @divTrunc(TILE_HEIGHT, 2);
                        rl.drawTextureRec(
                            sheet,
                            .{
                                .x = @floatFromInt(TILE_WIDTH * source_r),
                                .y = 3 * TILE_WIDTH,
                                .width = TILE_WIDTH,
                                .height = TILE_WIDTH,
                            },
                            screen_pos,
                            .white,
                        );
                    },
                    .generic_but_occupied => {},
                    else => {},
                }
            }
        }
    }

    pub fn deinit(_: State, _: std.mem.Allocator) void {}
};

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

fn project_to_screen(x: f32, y: f32) rl.Vector2 {
    // This makes the grid skewed and look more "angled"
    const half_screen: f32 = @floatFromInt(@divFloor(RENDER_WIDTH, 2));
    var screen_pos: rl.Vector2 = .{
        .x = ((x - y) * (@divFloor(TILE_WIDTH, 2))),
        .y = ((x + y) * (@divFloor(TILE_HEIGHT, 2))),
    };

    screen_pos.x += half_screen;
    screen_pos.y += TOP_PADDING;
    return screen_pos;
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

// TODO refactor
fn pop_radius(self: *State, radius: usize, ix: i32, iy: i32) void {
    for (0..radius * 2 + 1) |double_x| {
        for (0..radius * 2 + 1) |double_y| {
            const x: i32 = @as(i32, @intCast(double_x)) - @as(i32, @intCast(radius));
            const y: i32 = @as(i32, @intCast(double_y)) - @as(i32, @intCast(radius));
            if (@max(@abs(x), @abs(y)) == radius) {
                const i: i32 = x + ix;
                const j: i32 = y + iy;
                if (self.get_tile_at(i, j)) |tile_found| {
                    tile_found.y = -5 * @as(f32, @floatFromInt(radius));
                }
            }
        }
    }
}

pub fn main() anyerror!void {
    const flip = @import("builtin").target.os.tag != .emscripten;
    var gpa: if (flip) std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }) else struct {} = .{};
    if (flip) gpa.requested_memory_limit = 1_000_000;
    const allocator: std.mem.Allocator = if (flip) gpa.allocator() else std.heap.c_allocator;
    if (flip) setup_window() else rl.initWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "please work");
    defer rl.closeWindow();

    const zlib = std.compress.zlib;
    const t = try std.fs.cwd().openFile("resources/test", .{});
    const zlib_stream = zlib.decompressor(t.reader());
    _ = zlib_stream;

    const sheet = try rl.loadTexture("resources/spritesheet.png");
    const file = try std.fs.cwd().openFile("resources/critters/aseprite files/critter_stag.aseprite", .{});
    const ase = tatl.import(allocator, file.reader()) catch @panic("failed parsing aseprite file");
    var anim = try animator.Animator(StagAnimationStates).load(ase, allocator);

    rl.setTargetFPS(60);
    var state = try State.init(allocator);
    defer state.deinit(allocator);
    file.close();
    ase.free(allocator);

    try state.stags.append(allocator, .{ .animator = &anim, .position = rl.Vector2.zero() });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 20, .y = 13 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 30, .y = 23 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 2, .y = 23 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 6, .y = 1 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 22, .y = 32 } });

    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 22, .y = 13 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 33, .y = 23 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 4, .y = 25 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 8, .y = 3 } });
    try state.stags.append(allocator, .{ .animator = &anim, .position = .{ .x = 24, .y = 32 } });

    while (!rl.windowShouldClose()) {
        const mouse_position = get_mouse_screen_position();

        try state.update(8);

        // ignoring temporary render display on wasm because it is broken
        if (flip) state.scene.begin() else rl.beginDrawing();

        rl.clearBackground(.dark_gray);
        try state.draw_tiles(sheet);

        var world_pos = mouse_position;
        const half_screen = try std.math.divFloor(f32, RENDER_WIDTH, 2);
        world_pos.x -= half_screen;
        world_pos.y -= TOP_PADDING;

        const grid_pos = try screen_to_grid(world_pos);

        // temporary
        for (&state.tilemap) |*tile| {
            if (tile.y != 0) {
                tile.y /= 1.1;

                if (@abs(tile.y) < 0.5) {
                    tile.y = 0;
                }
            }
        }

        const ix: i32 = @intFromFloat(grid_pos.x);
        const iy: i32 = @intFromFloat(grid_pos.y);
        if (state.get_tile_at(ix, iy)) |tile| {
            if (rl.isKeyPressed(.q)) {
                try state.ripples.append(state.allocator, .{ .x = ix, .y = iy, .radius = 4, .interval_frames = 6 });
            }
            if (rl.isKeyDown(.e)) {
                tile.kind = .water;
                tile.occupation = null;
            }

            tile.y = -4;
        }

        for (state.stags.items) |stag| {
            stag.draw();
        }

        for (state.ripples.items, 0..) |*ripple, i| {
            ripple.on_tile_fn = Ripple.offset_tile_and_change_tile_to_water;
            ripple.update(&state);

            if (ripple.radius == ripple.current_wave) {
                // TODO
                // this should instead iterate via idx to safely remove. but fix later
                _ = state.ripples.swapRemove(i);
            }
        }

        // ignoring temporary render display on wasm because it is broken
        if (flip) {
            draw_final_scene(state.scene);
            state.scene.end();
        } else rl.endDrawing();
    }
}
