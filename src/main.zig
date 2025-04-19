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

const building_type = enum(u8) {
    water_pump,
    excavator,
};

const BuildingParameter = union(building_type) {
    water_pump,
    excavator: Direction,
};

const Building = struct {
    kind: building_type = .water_pump,

    pub fn draw(self: Building, position: rl.Vector2) void {
        const screen_pos = project_to_screen(position.x, position.y);
        switch (self.kind) {
            .water_pump => rl.drawCircleV(screen_pos, 15, .blue),
            .excavator => rl.drawCircleV(screen_pos, 15, .red),
        }
    }

    pub fn water_pump_land(pod: *Pod, state: *State, _: ?BuildingParameter) void {
        const ix: i32 = @intFromFloat(pod.position.x);
        const iy: i32 = @intFromFloat(pod.position.y);
        if (state.get_tile_at(ix, iy)) |tile| {
            tile.occupation = .{ .building = .{ .kind = .water_pump } };
            tile.kind = .water;

            var ripple: Ripple = .{ .x = ix, .y = iy, .radius = 4, .interval_frames = 16 };
            ripple.on_tile_fn = Ripple.offset_tile_and_change_random_to_rock;
            state.ripples.append(state.allocator, ripple) catch std.log.err("failed to add ripple", .{});
        }
    }

    pub fn excavator_land(pod: *Pod, state: *State, param: ?BuildingParameter) void {
        const direction = param.?.excavator;
        if (state.get_tile_at(@intFromFloat(pod.position.x), @intFromFloat(pod.position.y))) |tile| {
            tile.occupation = .{ .building = .{ .kind = .excavator } };
        }

        for (0..10) |i| {
            var dir_vector = direction.to_vec();
            dir_vector = dir_vector.scale(@floatFromInt(i));
            const tile_grid_position = pod.position.add(dir_vector);
            if (state.get_tile_at(@intFromFloat(tile_grid_position.x), @intFromFloat(tile_grid_position.y))) |tile| {
                if (!tile.occupied()) {
                    tile.kind = .path;
                }
            }
        }
    }
};

const Pod = struct {
    end_pos_grid: rl.Vector2,
    position: rl.Vector2,

    building_parameter: ?BuildingParameter = null,

    should_cleanup: bool = false,
    on_land_cb: *const fn (*Pod, *State, ?BuildingParameter) void,

    pub fn init(end_pos_grid: rl.Vector2, start_position: rl.Vector2, building: BuildingParameter) Pod {
        return .{
            .end_pos_grid = end_pos_grid,
            .position = start_position,
            .on_land_cb = switch (building) {
                .excavator => Building.excavator_land,
                .water_pump => Building.water_pump_land,
            },
            .building_parameter = building,
        };
    }

    pub fn update(self: *Pod, state: *State, dt: u16) void {
        const target = self.end_pos_grid;
        if (self.position.distance(target) < 0.1) {
            self.position = target;
            self.on_land_cb(self, state, self.building_parameter);
            self.should_cleanup = true;
        }

        self.position = self.position.moveTowards(target, 12 * @as(f32, @floatFromInt(dt)) / 1000);
    }

    pub fn draw(self: *Pod) void {
        const screen_pos = project_to_screen(self.position.x, self.position.y);
        rl.drawCircleV(screen_pos, 12, .yellow);
    }
};

const tile_type = enum(u8) {
    tundra = 0,
    path,
    grass,
    rock = 5,
    water = 10,
    soil,
};

// what is on top of a tile
const tile_occupation = union(enum(u8)) {
    generic_but_occupied = 0,
    bush,
    rock,
    water_particle,
    building: Building,
};

const Tile = struct {
    kind: tile_type = .tundra,
    y: f32 = 0,
    occupation: ?tile_occupation = null,

    pub fn occupied(tile: Tile) bool {
        return switch (tile.kind) {
            .water, .path => true,
            else => tile.occupation != null,
        };
    }
};

const Direction = enum(u6) {
    SW,
    NW,
    SE,
    NE,

    pub fn from_direction(dx: f32, dy: f32) Direction {
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

    pub fn to_vec(self: Direction) rl.Vector2 {
        return switch (self) {
            .SW => rl.Vector2{ .x = 0, .y = 1 },
            .NW => rl.Vector2{ .x = -1, .y = 0 },
            .SE => rl.Vector2{ .x = 1, .y = 0 },
            .NE => rl.Vector2{ .x = 0, .y = -1 },
        };
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

    pub fn offset_tile_and_change_tile_to_path(self: *Ripple, tile: *Tile) void {
        tile.y = self.strength;
        tile.kind = .path;
    }

    pub fn offset_tile_and_change_random_to_rock(self: *Ripple, tile: *Tile) void {
        tile.y = self.strength;
        if (std.crypto.random.float(f32) >= 0.88) {
            tile.kind = .rock;
            if (std.crypto.random.float(f32) >= 0.5) tile.occupation = .rock;
        }
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
    pods: std.ArrayListUnmanaged(Pod),
    ghost_building: ?BuildingParameter = null,

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
            .pods = .{},
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

    fn for_adjecent_tiles(self: *State, tile: *Tile, x: i32, y: i32, do_func_cb: fn (*Tile, *Tile) bool) void {
        if (self.get_tile_at(x, y + 1)) |above| {
            if (do_func_cb(tile, above)) return;
        }
        if (self.get_tile_at(x, y - 1)) |below| {
            if (do_func_cb(tile, below)) return;
        }
        if (self.get_tile_at(x - 1, y)) |left| {
            if (do_func_cb(tile, left)) return;
        }
        if (self.get_tile_at(x + 1, y)) |right| {
            if (do_func_cb(tile, right)) return;
        }
    }

    fn convert_tundra_to_water(self: *Tile, other: *Tile) bool {
        // these are on purpose independent
        const uptick = std.crypto.random.float(f32) > 0.94;
        const crit = std.crypto.random.float(f32) > 0.98;
        if (other.kind == .water and uptick) {
            self.kind = .grass;
            if (crit) {
                self.occupation = .bush;
                return true;
            }
        }

        return false;
    }

    fn convert_path_to_water(self: *Tile, other: *Tile) bool {
        const uptick = std.crypto.random.float(f32) > 0.96;
        if (other.kind == .water and uptick) {
            self.kind = .water;
            return true;
        }

        return false;
    }

    pub fn update(self: *State, dt: u16) !void {
        for (&self.tilemap, 0..) |*tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            switch (tile.kind) {
                .tundra => for_adjecent_tiles(self, tile, x, y, convert_tundra_to_water),
                .path => for_adjecent_tiles(self, tile, x, y, convert_path_to_water),
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

    fn draw_tile(sheet: rl.Texture, kind: tile_type, source_x: f32, screen_pos: rl.Vector2) void {
        draw_tile_color(sheet, kind, source_x, screen_pos, .white);
    }

    fn draw_tile_color(sheet: rl.Texture, kind: tile_type, source_x: f32, screen_pos: rl.Vector2, color: rl.Color) void {
        rl.drawTextureRec(
            sheet,
            .{
                .x = source_x,
                .y = @as(f32, @floatFromInt(@intFromEnum(kind))) * TILE_WIDTH,
                .width = TILE_WIDTH,
                .height = TILE_WIDTH,
            },
            screen_pos,
            color,
        );
    }

    fn draw_ghost(self: *State, grid_pos: rl.Vector2, sheet: rl.Texture) void {
        // i don't really like this. but is safer
        // ideally we should ensure that we don't try to draw ghost every without a ghost building
        if (self.ghost_building) |building| {
            const screen_pos = project_to_screen(grid_pos.x, grid_pos.y);

            switch (building) {
                .excavator => |direction| {
                    rl.drawCircleV(screen_pos, 15, .red);
                    for (1..10) |i| {
                        var dir_vector = direction.to_vec();
                        dir_vector = dir_vector.scale(@floatFromInt(i));
                        // TODO
                        // some bug with drawing tiles at x + 1. This is shown also when we try to interact with the tiles at max X.
                        // i believe this causes this artifact where have to off by one when drawing these ghost blocks
                        const tile_grid_position_sub_one = grid_pos.subtract(.{ .x = 1, .y = 0 });
                        const tile_grid_position = tile_grid_position_sub_one.add(dir_vector);

                        draw_tile_color(sheet, .path, 0, project_to_screen(tile_grid_position.x, tile_grid_position.y), .{ .a = 100, .r = 0, .g = 128, .b = 0 });
                    }
                },
                .water_pump => {
                    rl.drawCircleV(screen_pos, 15, .blue);
                },
            }
        }
    }

    pub fn draw_tiles(self: *State, sheet: rl.Texture) !void {
        const sheet_rows = try std.math.divFloor(i32, sheet.width, TILE_WIDTH);

        for (self.tilemap, 0..) |tile, i| {
            const x: i32 = @intCast(try std.math.mod(usize, i, GRID_SIZE));
            const y: i32 = @intCast(try std.math.divFloor(usize, i, GRID_SIZE));

            var screen_pos = project_to_screen(@floatFromInt(x), @floatFromInt(y));

            screen_pos.x -= @divTrunc(TILE_WIDTH, 2);
            screen_pos.y += tile.y;

            var rand = std.Random.DefaultPrng.init(i);
            const r = try std.math.mod(u64, rand.next(), @intCast(sheet_rows));

            switch (tile.kind) {
                .tundra, .soil => draw_tile(sheet, tile.kind, @floatFromInt(TILE_WIDTH * r), screen_pos),
                .grass => draw_tile(sheet, tile.kind, @floatFromInt(TILE_WIDTH * @mod(r, 3)), screen_pos),
                .path => draw_tile(sheet, tile.kind, TILE_WIDTH * 0, screen_pos),
                .rock => draw_tile(sheet, tile.kind, @floatFromInt(TILE_WIDTH * (6 + @mod(r, 3))), screen_pos),
                .water => {
                    const above_tile = self.get_tile_at(x, y + 1);
                    const below_tile = self.get_tile_at(x, y - 1);
                    const left_tile = self.get_tile_at(x + 1, y);
                    const right_tile = self.get_tile_at(x - 1, y);

                    const above = (above_tile != null and above_tile.?.kind != .water);
                    const below = (below_tile != null and below_tile.?.kind != .water);
                    const left = (left_tile != null and left_tile.?.kind != .water);
                    const right = (right_tile != null and right_tile.?.kind != .water);

                    // YEAH THIS IS CURSED
                    // might drops this entirely
                    if (above and below and left and right) draw_tile(sheet, tile.kind, 9 * TILE_WIDTH, screen_pos) else if (!above and below and left and !right) draw_tile(sheet, tile.kind, 8 * TILE_WIDTH, screen_pos) else if (above and !below and !left and right) draw_tile(sheet, tile.kind, 7 * TILE_WIDTH, screen_pos) else if (above and !below and left and !right) draw_tile(sheet, tile.kind, 6 * TILE_WIDTH, screen_pos) else if (!above and below and !left and right) draw_tile(sheet, tile.kind, 5 * TILE_WIDTH, screen_pos) else if (above and !below and !left and !right) draw_tile(sheet, tile.kind, 4 * TILE_WIDTH, screen_pos) else if (!above and !below and left and !right) draw_tile(sheet, tile.kind, 3 * TILE_WIDTH, screen_pos) else if (!above and !below and !left and right) draw_tile(sheet, tile.kind, 2 * TILE_WIDTH, screen_pos) else if (!above and below and !left and !right) draw_tile(sheet, tile.kind, 1 * TILE_WIDTH, screen_pos) else draw_tile(sheet, tile.kind, 0 * TILE_WIDTH, screen_pos);
                    // BTW this is for 'autotiling'
                },
            }

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
                    .water_particle => {
                        const source_r: usize = @intCast(5 + @as(i32, @intCast(@mod(rand.next(), 3))));
                        screen_pos.y -= @divTrunc(TILE_HEIGHT, 2);
                        rl.drawTextureRec(
                            sheet,
                            .{
                                .x = @floatFromInt(TILE_WIDTH * (source_r)),
                                .y = 7 * TILE_WIDTH,
                                .width = TILE_WIDTH,
                                .height = TILE_WIDTH,
                            },
                            screen_pos,
                            .white,
                        );
                    },
                    .rock => {
                        const source_r: usize = @intCast(9 + @as(i32, @intCast(@mod(rand.next(), 2))));
                        screen_pos.y -= @divTrunc(TILE_HEIGHT, 2);
                        rl.drawTextureRec(
                            sheet,
                            .{
                                .x = @floatFromInt(TILE_WIDTH * (source_r)),
                                .y = 5 * TILE_WIDTH,
                                .width = TILE_WIDTH,
                                .height = TILE_WIDTH,
                            },
                            screen_pos,
                            .white,
                        );
                    },
                    .generic_but_occupied => {},
                    .building => |building| building.draw(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }),
                }
            }
        }
    }

    pub fn summon_building(self: *State, grid_pos: rl.Vector2, building: BuildingParameter) void {
        const pod_spawn = screen_to_grid(rl.Vector2.zero()) catch {
            std.log.err("failed to get grid position from screen position", .{});
            return;
        };
        if (self.get_tile_at(@intFromFloat(grid_pos.x), @intFromFloat(grid_pos.y))) |_| {
            self.pods.append(self.allocator, Pod.init(grid_pos, pod_spawn, building)) catch std.log.err("failed to add pod", .{});
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

pub fn main() anyerror!void {
    const flip = @import("builtin").target.os.tag != .emscripten;
    var gpa: if (flip) std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }) else struct {} = .{};
    if (flip) gpa.requested_memory_limit = 1_000_000;
    const allocator: std.mem.Allocator = if (flip) gpa.allocator() else std.heap.c_allocator;
    if (flip) setup_window() else rl.initWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "please work");
    defer rl.closeWindow();

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

    state.ghost_building = .{ .excavator = .SW };

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
            if (rl.isKeyPressed(.e)) {
                if (state.ghost_building) |parameter| state.summon_building(grid_pos, parameter);
            }
            if (rl.isKeyPressed(.r)) {
                if (state.ghost_building) |parameter| {
                    state.ghost_building = switch (parameter) {
                        .excavator => |excavator| .{ .excavator = @as(Direction, @enumFromInt(@mod(@intFromEnum(excavator) + 1, 4))) },
                        .water_pump => parameter,
                    };
                }
            }
            if (rl.isKeyPressed(.f)) {
                state.summon_building(grid_pos, .water_pump);
            }

            tile.y = -4;
        }

        if (state.ghost_building) |_| {
            state.draw_ghost(.{ .x = @floatFromInt(ix), .y = @floatFromInt(iy) }, sheet);
        }

        for (state.stags.items) |stag| {
            stag.draw();
        }

        for (state.pods.items, 0..) |*pod, i| {
            pod.update(&state, 16);
            pod.draw();

            if (pod.should_cleanup) _ = state.pods.swapRemove(i);
        }

        for (state.ripples.items, 0..) |*ripple, i| {
            ripple.update(&state);

            if (ripple.radius == ripple.current_wave) {
                // TODO
                // this should instead iterate via idx to safely remove. but fix later
                _ = state.ripples.swapRemove(i);
            }
        }

        // ignoring temporary render display on wasm because it is broken
        if (flip) {
            state.scene.end();
            draw_final_scene(state.scene);
        } else rl.endDrawing();
    }
}
