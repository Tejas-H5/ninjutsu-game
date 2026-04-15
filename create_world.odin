package game

import "core:flags"
import "core:math"
import "core:math/linalg"
import "core:mem"
import rl "vendor:raylib"

get_chunk_relative_pos :: proc(state: ^GameState, pos: Vector2) -> ChunkRelativePos {
	coord := pos_to_chunk_coord(pos)
	relative_pos := pos - chunk_coord_to_pos(coord)
	return { chunk=coord, pos=relative_pos }
}

create_world :: proc(state: ^GameState) {
	t0 := rl.GetTime()

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

	add_decorations :: proc(state: ^GameState, placements: []DecorationPlacement) {
		for &p in placements {
			add_decoration_placement(state, p)
		}
	}

	add_decoration_placement :: proc(state: ^GameState, placement: DecorationPlacement) -> ^Decoration {
		return add_decoration(state, placement.type, placement.size, placement.pos)
	}

	add_decoration :: proc(
		state: ^GameState,
		type: DecorationType,
		size: f32,
		pos: ChunkRelativePos,
	) -> ^Decoration {
		chunk        := get_chunk(state, pos.chunk)
		relative_pos := pos.pos

		hitbox_size_sprite := DECORATION_TYPES[type].hitbox_size
		hitbox_side_len    := f32(hitbox_size_sprite / f32(state.assets.decorations.sprite_size)) * size
		hitbox_size        := Vector2{hitbox_side_len, hitbox_side_len}

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

	fill_line :: proc(state: ^GameState, from_i, to_i: Vector2i, ground: GroundDetails, set_edge_dir := false) {
		// 0.5 offset moves lines into the center of the pixels, and fixes artifacts when
		// the path is going like
		//    __-x-__
		// x--       --x
		from := Vector2{f32(from_i.x), f32(from_i.y)} + {0.5, 0.5}
		to := Vector2{f32(to_i.x), f32(to_i.y)} + {0.5, 0.5}
		pos := from
		dir := linalg.normalize0(to - from)

		if dir == 0 {return}

		edge_dir : EdgeDirection
		if set_edge_dir {
			dot_val := linalg.dot(dir, Vector2{0, 1})
			if dot_val > 0 {
				edge_dir = .Up
			} else if dot_val < 0 {
				edge_dir = .Down
			}
		}

		done := false
		for !done {
			if linalg.dot(dir, to - pos) < 0 {
				break;
			}

			coord := Vector2i{int(math.floor_f32(pos.x)), int(math.floor_f32(pos.y))}

			chunk, ground_pos := get_chunk_and_relative_ground_pos(state, coord)
			g := ground_at(chunk, ground_pos)

			write_to_ground(g, ground)
			if g.edge_dir == .NotSet {
				g.edge_dir = edge_dir
			}

			pos += dir
		}
	}

	fill_polygon_outline :: proc(state: ^GameState, points: []Vector2i, ground: GroundDetails, set_edge_dir := false) {
		for i in 0 ..< len(points) - 1 {
			from := points[i]
			to := points[i + 1]
			fill_line(state, from, to, ground, set_edge_dir)
		}
	}

	fill_polygon :: proc(
		state: ^GameState,
		ground: GroundDetails,
		points: []Vector2i, 
	) {
		fill_polygon_outline(state, points, ground, true)

		area := get_points_area(points)

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

	add_simple_npc :: proc(state: ^GameState, pos: ChunkRelativePos, type : CharacterType, color : Color, dialog: ^DialogNode) -> ^Entity {
		return add_entity_at_position(state, pos, type, color=color, dialog=dialog, 
			update_fn = proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) -> bool {
				return handle_dialog_back_and_forth(entity, state.player.entity, state, event)
			}
		)
	}

	persistent_store_arena : mem.Arena;
	persistent_store: mem.Allocator; {
		mem.arena_init(&persistent_store_arena, make([]byte, 4096))
		persistent_store = mem.arena_allocator(&persistent_store_arena)
	}

	half_grid := Vector2{CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE} / 2 // Not a compile time contant? wtf.
	origin :: Vector2i{0, 0}

	area_1_domain := world_area({-1000, -100}, {100, 100})

	// This is the default player spawn position.
	player_spawn_pos := Vector2{27430.477, 20926.213}

	sand := GroundDetails {type = .Ground, tint = COL_SAND, z = -10,}
	grass := GroundDetails {type = .Ground, tint = COL_GRASS_GREEN, z = -9,}

	COL_ORANGE := to_floating_color({255, 144, 130, 255})

	// Starting island
	{
		// land
		{
			fill_polygon(state, sand, []Vector2i {Vector2i { 79, 90 }, Vector2i { 84, 95 }, Vector2i { 91, 99 }, Vector2i { 96, 100 }, Vector2i { 103, 101 }, Vector2i { 112, 102 }, Vector2i { 121, 100 }, Vector2i { 128, 98 }, Vector2i { 139, 96 }, Vector2i { 143, 95 }, Vector2i { 152, 89 }, Vector2i { 158, 78 }, Vector2i { 158, 67 }, Vector2i { 160, 54 }, Vector2i { 159, 46 }, Vector2i { 157, 40 }, Vector2i { 152, 37 }, Vector2i { 141, 34 }, Vector2i { 125, 31 }, Vector2i { 106, 31 }, Vector2i { 90, 33 }, Vector2i { 79, 37 }, Vector2i { 75, 41 }, Vector2i { 73, 45 }, Vector2i { 73, 52 }, Vector2i { 70, 60 }, Vector2i { 67, 66 }, Vector2i { 67, 72 }, Vector2i { 71, 80 }, Vector2i { 76, 82 }, Vector2i { 79, 81 }, Vector2i { 81, 76 }, Vector2i { 85, 70 }, Vector2i { 91, 67 }, Vector2i { 96, 68 }, Vector2i { 100, 72 }, Vector2i { 102, 75 }, Vector2i { 102, 80 }, Vector2i { 100, 84 }, Vector2i { 95, 86 }, Vector2i { 90, 87 }, Vector2i { 88, 86 }, Vector2i { 83, 85 }, Vector2i { 79, 86 }, Vector2i { 78, 88 }, Vector2i { 79, 90 },})
			fill_polygon(state, grass, []Vector2i {Vector2i { 95, 37 }, Vector2i { 96, 45 }, Vector2i { 99, 56 }, Vector2i { 104, 69 }, Vector2i { 109, 80 }, Vector2i { 118, 88 }, Vector2i { 126, 94 }, Vector2i { 138, 92 }, Vector2i { 147, 87 }, Vector2i { 151, 81 }, Vector2i { 154, 72 }, Vector2i { 155, 62 }, Vector2i { 156, 52 }, Vector2i { 155, 41 }, Vector2i { 145, 37 }, Vector2i { 128, 35 }, Vector2i { 108, 35 }, Vector2i { 98, 36 }, Vector2i { 95, 37 },})
		}

		// tutorial
		{
			add_decorations(state, []DecorationPlacement{
				{ .TutorialZ, 200, ChunkRelativePos{ { 6, 5 }, { 3155.4766, 921.83789  } } },
				{ .TutorialX, 200, ChunkRelativePos{ { 6, 5 }, { 3427.9766, 1214.33789 } } },
				{ .TutorialC, 200, ChunkRelativePos{ { 6, 5 }, { 3712.9766, 940.58789  } } },
				{ .TutorialV, 200, ChunkRelativePos{ { 6, 5 }, { 3452.9766, 613.08789  } } },
			})
		}

		// charcters
		{
			// bob
			{
				color := to_floating_color({255, 171, 38, 255})
				d0 := new_dialog({text="Hellope!"}, persistent_store)
				add_simple_npc(state, ChunkRelativePos{{ 6, 6}, { 3862.3672, 1464.7363 }}, .Blob, color, d0)
			}

			// guy next to bob
			{
				d0 := new_dialog({text="Bob sure is a strage fella ain't he"}, persistent_store)
				color := to_floating_color({255, 171, 38, 255})
				add_simple_npc(state, ChunkRelativePos{{ 6, 6}, { 3646.6758, 1481.1992 }}, .Stickman, color, d0)
			}

			// congrats
			{
				color := to_floating_color({255, 171, 38, 255})
				d0 := new_dialog({text="Congrats! I was thinking you would never make it out of there."}, persistent_store)
				add_simple_npc(state, ChunkRelativePos{{ 6, 5}, { 1523.2988, 852.56055 }}, .Stickman, color, d0)
			}

			// slice challenge 1
			{
				d0 := new_dialog({text="Hey! You think you can beat my challenge?", reply="yeah ofc. Im a goat"}, persistent_store)
				d1 := new_next_dialog(d0, {text="Yeah you really shouldn't need to say that if it's true ya know", reply="stfu. Whats the challenge"}, persistent_store)
				d2 := new_next_dialog(d1, {text="All you gotta do is slice the apples in half before the timer runs out", reply="sounds easy"}, persistent_store)
				d3 := new_next_dialog(d2, {text="Alrigty. Three... two... one... go!", flags={.Event1}, duration_tail=1}, persistent_store)
				
				SliceChallengeData :: struct {
					x: f32,
				}

				data := new_clone(SliceChallengeData {
					x = 35,
				}, persistent_store)

				add_entity_at_position(
					state, ChunkRelativePos{{ 6, 5}, { 706.09766, 3286.037 }}, .Stickman, color = COL_ORANGE, dialog = d0, 
					data = data,
					update_fn = proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) -> bool {
						data := cast(^SliceChallengeData)entity.dataptr

						#partial switch(event) {
						case .SelfDialogComplete:
							if entity.last_dialog != nil {
								if .Event1 in entity.last_dialog.val.flags {
									debug_log("started slice challenge %v", data)
								}
							}
						}

						return handle_dialog_back_and_forth(entity, state.player.entity, state, event)
					}
				)
			}
		}
	}

	// The main game should be a sequence of islands separated by water boundaries. 
	// That would be epic I think.


	// Secret island
	{
		// Outline
		{
			// Sand

			fill_polygon(state, sand,  []Vector2i {Vector2i {109 , 316 }, Vector2i {109 , 304 }, Vector2i {113 , 304 }, Vector2i {113 , 300 }, Vector2i {124 , 300 }, Vector2i {124 , 288 }, Vector2i {113 , 288 }, Vector2i {113 , 284 }, Vector2i {109 , 284 }, Vector2i {109 , 273 }, Vector2i {96 , 273 }, Vector2i {96 , 284 }, Vector2i {92 , 284 }, Vector2i {92 , 288 }, Vector2i {81 , 288 }, Vector2i {81 , 300 }, Vector2i {92 , 300 }, Vector2i {92 , 304 }, Vector2i {96 , 304 }, Vector2i {96 , 316 }, Vector2i {109 , 316 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {82 , 299 }, Vector2i {92 , 299 }, Vector2i {92 , 289 }, Vector2i {82 , 289 }, Vector2i {82 , 299 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {97 , 315 }, Vector2i {108 , 315 }, Vector2i {108 , 304 }, Vector2i {97 , 304 }, Vector2i {97 , 315 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {113 , 299 }, Vector2i {123 , 299 }, Vector2i {123 , 289 }, Vector2i {113 , 289 }, Vector2i {113 , 299 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {97 , 284 }, Vector2i {108 , 284 }, Vector2i {108 , 274 }, Vector2i {97 , 274 }, Vector2i {97 , 284 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {93 , 297 }, Vector2i {99 , 297 }, Vector2i {99 , 303 }, Vector2i {106 , 303 }, Vector2i {106 , 297 }, Vector2i {112 , 297 }, Vector2i {112 , 291 }, Vector2i {106 , 291 }, Vector2i {106 , 285 }, Vector2i {99 , 285 }, Vector2i {99 , 291 }, Vector2i {93 , 291 }, Vector2i {93 , 297 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {94 , 289 }, Vector2i {97 , 289 }, Vector2i {97 , 286 }, Vector2i {94 , 286 }, Vector2i {94 , 289 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {94 , 299 }, Vector2i {94 , 302 }, Vector2i {97 , 302 }, Vector2i {97 , 299 }, Vector2i {94 , 299 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {108 , 299 }, Vector2i {108 , 302 }, Vector2i {111 , 302 }, Vector2i {111 , 299 }, Vector2i {108 , 299 },})
			fill_polygon(state, grass, []Vector2i {Vector2i {108 , 286 }, Vector2i {108 , 289 }, Vector2i {111 , 289 }, Vector2i {111 , 286 }, Vector2i {108 , 286 },})


			// Ohh, so you are approaching me !?
			{
				// TODO: implement epic boss battle
				d0    := new_dialog({text="Ohhh ... So - you're approaching me ?"}, persistent_store)
				d1    := new_next_dialog(d0, {text="No boss battle yet. Not implemented apologies"}, persistent_store)
				color := to_floating_color({156, 0, 229, 255})
				add_simple_npc(state, ChunkRelativePos{{ 6, 18}, { 1744.1309, 1711.5 }}, .Stickman, color, d0)
			}
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
			player.entity.move_speed = 900
			g1_size = math.ceil(max(g1_size, player.entity.hitbox_size.x))
		}

		if IS_DEBUGGING_WORLD {
			player.viewing_map = true
			player.map_camera = {player_spawn_pos, 0.1}
		}
	}

	elapsed := rl.GetTime() - t0
	debug_log_intentional(
		"World created! Elapsed: %v seconds, Chunks: %v,  persistent store usage: %v/%v",
		elapsed,
		len(state.chunks),
		persistent_store_arena.peak_used,
		len(persistent_store_arena.data),
	)
}

GameEvents :: enum LoadEvent {
	Bob,
}

DialogNode :: struct {
	val         : Dialog,
	next_dialog : ^DialogNode,
}

DialogFlags :: enum {
	Event1,
	Event2,
	Event3,
	Event4,
	Event5,
	Event6,
	Event7,
}

Dialog :: struct {
	text  : string,
	reply : string,
	flags : bit_set[DialogFlags],
	duration_tail : f32,
	reply_duration_tail : f32,
}

new_dialog :: proc(val: Dialog, allocator : mem.Allocator) -> ^DialogNode {
	node := new(DialogNode, allocator)
	node.val  = val
	node.next_dialog = node
	return node
}

new_next_dialog :: proc(parent: ^DialogNode, val: Dialog, allocator : mem.Allocator) -> ^DialogNode {
	child_node := new_dialog(val, allocator)

	assert(parent.next_dialog == parent)
	parent.next_dialog = child_node

	return child_node
}


// entity.last_dialog -> entity.dialog
// entity.dialog      -> entity.dialog.next_dialog
handle_dialog_back_and_forth :: proc(entity, talking_to: ^Entity, state: ^GameState, event: EntityUpdateEventType) -> bool {
	if entity.dialog != nil {
		#partial switch event {
		case .PlayerInteracted:
			set_current_entity_dialog(state, entity, talking_to, entity.dialog.val.text, entity.dialog.val.duration_tail)
			return true
		case .OtherDialogComplete:
			entity.last_dialog = entity.dialog
			entity.dialog = entity.dialog.next_dialog
			set_current_entity_dialog(state, entity, talking_to, entity.dialog.val.text, entity.dialog.val.duration_tail)
			return true;
		}
	}

	return false
}
