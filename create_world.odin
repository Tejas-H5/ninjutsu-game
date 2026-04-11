package game

import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"

ISLAND_POINTS :: []Vector2i {
	Vector2i{-32, 24},
	Vector2i{-9, 31},
	Vector2i{-2, 39},
	Vector2i{-4, 60},
	Vector2i{0, 69},
	Vector2i{8, 76},
	Vector2i{16, 78},
	Vector2i{29, 78},
	Vector2i{39, 74},
	Vector2i{55, 75},
	Vector2i{72, 77},
	Vector2i{83, 89},
	Vector2i{95, 95},
	Vector2i{111, 98},
	Vector2i{123, 95},
	Vector2i{134, 87},
	Vector2i{151, 68},
	Vector2i{156, 40},
	Vector2i{159, 0},
	Vector2i{154, -31},
	Vector2i{141, -40},
	Vector2i{106, -47},
	Vector2i{45, -43},
	Vector2i{1, -48},
	Vector2i{-26, -47},
	Vector2i{-42, -40},
	Vector2i{-55, -30},
	Vector2i{-59, -13},
	Vector2i{-57, 6},
	Vector2i{-49, 19},
	Vector2i{-36, 24},
	Vector2i{-32, 24},
}

SHORELINE_END_POINTS :: []Vector2i {
	Vector2i{-10, 20},
	Vector2i{14, 24},
	Vector2i{20, 35},
	Vector2i{17, 45},
	Vector2i{18, 53},
	Vector2i{22, 58},
	Vector2i{28, 62},
	Vector2i{36, 63},
	Vector2i{67, 65},
	Vector2i{100, 82},
	Vector2i{118, 86},
	Vector2i{137, 73},
	Vector2i{146, 40},
	Vector2i{147, 24},
	Vector2i{146, 2},
	Vector2i{138, -23},
	Vector2i{120, -34},
	Vector2i{97, -38},
	Vector2i{82, -38},
	Vector2i{65, -39},
	Vector2i{54, -38},
	Vector2i{41, -37},
	Vector2i{33, -38},
	Vector2i{15, -40},
	Vector2i{-8, -39},
	Vector2i{-26, -36},
	Vector2i{-38, -29},
	Vector2i{-44, -24},
	Vector2i{-48, -14},
	Vector2i{-46, 2},
	Vector2i{-37, 13},
	Vector2i{-16, 19},
	Vector2i{-10, 20},
}

create_world :: proc(state: ^GameState) {
	// Mainly to control infinite loops. Aint no way we can design an open world this big
	WORLD_EXTENT :: WorldArea {
		lo = {-2000, -2000},
		hi = {2000, 2000},
	}

	WorldArea :: struct {
		lo, hi: Vector2i,
	}

	world_area :: proc(from: Vector2i, to: Vector2i) -> WorldArea {
		lo := linalg.min(from, to)
		hi := linalg.max(from, to)
		return {lo, hi}
	}

	world_area_width :: proc(area: WorldArea) -> int {
		return area.hi.x - area.lo.x
	}

	world_area_height :: proc(area: WorldArea) -> int {
		return area.hi.y - area.lo.y
	}

	extend_area :: proc(area: WorldArea, lo, hi: Vector2i) -> WorldArea {
		return {area.lo + lo, area.hi + hi}
	}

	absorb_point_into_area :: proc(area: WorldArea, pos: Vector2i) -> WorldArea {
		return {linalg.min(area.lo, pos), linalg.max(area.hi, pos)}
	}

	get_points_area :: proc(points: []Vector2i) -> WorldArea {
		result := world_area(points[0], points[0])
		for i in 1 ..< len(points) {
			point := points[i]
			result = absorb_point_into_area(result, point)
		}
		return result
	}

	get_chunk :: proc(state: ^GameState, coord: Vector2i) -> ^Chunk {
		_, v, _, _ := map_entry(&state.chunks, coord)
		return v
	}

	get_chunk_and_relative_pos :: proc(state: ^GameState, pos: Vector2) -> (^Chunk, Vector2) {
		coord := pos_to_chunk_coord(pos)
		chunk := get_chunk(state, coord)
		relative_pos := pos - chunk_coord_to_pos(coord)
		return chunk, relative_pos
	}

	get_chunk_and_relative_ground_pos :: proc(state: ^GameState, pos: Vector2i) -> (^Chunk, Vector2i) {
		coord := ground_pos_to_chunk_coord(pos)
		chunk := get_chunk(state, coord)

		coord_ground_pos := coord * CHUNK_GROUND_ROW_COUNT
		relative_ground_pos := pos - coord_ground_pos

		assert(relative_ground_pos.x < CHUNK_GROUND_ROW_COUNT)
		assert(relative_ground_pos.y < CHUNK_GROUND_ROW_COUNT)
		assert(relative_ground_pos.x >= 0)
		assert(relative_ground_pos.y >= 0)

		return chunk, relative_ground_pos
	}

	DecorationPlacement :: struct {
		type: DecorationType,
		size: f32,
		pos:  Vector2,
	}

	add_decorations :: proc(state: ^GameState, placements: []DecorationPlacement) {
		for &p in placements {
			add_decoration_placement(state, p)
		}
	}

	add_load_event :: proc(state: ^GameState, pos: Vector2, load: LoadEventFn) {
		chunk, relative_pos := get_chunk_and_relative_pos(state, pos)
		append(&chunk.loadevents, LoadEvent{
			pos = pos,
			load = load,
		})
	}

	add_decoration_placement :: proc(state: ^GameState, placement: DecorationPlacement) -> ^Decoration {
		return add_decoration(state, placement.type, placement.size, placement.pos)
	}

	add_decoration :: proc(
		state: ^GameState,
		type: DecorationType,
		size: f32,
		pos: Vector2,
	) -> ^Decoration {
		chunk, relative_pos := get_chunk_and_relative_pos(state, pos)

		hitbox_size_sprite := DECORATION_TYPES[type].hitbox_size
		hitbox_side_len :=
			f32(hitbox_size_sprite / f32(state.assets.decorations.sprite_size)) * size
		hitbox_size := Vector2{hitbox_side_len, hitbox_side_len}

		idx := len(chunk.decorations)
		append(
			&chunk.decorations,
			Decoration{pos = relative_pos, size = size, type = type, hitbox_size = hitbox_size},
		)

		return &chunk.decorations[idx]
	}

	write_to_ground :: proc(existing: ^GroundDetails, new_ground: GroundDetails) {
		if existing.type == .None || new_ground.z > existing.z {
			existing^ = new_ground
		}
	}

	// Won't overwrite ground on the same or lower z-index
	fill_ground :: proc(state: ^GameState, area: WorldArea, details: GroundDetails) {
		for x in area.lo.x ..< area.hi.x {
			for y in area.lo.y ..< area.hi.y {
				chunk, ground_pos := get_chunk_and_relative_ground_pos(state, {x, y})
				g := ground_at(chunk, ground_pos)
				write_to_ground(g, details)
			}
		}
	}

	fill_horizontal_line :: proc(
		state: ^GameState,
		from, to, y: int,
		inner_width: int,
		inner: GroundDetails,
		outer_width: int,
		outer: GroundDetails,
	) {
		fill_ground(state, world_area({from, y - inner_width}, {to, y + inner_width + 1}), inner)
		fill_ground(
			state,
			world_area({from, y - inner_width - outer_width}, {to, y - inner_width}),
			outer,
		)
		fill_ground(
			state,
			world_area({from, y + inner_width + 1}, {to, y + inner_width + 1 + outer_width}),
			outer,
		)
	}

	fill_vertical_line :: proc(
		state: ^GameState,
		from, to, x: int,
		inner_width: int,
		inner: GroundDetails,
		outer_width: int,
		outer: GroundDetails,
	) {
		fill_ground(state, world_area({x - inner_width, from}, {x + inner_width + 1, to}), inner)
		fill_ground(
			state,
			world_area({x - inner_width - outer_width, from}, {x - inner_width, to}),
			outer,
		)
		fill_ground(
			state,
			world_area({x + inner_width + 1, from}, {x + inner_width + 1 + outer_width, to}),
			outer,
		)
	}

	fill_line :: proc(state: ^GameState, from_i, to_i: Vector2i, ground: GroundDetails) {
		// 0.5 offset moves lines into the center of the pixels, and fixes artifacts when
		// the path is going like
		//    __-x-__
		// x--       --x
		from := Vector2{f32(from_i.x), f32(from_i.y)} + {0.5, 0.5}
		to := Vector2{f32(to_i.x), f32(to_i.y)} + {0.5, 0.5}
		pos := from
		dir := linalg.normalize0(to - from)

		if dir == 0 {return}

		ground := ground
		ground.edge_dir = linalg.dot(dir, Vector2{0, 1}) > 0 ? .Up : .Down

		done := false
		for !done {
			if linalg.dot(dir, to - pos) < 0 {
				done = true
			}

			coord := Vector2i{int(math.floor_f32(pos.x)), int(math.floor_f32(pos.y))}

			chunk, ground_pos := get_chunk_and_relative_ground_pos(state, coord)
			g := ground_at(chunk, ground_pos)
			write_to_ground(g, ground)

			pos += dir
		}
	}

	fill_polygon_outline :: proc(state: ^GameState, points: []Vector2i, ground: GroundDetails) {
		for i in 0 ..< len(points) - 1 {
			from := points[i]
			to := points[i + 1]
			fill_line(state, from, to, ground)
		}
	}

	fill_existing_polygon_outline :: proc(
		state: ^GameState,
		area: WorldArea,
		ground: GroundDetails,
	) {
		// classic scanlines algorithm. Finally get to use it, lets go.
		// It wasn't as simple as 'if found an edge, start drawing else stop drawing'.
		// The edges have already been rasterized, so we actually need to keep track of whether the edge
		// was upwards or downards. If our polygons are drawn clockwise, all edges going up will turn drawing 'on',
		// and all edges going down will turn drawing 'off'.

		for y in area.lo.y ..< area.hi.y {
			drawing := false
			for x in area.lo.x ..< area.hi.x {
				chunk, ground_pos := get_chunk_and_relative_ground_pos(state, {x, y})
				g := ground_at(chunk, ground_pos)

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
		return {f32(ground_pos.x * CHUNK_GROUND_SIZE), f32(ground_pos.y * CHUNK_GROUND_SIZE)}
	}

	log_chunks :: proc(state: ^GameState) {
		debug_log_intentional("all chunks ---")
		for coord, chunk in state.chunks {
			debug_log_intentional("%v -> %v", coord, len(chunk.decorations))
		}
	}

	half_grid := Vector2{CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE} / 2 // Not a compile time contant? wtf.
	origin :: Vector2i{0, 0}

	area_1_domain := world_area({-1000, -100}, {100, 100})

	// This is the default player spawn position.
	player_spawn_pos := Vector2{27430.477, 20926.213}

	// Island 1
	{
		island_1_area: WorldArea

		sand := GroundDetails {
			type = .Ground,
			tint = COL_SAND,
			z    = -10,
		}
		grass := GroundDetails {
			type = .Ground,
			tint = COL_GRASS_GREEN,
			z    = -9,
		}

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

		add_decorations(
			state,
			[]DecorationPlacement {
				// Woods area (lower left)
				{.DeadTree1, 2200, {-1241.92139, 890.7179}},
				{.DeadTree1, 1600, {-1764.4967, 143.14497}},
				{.DeadTree1, 1300, {-915.31189, -368.5433}},
				{.DeadTree1, 1100, {-1529.82178, -787.0874}},
				{.DeadTree1, 2000, {-2816.9053, -895.95728}},
				{.DeadTree1, 1200, {-2483.0376, 758.86438}},
				{.DeadTree1, 900, {-2957.8569, -150.04834}},
				{.DeadTree1, 2100, {-4000.604, -498.8418}},
				{.DeadTree1, 1500, {-3266.6846, 1099.7949}},
				{.DeadTree1, 1300, {-2215.9453, 1539.06689}},
				{.DeadTree1, 1800, {-3048.8008, 2336.9282}},
				{.DeadTree1, 1200, {-4007.6343, 1861.01099}},
				{.DeadTree1, 1000, {-4133.6123, 1231.12036}},
				{.DeadTree1, 2200, {-5330.4043, 1483.0767}},
				{.DeadTree1, 1300, {-5134.4385, -196.63162}},
				{.DeadTree1, 1700, {-5015.459, -1358.4298}},
				{.DeadTree1, 1400, {-3979.6392, -1554.3958}},
				{.DeadTree1, 2700, {-6198.2539, -1099.4749}},
				{.DeadTree1, 1700, {-6562.1904, 1168.1313}},
				{.DeadTree1, 2200, {-5988.29, 2609.8809}},
				{.DeadTree1, 1400, {-4679.5176, 2511.8979}},
				{.DeadTree1, 3300, {-7647.002, -2548.2231}},
				{.DeadTree1, 2100, {-5848.3145, -2758.1865}},
				{.DeadTree1, 3000, {-7658.7676, 2233.3926}},
				{.DeadTree1, 1600, {-7670.5889, 742.28406}},
				{.DeadTree1, 2100, {-9482.5107, 1274.45679}},
				{.DeadTree1, 1898, {-9805.615, -208.02432}},
				{.DeadTree1, 2792, {-11220.416, 648.30615}},
				{.DeadTree1, 1692, {-10789.828, -438.4153}},
				{.DeadTree1, 1087, {-11251.1729, -1166.3136}},
				{.DeadTree1, 1087, {-11733.021, -1873.70776}},
				{.DeadTree1, 1087, {-10266.9727, -1135.55737}},
				{.DeadTree1, 1087, {-10953.862, -1822.44739}},
				{.DeadTree1, 1087, {-10225.9639, -1719.92639}},
				{.DeadTree1, 2187, {-8319.075, -4170.1758}},
				{.DeadTree1, 885, {-9615.078, -4535.5488}},
				{.DeadTree1, 885, {-10122.5928, -5028.9658}},
				{.DeadTree1, 885, {-10249.4717, -5569.375}},
				{.DeadTree1, 885, {-9591.582, -5893.6206}},
				{.DeadTree1, 1385, {-9403.613, -5235.7314}},
				{.DeadTree1, 1185, {-8618.8457, -5188.7393}},
				{.DeadTree1, 1684, {-8257.042, -6404.1768}},
				{.DeadTree1, 2484, {-7047.6045, -5082.0879}},
				{.DeadTree1, 1984, {-6152.787, -4065.7517}},
				{.DeadTree1, 2484, {-5390.5347, -5512.9258}},
				{.DeadTree1, 2584, {-2816.5532, -4905.3335}},
				{.DeadTree1, 2184, {-4075.0588, -2972.2598}},
				{.DeadTree1, 1784, {-4240.7656, -4275.8208}},
				{.DeadTree1, 1584, {-6825.7939, -6684.0957}},
				{.DeadTree1, 1584, {-1998.1982, -2673.987}},
				{.DeadTree1, 2384, {-2881.539, -2210.1768}},
				{.DeadTree1, 1784, {-2255.383, -3603.3735}},
				{.DeadTree1, 2484, {-3773.811, -6671.5376}},
				{.DeadTree1, 1884, {-1050.033, -1959.7144}},
				{.DeadTree1, 1684, {-4086.8892, -8143.0044}},
				{.DeadTree1, 1584, {-5276.5854, -8643.9287}},
				{.DeadTree1, 1584, {-3852.0806, -9160.5078}},
				{.DeadTree1, 2584, {-1973.613, -7141.1548}},
				{.DeadTree1, 1984, {-987.41736, -4448.684}},
				{.DeadTree1, 1484, {233.58669, -1177.0195}},
				{.DeadTree1, 2984, {-987.41736, 2720.8013}},
				{.DeadTree1, 2484, {-4446.9287, 3753.9585}},
				{.DeadTree1, 2884, {-2678.9238, 4735.415}},
				{.DeadTree1, 1984, {-5959.6846, 4030.6587}},
				{.DeadTree1, 1484, {-4209.9453, 5124.2456}},
				{.DeadTree1, 2484, {-7782.3296, 4565.3013}},
				{.DeadTree1, 1584, {-9094.6348, 2548.2407}},
				{.DeadTree1, 2695, {674.74304, 1576.16357}},
				{.DeadTree1, 2795, {-1172.2039, -8849.365}},
				{.DeadTree1, 1890, {796.25269, -9068.083}},
				{.DeadTree1, 1690, {237.3082, -7075.3247}},
				{.DeadTree1, 1990, {2302.9727, -7318.3438}},
				{.DeadTree1, 1490, {2254.3687, -5568.6045}},
				{.DeadTree1, 2490, {5996.866, -7780.0806}},
				{.DeadTree1, 2090, {5121.9966, -5520.001}},
				{.DeadTree1, 1790, {3080.6343, -3381.4307}},
				{.DeadTree1, 1390, {966.3662, -3673.054}},
				{.DeadTree1, 1890, {3736.7866, -3.4621582}},
				{.DeadTree1, 1490, {2059.9531, 4200.7725}},
				{.DeadTree1, 1490, {9156.117, -4256.3003}},
				{.DeadTree1, 1690, {7139.057, -2093.4282}},
				{.DeadTree1, 2290, {5486.5259, 3180.0913}},
				{.DeadTree1, 1490, {4830.3735, -2336.4478}},
				{.LiveTree, 1000, {843.31165, -2073.5029}},
				{.LiveTree, 999, {1843.1074, -2642.1072}},
				{.LiveTree, 999, {2662.8452, -2457.3108}},
				{.LiveTree, 999, {2008.9504, -1699.17188}},
				{.LiveTree, 998, {1696.218, -865.21887}},
				{.LiveTree, 998, {279.43433, -18.431274}},
				{.LiveTree, 997, {-1881.32568, -1594.1821}},
				{.LiveTree, 996, {-1145.3464, -3056.7053}},
				{.LiveTree, 996, {-182.91174, -3462.4375}},
				{.LiveTree, 996, {71.850464, -2594.3594}},
				{.LiveTree, 996, {1185.2551, -3056.7053}},
				{.LiveTree, 1396, {2072.2048, -3849.2986}},
				{.LiveTree, 896, {411.5332, -4556.971}},
				{.LiveTree, 595, {-164.0404, -5255.208}},
				{.LiveTree, 1595, {1440.0173, -4953.2676}},
				{.LiveTree, 1495, {3279.9658, -4915.5254}},
				{.LiveTree, 1894, {2592.3398, -9152.158}},
				{.LiveTree, 1394, {3941.199, -9411.5547}},
				{.LiveTree, 1594, {3768.2683, -8270.2119}},
				{.LiveTree, 1294, {5220.8857, -9221.33}},
				{.LiveTree, 1894, {3872.0266, -6800.3013}},
				{.LiveTree, 2094, {7278.7603, -8633.366}},
				{.LiveTree, 1694, {8869.7227, -8529.607}},
				{.LiveTree, 2794, {10910.3037, -7907.0576}},
				{.LiveTree, 1794, {7814.845, -6627.3706}},
				{.LiveTree, 2694, {6759.9683, -3912.3594}},
				{.LiveTree, 2894, {6033.6597, -782.3147}},
				{.LiveTree, 2894, {9059.946, -1733.4332}},
				{.LiveTree, 1394, {8056.948, 428.19995}},
				{.LiveTree, 1294, {3560.7515, -1214.6414}},
				{.LiveTree, 1194, {2678.8052, 289.85522}},


				// Beach area (top right)
				{.SeaUrchin, 0, {6265.0015, 220.00003}},
				{.SeaUrchin, 80, {2168.8293, 19192.191}},
				{.SeaUrchin, 75, {2090.8293, 19136.191}},
				{.SeaUrchin, 75, {2092.8293, 19044.191}},
				{.SeaUrchin, 75, {2034.8292, 18945.191}},
				{.SeaUrchin, 89, {3197.5413, 19155.516}},
				{.SeaUrchin, 103, {3267.5413, 19146.516}},
				{.SeaUrchin, 77, {3232.5413, 19082.516}},
				{.SeaUrchin, 71, {5219.428, 18865}},
				{.SeaUrchin, 71, {8273.242, 18107.725}},
				{.SeaUrchin, 71, {7132.916, 18291.307}},
				{.SeaUrchin, 71, {5671.3218, 18033.586}},
				{.SeaUrchin, 71, {7086.702, 17331.666}},
				{.SeaUrchin, 71, {4587.7393, 16956.635}},
				{.SeaUrchin, 71, {2697.1, 17667.457}},
				{.SeaUrchin, 71, {4389.8818, 17535.553}},
				{.SeaUrchin, 71, {2667.7876, 15725.521}},
				{.SeaUrchin, 71, {2257.4163, 17183.805}},
				{.SeaUrchin, 71, {3554.4829, 16560.92}},
				{.SeaUrchin, 71, {454.71338, 16553.592}},
				{.SeaUrchin, 71, {982.33374, 14882.7949}},
				{.SeaUrchin, 71, {1033.6301, 14318.534}},
				{.SeaUrchin, 71, {1920.3254, 16722.139}},
				{.SeaUrchin, 71, {938.36523, 15542.32}},
				{.SeaUrchin, 71, {-431.98193, 15461.7109}},
				{.SeaUrchin, 71, {2440.6177, 14816.8418}},
				{.SeaUrchin, 71, {879.23956, 18152.027}},
				{.SeaUrchin, 71, {3906.6523, 18932.459}},
			},
		)

		// Beach area - quests
		{
			// Bob
			add_load_event(state, { 27590.4, 24648.047 }, proc(state: ^GameState, trigger: LoadEvent) {
				add_entity_at_position(state, trigger.pos, ent_id(.Bob), 
					proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {
						#partial switch event {
						case .Loaded:
							set_entity_appearance(state, entity, .Blob)
							entity.can_interact = true
							entity.move_speed   = 0
						case .PlayerInteracted:
							dialog := ""

							some_guy, ok := get_entity_by_id(state, ent_id(.SomeGuy))
							if ok {
								if some_guy.memory.state == 2 {
									dialog = "ooh, he'll remember that"
								}
							}

							if dialog == "" {
								if int(entity.memory.idx) < len(NPC_BOB_TALKING_POINTS) {entity.memory.idx += 1} 
								dialog = NPC_BOB_TALKING_POINTS[entity.memory.idx - 1][0]
								entity.memory.turn = 1
							}

							if dialog != "" {
								set_current_entity_dialog(state, dialog, entity.handle)
							}
						case .DialogComplete:
							if entity.memory.turn == 1 {
								entity.memory.turn = 0
								player := get_player(state)
								dialog := NPC_BOB_TALKING_POINTS[entity.memory.idx - 1][1]
								set_current_entity_dialog(state, dialog, player.handle)
							}
						}
					}
				)
			})

			// Some guy
			add_load_event(state, { 26509.605, 24396.953 }, proc(state: ^GameState, trigger: LoadEvent) {
				add_entity_at_position(state, trigger.pos, ent_id(.SomeGuy), 
					proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {
						player := get_player(state)

						#partial switch event {
						case .Loaded:
							set_entity_appearance(state, entity, .Stickman, color=to_floating_color({156, 0, 229, 255}))
							entity.can_interact = true
							entity.move_speed   = 0
						case .ReOrient:
							if entity.memory.state == 1 {
								orient_entity_towards_target(state, entity, 900, player.pos, player.velocity)
							} else {
								orient_entity_towards_target(state, entity, 0, 0, 0)
							}
						case .CollidedWithPlayer: fallthrough
						case .PlayerInteracted:
							if entity.memory.state == 2 {
								if event == .CollidedWithPlayer {
									set_current_entity_dialog(state, "Back off buddy. Stay away from me", entity.handle)
									entity.target_pos = entity.pos + {100, 1}
								} else {
									set_current_entity_dialog(state, "HOW", entity.handle)
								}
							} else {
								idx := entity.memory.idx
								if int(entity.memory.idx) < len(SOME_GUY_TALKING_POINTS) {
									set_current_entity_dialog(state, SOME_GUY_TALKING_POINTS[entity.memory.idx], entity.handle)
									entity.memory.idx += 1
								}
							}
						case .DialogComplete:
							if entity.memory.idx == len(SOME_GUY_TALKING_POINTS) {
								entity.move_speed        = 400
								entity.can_interact      = false
								entity.can_damage_player = true
								entity.memory            .state = 1

								set_current_entity_dialog(state, "Ahh shit", player.handle)
							}
						case .Death:
							entity.memory.state = 2
						case .UnloadedDeath:
							entity.health     = 10
							entity.move_speed = 0
							entity.can_damage_player = false
							entity.can_interact = true
							entity.memory.idx = 0
							set_current_entity_dialog(state, "HOW.", entity.handle)
						}
					}
				)
			})
		}
	}

	// Player
	{
		g1_size := f32(0) // entities
		g2_size := f32(0) // decorations, larger items

		player := state.player; {
			set_entity_appearance(
				state, 
				state.player.entity,
				.Stickman,
				color = to_floating_color({0, 0, 0, 255}),
				health = 100,
				size = 100,
			)
			player.entity.pos = player_spawn_pos
			g1_size = math.ceil(max(g1_size, player.entity.hitbox_size.x))

			player.entity.update_fn = proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {

			}
		}


		if IS_DEBUGGING_WORLD {
			player.viewing_map = true
			player.map_camera = {player_spawn_pos, 0.1}
		}
	}
}

// entity is a pain to type ngl
ent_id :: proc(unique_entity: UniqueEntity) -> EntityId {
	return EntityId(unique_entity)
}

UniqueEntity :: enum EntityId {
	Player = ENTITY_ID_PLAYER, 
	Bob,
	SomeGuy,
}

