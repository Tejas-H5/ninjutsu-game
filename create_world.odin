package game

import "core:relative"
import "core:math/linalg"
import "core:math"

ISLAND_POINTS :: []Vector2i{
	Vector2i { -32, 24 },
	Vector2i { -9, 31 },
	Vector2i { -2, 39 },
	Vector2i { -4, 60 },
	Vector2i { 0, 69 },
	Vector2i { 8, 76 },
	Vector2i { 15, 77 },
	Vector2i { 39, 72 },
	Vector2i { 63, 57 },
	Vector2i { 78, 44 },
	Vector2i { 79, 30 },
	Vector2i { 83, 1 },
	Vector2i { 73, -26 },
	Vector2i { 41, -45 },
	Vector2i { 1, -48 },
	Vector2i { -26, -47 },
	Vector2i { -42, -40 },
	Vector2i { -55, -30 },
	Vector2i { -59, -13 },
	Vector2i { -57, 6 },
	Vector2i { -49, 19 },
	Vector2i { -36, 24 },
	Vector2i { -32, 24 },
}

SHORELINE_END_POINTS :: []Vector2i {
	Vector2i { -10, 20 },
	Vector2i { 14, 24 },
	Vector2i { 20, 35 },
	Vector2i { 17, 45 },
	Vector2i { 18, 53 },
	Vector2i { 22, 58 },
	Vector2i { 28, 62 },
	Vector2i { 36, 63 },
	Vector2i { 40, 61 },
	Vector2i { 46, 59 },
	Vector2i { 62, 49 },
	Vector2i { 68, 44 },
	Vector2i { 73, 38 },
	Vector2i { 71, 27 },
	Vector2i { 73, 17 },
	Vector2i { 77, 9 },
	Vector2i { 77, 5 },
	Vector2i { 76, -2 },
	Vector2i { 70, -15 },
	Vector2i { 60, -21 },
	Vector2i { 53, -27 },
	Vector2i { 43, -34 },
	Vector2i { 33, -38 },
	Vector2i { 15, -40 },
	Vector2i { -8, -39 },
	Vector2i { -26, -36 },
	Vector2i { -38, -29 },
	Vector2i { -44, -24 },
	Vector2i { -48, -14 },
	Vector2i { -46, 2 },
	Vector2i { -37, 13 },
	Vector2i { -16, 19 },
	Vector2i { -10, 20 },
}

create_world :: proc(state: ^GameState) {
	// Mainly to control infinite loops. Aint no way we can design an open world this big
	WORLD_EXTENT :: WorldArea{ lo={-2000,-2000}, hi={2000,2000} }

	WorldArea :: struct {
		lo, hi: Vector2i
	}

	world_area :: proc(from: Vector2i, to: Vector2i) -> WorldArea {
		lo := linalg.min(from, to)
		hi := linalg.max(from, to)
		return { lo, hi }
	}

	world_area_width :: proc(area: WorldArea) -> int {
		return area.hi.x - area.lo.x
	}

	world_area_height :: proc(area: WorldArea) -> int {
		return area.hi.y - area.lo.y
	}

	extend_area :: proc(area: WorldArea, lo, hi: Vector2i) -> WorldArea {
		return {
			area.lo + lo,
			area.hi + hi,
		}
	}

	absorb_point_into_area :: proc(area: WorldArea, pos: Vector2i) -> WorldArea {
		return {
			linalg.min(area.lo, pos),
			linalg.max(area.hi, pos),
		}
	}

	get_points_area :: proc(points: []Vector2i) -> WorldArea {
		result := world_area(points[0], points[0])
		for i in 1..<len(points) {
			point := points[i]
			result = absorb_point_into_area(result, point)
		}
		return result;
	}

	get_chunk :: proc(state: ^GameState, coord: Vector2i) -> ^Chunk {
		_, v, _, _ := map_entry(&state.chunks, coord)
		return v;
	}

	get_chunk_and_relative_pos :: proc(state: ^GameState, ground_pos: Vector2i, offset: Vector2 = 0) -> (^Chunk, Vector2i, Vector2) {
		coord := ground_pos_to_chunk_coord(ground_pos)
		chunk := get_chunk(state, coord)

		relative_ground_pos := ground_pos - coord * CHUNK_GROUND_ROW_COUNT
		relative_pos        := ground_pos_to_world_pos(relative_ground_pos) + offset

		assert(relative_ground_pos.x < CHUNK_GROUND_ROW_COUNT)
		assert(relative_ground_pos.y < CHUNK_GROUND_ROW_COUNT)

		return chunk, relative_ground_pos, relative_pos
	}

	DecorationPlacement :: struct {
		type: DecorationType,
		size: f32,
		pos: Vector2,
		col: Color,
	}

	add_decorations :: proc(state: ^GameState, placements: []DecorationPlacement) {
		for &p in placements {
			add_decoration_placement(state, p)
		}
	}

	add_decoration_placement :: proc(state: ^GameState, placement: DecorationPlacement) -> ^Decoration {
		ground_pos       := world_pos_to_ground_pos(placement.pos)
		ground_pos_world := ground_pos_to_world_pos(ground_pos)
		relative_pos     := placement.pos - ground_pos_world
		return add_decoration(state, placement.type, placement.size, ground_pos, relative_pos, placement.col)
	}

	add_decoration :: proc(
		state: ^GameState,
		type: DecorationType,
		size: f32,
		ground_pos: Vector2i, offset: Vector2,
		col: Color,
	) -> ^Decoration {
		chunk, ground_pos, pos := get_chunk_and_relative_pos(state, ground_pos, offset)

		hitbox_size_sprite := DECORATION_TYPES[type].hitbox_size
		hitbox_side_len := f32(hitbox_size_sprite / f32(state.assets.decorations.sprite_size)) * size
		hitbox_size := Vector2{hitbox_side_len, hitbox_side_len}

		idx := len(chunk.decorations)
		append(&chunk.decorations, Decoration{
			pos = pos,
			size = size,
			type = type,
			hitbox_size = hitbox_size,
			color = col,
		})

		return &chunk.decorations[idx]
	}

	write_to_ground :: proc(existing: ^GroundDetails, new_ground: GroundDetails) {
		if existing.type == .None || new_ground.z > existing.z {
			existing^ = new_ground
		}
	}

	// Won't overwrite ground on the same or lower z-index
	fill_ground :: proc(state: ^GameState, area: WorldArea, details: GroundDetails) {
		for x in area.lo.x..<area.hi.x {
			for y in area.lo.y..<area.hi.y {
				chunk, ground_pos, _ := get_chunk_and_relative_pos(state, {x, y})
				g := ground_at(chunk, ground_pos);
				write_to_ground(g, details)
			}
		}
	}

	fill_horizontal_line :: proc(
		state: ^GameState,
		from, to, y: int,
		inner_width: int, inner: GroundDetails,
		outer_width: int, outer: GroundDetails,
	) {
		fill_ground(state, world_area({from, y - inner_width},               {to, y + inner_width + 1}),               inner)
		fill_ground(state, world_area({from, y - inner_width - outer_width}, {to, y - inner_width }),                  outer)
		fill_ground(state, world_area({from, y + inner_width + 1},           {to, y + inner_width + 1 + outer_width}), outer)
	}

	fill_vertical_line :: proc(
		state: ^GameState,
		from, to, x: int,
		inner_width: int, inner: GroundDetails,
		outer_width: int, outer: GroundDetails,
	) {
		fill_ground(state, world_area({x - inner_width, from},               {x + inner_width + 1, to}),               inner)
		fill_ground(state, world_area({x - inner_width - outer_width, from}, {x - inner_width , to}),                  outer)
		fill_ground(state, world_area({x + inner_width + 1, from},           {x + inner_width + 1 + outer_width, to}), outer)
	}

	fill_line :: proc(state: ^GameState, from_i, to_i: Vector2i, ground: GroundDetails) {
		from := Vector2{ f32(from_i.x), f32(from_i.y) }
		to   := Vector2{ f32(to_i.x), f32(to_i.y) }
		pos  := from
		dir  := linalg.normalize0(to - from)

		if dir == 0 {return}

		ground := ground
		ground.edge_dir = linalg.dot(dir, Vector2{0, 1}) > 0 ? .Up : .Down

		for linalg.dot(dir, to - pos) > 0 {
			coord := Vector2i{ 
				int(math.floor_f32(pos.x)),
				int(math.floor_f32(pos.y)),
			}

			chunk, ground_pos, _ := get_chunk_and_relative_pos(state, coord)
			g := ground_at(chunk, ground_pos);
			write_to_ground(g, ground)

			pos += dir
		}
	}

	fill_polygon_outline :: proc(state: ^GameState, points: []Vector2i, ground: GroundDetails) {
		for i in 0..<len(points) - 1 {
			from := points[i]
			to   := points[i + 1]
			fill_line(state, from, to, ground)
		}
	}

	fill_existing_polygon_outline :: proc(state: ^GameState, area: WorldArea, ground: GroundDetails) {
		// classic scanlines algorithm. Finally get to use it, lets go.
		// It wasn't as simple as 'if found an edge, start drawing else stop drawing'. 
		// The edges have already been rasterized, so we actually need to keep track of whether the edge
		// was upwards or downards. If our polygons are drawn clockwise, all edges going up will turn drawing 'on',
		// and all edges going down will turn drawing 'off'. 

		for y in area.lo.y..<area.hi.y {
			drawing := false
			for x in area.lo.x..<area.hi.x {
				chunk, ground_pos, _ := get_chunk_and_relative_pos(state, {x, y})
				g := ground_at(chunk, ground_pos);

				switch g.edge_dir {
				case .NotSet:
				case .Up:
					drawing = true
				case .Down:
					drawing = false
				}
				// Don't interfere with subsequent draws
				g.edge_dir = .NotSet

				if drawing {
					write_to_ground(g, ground)
				}
			}
		}
	}

	get_chunk_pos :: proc(ground_pos: Vector2i) -> Vector2 {
		return {
			f32(ground_pos.x * CHUNK_GROUND_SIZE),
			f32(ground_pos.y * CHUNK_GROUND_SIZE),
		}
	}

	log_chunks :: proc(state: ^GameState) {
		debug_log_intentional("all chunks ---")
		for coord, chunk in state.chunks {
			debug_log_intentional("%v -> %v", coord, len(chunk.decorations))
		}
	}


	half_grid   := Vector2{CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE} / 2 // Not a compile time contant? wtf.
	origin :: Vector2i{0, 0}

	area_1_domain := world_area({-1000, -100},  {100, 100})

	// This is the default player spawn position.
	player_spawn_pos := ground_pos_to_world_pos({0, 0}) + half_grid

	// Island 1
	{
		island_1_area : WorldArea

		sand  := GroundDetails{ type = .Ground, tint = COL_SAND,        z = -10 }
		grass := GroundDetails{ type = .Ground, tint = COL_GRASS_GREEN, z = -9 }

		// Sand
		{
			points := ISLAND_POINTS
			fill_polygon_outline(state, points, sand)
			area := get_points_area(points)
			fill_existing_polygon_outline(state, area, sand)
		}

		// Grass
		{
			points := SHORELINE_END_POINTS
			fill_polygon_outline(state, points, grass)
			area := get_points_area(points)
			fill_existing_polygon_outline(state, area, grass)
		}

		dead_tree_col := Color{ 0, 0, 0, 200 }
		sea_urchin_color := Color{ 0, 0, 0, 255 }

		add_decorations(state, []DecorationPlacement{
			// Woods area (lower left)
			{ .DeadTree1, 2200, { -1241.92139, 890.7179 }, dead_tree_col },
			{ .DeadTree1, 1600, { -1764.4967, 143.14497 }, dead_tree_col },
			{ .DeadTree1, 1300, { -915.31189, -368.5433 }, dead_tree_col },
			{ .DeadTree1, 1100, { -1529.82178, -787.0874 }, dead_tree_col },
			{ .DeadTree1, 2000, { -2816.9053, -895.95728 }, dead_tree_col },
			{ .DeadTree1, 1200, { -2483.0376, 758.86438 }, dead_tree_col },
			{ .DeadTree1, 900,  { -2957.8569, -150.04834 }, dead_tree_col },
			{ .DeadTree1, 2100, { -4000.604, -498.8418 }, dead_tree_col },
			{ .DeadTree1, 1500, { -3266.6846, 1099.7949 }, dead_tree_col },
			{ .DeadTree1, 1300, { -2215.9453, 1539.06689 }, dead_tree_col },
			{ .DeadTree1, 1800, { -3048.8008, 2336.9282 }, dead_tree_col },
			{ .DeadTree1, 1200, { -4007.6343, 1861.01099 }, dead_tree_col },
			{ .DeadTree1, 1000, { -4133.6123, 1231.12036 }, dead_tree_col },
			{ .DeadTree1, 2200, { -5330.4043, 1483.0767 }, dead_tree_col },
			{ .DeadTree1, 1300, { -5134.4385, -196.63162 }, dead_tree_col },
			{ .DeadTree1, 1700, { -5015.459, -1358.4298 }, dead_tree_col },
			{ .DeadTree1, 1400, { -3979.6392, -1554.3958 }, dead_tree_col },
			{ .DeadTree1, 2700, { -6198.2539, -1099.4749 }, dead_tree_col },
			{ .DeadTree1, 1700, { -6562.1904, 1168.1313 }, dead_tree_col },
			{ .DeadTree1, 2200, { -5988.29, 2609.8809 }, dead_tree_col },
			{ .DeadTree1, 1400, { -4679.5176, 2511.8979 }, dead_tree_col },
			{ .DeadTree1, 3300, { -7647.002, -2548.2231 }, dead_tree_col },
			{ .DeadTree1, 2100, { -5848.3145, -2758.1865 }, dead_tree_col },
			{ .DeadTree1, 3000, { -7658.7676, 2233.3926 }, dead_tree_col },
			{ .DeadTree1, 1600, { -7670.5889, 742.28406 }, dead_tree_col },
			{ .DeadTree1, 2100, { -9482.5107, 1274.45679 }, dead_tree_col },
			{ .DeadTree1, 1898, { -9805.615, -208.02432 }, dead_tree_col },
			{ .DeadTree1, 2792, { -11220.416, 648.30615 }, dead_tree_col },
			{ .DeadTree1, 1692, { -10789.828, -438.4153 }, dead_tree_col },
			{ .DeadTree1, 1087, { -11251.1729, -1166.3136 }, dead_tree_col },
			{ .DeadTree1, 1087, { -11733.021, -1873.70776 }, dead_tree_col },
			{ .DeadTree1, 1087, { -10266.9727, -1135.55737 }, dead_tree_col },
			{ .DeadTree1, 1087, { -10953.862, -1822.44739 }, dead_tree_col },
			{ .DeadTree1, 1087, { -10225.9639, -1719.92639 }, dead_tree_col },
			{ .DeadTree1, 2187, { -8319.075, -4170.1758 }, dead_tree_col },
			{ .DeadTree1, 885, { -9615.078, -4535.5488 }, dead_tree_col },
			{ .DeadTree1, 885, { -10122.5928, -5028.9658 }, dead_tree_col },
			{ .DeadTree1, 885, { -10249.4717, -5569.375 }, dead_tree_col },
			{ .DeadTree1, 885, { -9591.582, -5893.6206 }, dead_tree_col },
			{ .DeadTree1, 1385, { -9403.613, -5235.7314 }, dead_tree_col },
			{ .DeadTree1, 1185, { -8618.8457, -5188.7393 }, dead_tree_col },
			{ .DeadTree1, 1684, { -8257.042, -6404.1768 }, dead_tree_col },
			{ .DeadTree1, 2484, { -7047.6045, -5082.0879 }, dead_tree_col },
			{ .DeadTree1, 1984, { -6152.787, -4065.7517 }, dead_tree_col },
			{ .DeadTree1, 2484, { -5390.5347, -5512.9258 }, dead_tree_col },
			{ .DeadTree1, 2584, { -2816.5532, -4905.3335 }, dead_tree_col },
			{ .DeadTree1, 2184, { -4075.0588, -2972.2598 }, dead_tree_col },
			{ .DeadTree1, 1784, { -4240.7656, -4275.8208 }, dead_tree_col },
			{ .DeadTree1, 1584, { -6825.7939, -6684.0957 }, dead_tree_col },
			{ .DeadTree1, 1584, { -1998.1982, -2673.987 }, dead_tree_col },
			{ .DeadTree1, 2384, { -2881.539, -2210.1768 }, dead_tree_col },
			{ .DeadTree1, 1784, { -2255.383, -3603.3735 }, dead_tree_col },
			{ .DeadTree1, 2484, { -3773.811, -6671.5376 }, dead_tree_col },
			{ .DeadTree1, 1884, { -1050.033, -1959.7144 }, dead_tree_col },
			{ .DeadTree1, 1684, { -4086.8892, -8143.0044 }, dead_tree_col },
			{ .DeadTree1, 1584, { -5276.5854, -8643.9287 }, dead_tree_col },
			{ .DeadTree1, 1584, { -3852.0806, -9160.5078 }, dead_tree_col },
			{ .DeadTree1, 2584, { -1973.613, -7141.1548 }, dead_tree_col },
			{ .DeadTree1, 1984, { -987.41736, -4448.684 }, dead_tree_col },
			{ .DeadTree1, 1484, { 233.58669, -1177.0195 }, dead_tree_col },
			{ .DeadTree1, 2984, { -987.41736, 2720.8013 }, dead_tree_col },
			{ .DeadTree1, 2484, { -4446.9287, 3753.9585 }, dead_tree_col },
			{ .DeadTree1, 2884, { -2678.9238, 4735.415 }, dead_tree_col },
			{ .DeadTree1, 1984, { -5959.6846, 4030.6587 }, dead_tree_col },
			{ .DeadTree1, 1484, { -4209.9453, 5124.2456 }, dead_tree_col },
			{ .DeadTree1, 2484, { -7782.3296, 4565.3013 }, dead_tree_col },
			{ .DeadTree1, 1584, { -9094.6348, 2548.2407 }, dead_tree_col },
			{ .DeadTree1, 2695, { 674.74304, 1576.16357 }, dead_tree_col },
			{ .DeadTree1, 2795, { -1172.2039, -8849.365 }, dead_tree_col },
			{ .DeadTree1, 1890, { 796.25269, -9068.083 }, dead_tree_col },
			{ .DeadTree1, 1690, { 237.3082, -7075.3247 }, dead_tree_col },
			{ .DeadTree1, 1990, { 2302.9727, -7318.3438 }, dead_tree_col },
			{ .DeadTree1, 1490, { 2254.3687, -5568.6045 }, dead_tree_col },
			{ .DeadTree1, 2490, { 5996.866, -7780.0806 }, dead_tree_col },
			{ .DeadTree1, 2090, { 5121.9966, -5520.001 }, dead_tree_col },
			{ .DeadTree1, 1790, { 3080.6343, -3381.4307 }, dead_tree_col },
			{ .DeadTree1, 1390, { 966.3662, -3673.054 }, dead_tree_col },
			{ .DeadTree1, 1890, { 3736.7866, -3.4621582 }, dead_tree_col },
			{ .DeadTree1, 1490, { 2059.9531, 4200.7725 }, dead_tree_col },
			{ .DeadTree1, 1490, { 9156.117, -4256.3003 }, dead_tree_col },
			{ .DeadTree1, 1690, { 7139.057, -2093.4282 }, dead_tree_col },
			{ .DeadTree1, 2290, { 5486.5259, 3180.0913 }, dead_tree_col },
			{ .DeadTree1, 1490, { 4830.3735, -2336.4478 }, dead_tree_col },

			// Beach area (top right)
			{ .SeaUrchin, 0, { 6265.0015, 220.00003 }, sea_urchin_color },
			{ .SeaUrchin, 80, { 2168.8293, 19192.191 }, sea_urchin_color },
			{ .SeaUrchin, 75, { 2090.8293, 19136.191 }, sea_urchin_color },
			{ .SeaUrchin, 75, { 2092.8293, 19044.191 }, sea_urchin_color },
			{ .SeaUrchin, 75, { 2034.8292, 18945.191 }, sea_urchin_color },
			{ .SeaUrchin, 89, { 3197.5413, 19155.516 }, sea_urchin_color },
			{ .SeaUrchin, 103, { 3267.5413, 19146.516 }, sea_urchin_color },
			{ .SeaUrchin, 77, { 3232.5413, 19082.516 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 5219.428, 18865 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 8273.242, 18107.725 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 7132.916, 18291.307 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 5671.3218, 18033.586 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 7086.702, 17331.666 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 4587.7393, 16956.635 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 2697.1, 17667.457 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 4389.8818, 17535.553 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 2667.7876, 15725.521 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 2257.4163, 17183.805 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 3554.4829, 16560.92 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 454.71338, 16553.592 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 982.33374, 14882.7949 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 1033.6301, 14318.534 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 1920.3254, 16722.139 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 938.36523, 15542.32 }, sea_urchin_color },
			{ .SeaUrchin, 71, { -431.98193, 15461.7109 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 2440.6177, 14816.8418 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 879.23956, 18152.027 }, sea_urchin_color },
			{ .SeaUrchin, 71, { 3906.6523, 18932.459 }, sea_urchin_color },
		})
	}

	// Player
	{
		g1_size := f32(0) // enemies
		g2_size := f32(0) // decorations, larger items

		player := &state.player; {
			player.size = 100
			player.health = INITIAL_PLAYER_HEALTH;
			player.sprite = state.assets.sprite1
			player_hitbox_side := f32(13.0 / f32(player.sprite.sprite_size)) * player.size
			player.hitbox_size = Vector2{player_hitbox_side, player_hitbox_side}
			player.pos = player_spawn_pos

			g1_size = math.ceil(max(g1_size, player_hitbox_side + 1))
		}

		// TODO: revert
		player.viewing_map = true
		player.map_pos = player_spawn_pos 
		player.map_zoom = 0.1
	}
}
