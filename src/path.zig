const std = @import("std");
const math = std.math;
const rl = @import("raylib");

pub const Path = struct {
    path: []rl.Vector2,

    pub fn find(
        allocator: std.mem.Allocator,
        grid: [][]bool,
        start: rl.Vector2,
        goal: rl.Vector2,
    ) !Path {
        return find_path(allocator, grid, start, goal);
    }
};

const Node = struct {
    point: rl.Vector2,
    cost: f64, // f = g + heuristic
    g: f64, // cost so far
};

fn node_cmp(_: u8, a: Node, b: Node) std.math.Order {
    if (a.cost < b.cost) return .lt;
    if (a.cost > b.cost) return .gt;
    return .eq;
}

fn movement_cost(dir: rl.Vector2) f64 {
    if (dir.x != 0 and dir.y != 0) return 1.414;
    return 1.0;
}

fn heuristic(a: rl.Vector2, b: rl.Vector2) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return std.math.sqrt(dx * dx + dy * dy);
}

/// Helper: convert (x, y) to a 1D index.
fn idx(x: usize, y: usize, width: usize) usize {
    return y * width + x;
}

///
/// Computes an A* path on the given collision map.
/// - `grid` is a slice of rows (each row is a slice of booleans)
///   where `true` means walkable and `false` is a collision.
/// - `start` and `goal` are the positions to pathfind between.
/// Returns a dynamically allocated slice of Points representing the path,
/// which the caller must free.
///
/// Note: This implementation “flattens” the 2D grid into 1D arrays for
/// tracking costs and parent pointers.
fn find_path(
    allocator: std.mem.Allocator,
    grid: [][]bool,
    start: rl.Vector2,
    goal: rl.Vector2,
) !Path {
    // Validate grid dimensions.
    const grid_height = grid.len;
    if (grid_height == 0) return error.InvalidGrid;
    const grid_width = grid[0].len;
    if (grid_width == 0) return error.InvalidGrid;

    var cost_so_far = try std.ArrayList(f64).initCapacity(allocator, grid_width * grid_height);
    var came_from = try std.ArrayList(?rl.Vector2).initCapacity(allocator, grid_width * grid_height);
    cost_so_far.expandToCapacity();
    came_from.expandToCapacity();

    // Initialize arrays: set all costs to "infinity" and all parents to null.
    for (cost_so_far.items) |*cell| {
        cell.* = std.math.inf(f64);
    }
    for (came_from.items) |*cell| {
        cell.* = null;
    }

    cost_so_far.items[idx(@intFromFloat(start.x), @intFromFloat(start.y), grid_width)] = 0;

    var open_set = std.PriorityQueue(Node, u8, node_cmp).init(allocator, 0);
    defer open_set.deinit();

    const start_node: Node = .{
        .point = start,
        .g = 0,
        .cost = heuristic(start, goal),
    };
    try open_set.add(start_node);

    const directions: [4]rl.Vector2 = .{
        .{ .x = 1, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 0, .y = -1 },
        //        .{ .x = 1, .y = 1 },
        //        .{ .x = 1, .y = -1 },
        //        .{ .x = -1, .y = 1 },
        //        .{ .x = -1, .y = -1 },
    };

    var found = false;

    // A* search loop.
    while (open_set.count() != 0) {
        const current: Node = open_set.removeOrNull() orelse break;
        if (current.point.x == goal.x and current.point.y == goal.y) {
            found = true;
            break;
        }

        for (directions) |dir| {
            const next_x: i32 = @intFromFloat(current.point.x + dir.x);
            const next_y: i32 = @intFromFloat(current.point.y + dir.y);

            if (next_x < 0 or next_x >= @as(i32, @intCast(grid_width))) continue;
            if (next_y < 0 or next_y >= @as(i32, @intCast(grid_height))) continue;

            const walkable = !grid[@intCast(next_y)][@intCast(next_x)];
            const index = idx(@intCast(next_x), @intCast(next_y), grid_width);

            // Skip if the cell is not walkable.
            if (!walkable) {
                continue;
            }

            const new_cost = current.g + movement_cost(dir);
            if (new_cost < cost_so_far.items[index]) {
                cost_so_far.items[index] = new_cost;
                const f_next_x: f32 = @floatFromInt(next_x);
                const f_next_y: f32 = @floatFromInt(next_y);
                const priority = new_cost + heuristic(.{ .x = f_next_x, .y = f_next_y }, goal);
                const next_node = Node{
                    .point = .{ .x = f_next_x, .y = f_next_y },
                    .g = new_cost,
                    .cost = priority,
                };
                try open_set.add(next_node);
                came_from.items[index] = current.point;
            }
        }
    }

    if (!found) {
        cost_so_far.deinit();
        came_from.deinit();
        return error.PathNotFound;
    }

    // Reconstruct the path from goal back to start.
    var path = std.ArrayList(rl.Vector2).init(allocator);
    var current_point = goal;
    while (true) {
        try path.append(current_point);
        if (current_point.x == start.x and current_point.y == start.y) break;
        const index = idx(@intFromFloat(current_point.x), @intFromFloat(current_point.y), grid_width);
        const prev = came_from.items[index];
        if (prev == null) break;
        current_point = prev.?;
    }

    // Reverse the path so it runs from start to goal.
    for (0..@divTrunc(path.items.len, 2)) |i| {
        const tmp = path.items[i];
        path.items[i] = path.items[path.items.len - 1 - i];
        path.items[path.items.len - 1 - i] = tmp;
    }

    // Clean up temporary arrays.
    cost_so_far.deinit();
    came_from.deinit();

    return .{ .path = try path.toOwnedSlice() };
}
