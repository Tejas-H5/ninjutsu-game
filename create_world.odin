package game

import "core:math/linalg"
import "core:math"

ISLAND_POINTS :: []Vector2i{
	Vector2i { -34, 32 },
	Vector2i { 40, 27 },
	Vector2i { 40, 13 },
	Vector2i { 42, -25 },
	Vector2i { -37, -27 },
	Vector2i { -35, 29 },
	Vector2i { -34, 32 },
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

		island_points := ISLAND_POINTS

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
