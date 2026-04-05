package game

import "core:math/linalg"
import "core:math"

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

	add_decoration :: proc(
		state: ^GameState,
		ground_pos: Vector2i, offset: Vector2,
		size: f32,
		type: DecorationType
	) -> ^Decoration {
		chunk, ground_pos, pos := get_chunk_and_relative_pos(state, ground_pos, offset)

		hitbox_side_len := f32(13.0 / f32(state.assets.decorations.sprite_size)) * size
		hitbox_size := Vector2{hitbox_side_len, hitbox_side_len}

		idx := len(chunk.decorations)
		append(&chunk.decorations, Decoration{
			pos = pos,
			size = size,
			type = type,
			hitbox_size = hitbox_size
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


	SAND_Z_INDEX :: -10

	half_grid   := Vector2{CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE} / 2 // Not a compile time contant? wtf.
	origin :: Vector2i{0, 0}

	area_1_domain := world_area({-1000, -100},  {100, 100})

	// This is the default player spawn position.
	player_spawn_pos := ground_pos_to_world_pos({0, 0}) + half_grid

	// Island 1
	{
		island_1_area : WorldArea

		sand := GroundDetails{ type = .Ground, tint = COL_SAND, z = SAND_Z_INDEX }

		// fill_polyline
		// DRAWING_OUTLINE was used here
		// island_points := []Vector2i{Vector2i{ -32, 256 }, Vector2i{ 1, 254 }, Vector2i{ 57, 258 }, Vector2i{ 93, 228 }, Vector2i{ 170, 178 }, Vector2i{ 203, 156 }, Vector2i{ 209, 104 }, Vector2i{ 211, 42 }, Vector2i{ 199, -4 }, Vector2i{ 183, -59 }, Vector2i{ 169, -126 }, Vector2i{ 147, -166 }, Vector2i{ 100, -184 }, Vector2i{ 75, -195 }, Vector2i{ 36, -214 }, Vector2i{ 15, -247 }, Vector2i{ -12, -277 }, Vector2i{ -40, -300 }, Vector2i{ -51, -316 }, Vector2i{ -100, -350 }, Vector2i{ -109, -374 }, Vector2i{ -150, -399 }, Vector2i{ -183, -407 }, Vector2i{ -230, -401 }, Vector2i{ -300, -407 }, Vector2i{ -353, -392 }, Vector2i{ -385, -342 }, Vector2i{ -388, -274 }, Vector2i{ -365, -194 }, Vector2i{ -371, -108 }, Vector2i{ -413, -67 }, Vector2i{ -468, -11 }, Vector2i{ -482, 55 }, Vector2i{ -457, 121 }, Vector2i{ -321, 207 }, Vector2i{ -219, 225 }, Vector2i{ -146, 294 }, Vector2i{ -100, 348 }, Vector2i{ -161, 413 }, Vector2i{ -113, 449 }, Vector2i{ 4, 460 }, Vector2i{ 217, 429 }, Vector2i{ 383, 336 }, Vector2i{ 414, 258 }, Vector2i{ 416, 230 }, Vector2i{ 341, 226 }, Vector2i{ 263, 279 }, Vector2i{ 236, 315 }, Vector2i{ 185, 339 }, Vector2i{ 80, 333 }, Vector2i{ 9, 318 }, Vector2i{ -57, 286 }, Vector2i{ -32, 256 },}
		// island_points := []Vector2i{Vector2i{ -5, 4 }, Vector2i{ -6, 7 }, Vector2i{ -5, 10 }, Vector2i{ -4, 12 }, Vector2i{ -1, 13 }, Vector2i{ 1, 12 }, Vector2i{ 1, 11 }, Vector2i{ 3, 6 }, Vector2i{ 7, 7 }, Vector2i{ 10, 10 }, Vector2i{ 11, 16 }, Vector2i{ 15, 17 }, Vector2i{ 22, 13 }, Vector2i{ 23, 7 }, Vector2i{ 21, 0 }, Vector2i{ 14, -3 }, Vector2i{ 1, -4 }, Vector2i{ -1, -6 }, Vector2i{ -1, -14 }, Vector2i{ -4, -19 }, Vector2i{ -13, -16 }, Vector2i{ -17, -12 }, Vector2i{ -18, -7 }, Vector2i{ -14, -5 }, Vector2i{ -11, -5 }, Vector2i{ -10, -8 }, Vector2i{ -7, -9 }, Vector2i{ -5, -6 }, Vector2i{ -6, -3 }, Vector2i{ -7, 1 }, Vector2i{ -5, 4 },}
		island_points := []Vector2i{
			Vector2i { -283, 72 },
			Vector2i { -277, 103 },
			Vector2i { -264, 135 },
			Vector2i { -238, 153 },
			Vector2i { -203, 161 },
			Vector2i { -179, 164 },
			Vector2i { -173, 160 },
			Vector2i { -169, 151 },
			Vector2i { -168, 135 },
			Vector2i { -164, 121 },
			Vector2i { -143, 109 },
			Vector2i { -134, 100 },
			Vector2i { -96, 107 },
			Vector2i { -80, 113 },
			Vector2i { -61, 134 },
			Vector2i { -52, 148 },
			Vector2i { -16, 167 },
			Vector2i { 13, 168 },
			Vector2i { 75, 165 },
			Vector2i { 104, 161 },
			Vector2i { 137, 168 },
			Vector2i { 165, 174 },
			Vector2i { 209, 168 },
			Vector2i { 232, 160 },
			Vector2i { 274, 145 },
			Vector2i { 302, 115 },
			Vector2i { 315, 73 },
			Vector2i { 317, 42 },
			Vector2i { 316, 14 },
			Vector2i { 310, 0 },
			Vector2i { 313, -27 },
			Vector2i { 320, -49 },
			Vector2i { 317, -56 },
			Vector2i { 309, -57 },
			Vector2i { 300, -51 },
			Vector2i { 295, -42 },
			Vector2i { 289, -32 },
			Vector2i { 277, -8 },
			Vector2i { 252, -3 },
			Vector2i { 229, 5 },
			Vector2i { 225, 18 },
			Vector2i { 227, 40 },
			Vector2i { 224, 52 },
			Vector2i { 222, 67 },
			Vector2i { 232, 80 },
			Vector2i { 227, 97 },
			Vector2i { 210, 112 },
			Vector2i { 190, 123 },
			Vector2i { 173, 129 },
			Vector2i { 150, 130 },
			Vector2i { 124, 133 },
			Vector2i { 109, 129 },
			Vector2i { 99, 121 },
			Vector2i { 105, 113 },
			Vector2i { 115, 114 },
			Vector2i { 131, 115 },
			Vector2i { 155, 113 },
			Vector2i { 175, 109 },
			Vector2i { 193, 97 },
			Vector2i { 203, 80 },
			Vector2i { 200, 56 },
			Vector2i { 196, 41 },
			Vector2i { 201, 16 },
			Vector2i { 222, -5 },
			Vector2i { 241, -31 },
			Vector2i { 240, -56 },
			Vector2i { 235, -79 },
			Vector2i { 239, -102 },
			Vector2i { 242, -130 },
			Vector2i { 230, -147 },
			Vector2i { 202, -157 },
			Vector2i { 178, -158 },
			Vector2i { 138, -137 },
			Vector2i { 139, -106 },
			Vector2i { 154, -74 },
			Vector2i { 176, -66 },
			Vector2i { 195, -41 },
			Vector2i { 201, -15 },
			Vector2i { 177, 7 },
			Vector2i { 142, 15 },
			Vector2i { 116, 8 },
			Vector2i { 78, -9 },
			Vector2i { 79, -38 },
			Vector2i { 61, -68 },
			Vector2i { 38, -93 },
			Vector2i { 57, -126 },
			Vector2i { 32, -142 },
			Vector2i { 6, -153 },
			Vector2i { -34, -158 },
			Vector2i { -74, -159 },
			Vector2i { -115, -155 },
			Vector2i { -170, -143 },
			Vector2i { -210, -143 },
			Vector2i { -243, -147 },
			Vector2i { -283, -156 },
			Vector2i { -315, -145 },
			Vector2i { -331, -110 },
			Vector2i { -320, -82 },
			Vector2i { -283, -54 },
			Vector2i { -259, -25 },
			Vector2i { -250, 19 },
			Vector2i { -270, 65 },
			Vector2i { -283, 72 },
		}

		fill_polygon_outline(state, island_points, sand)

		island_1_area = get_points_area(island_points)
		fill_existing_polygon_outline(state, island_1_area, sand)
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
