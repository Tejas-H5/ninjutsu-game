package game

import "core:math"
import "core:math/linalg"
import "core:mem"
import rl "vendor:raylib"

get_chunk_relative_pos :: proc(state: ^GameState, pos: Vector2) -> ChunkRelativePosition {
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

	add_load_event :: proc(state: ^GameState, pos: Vector2, data: LoadEventData, load: LoadEventFn) {
		chunk, relative_pos := get_chunk_and_relative_pos(state, pos)
		append(&chunk.loadevents, LoadEvent{
			pos = pos,
			load = load,
			data = data,
		})
	}

	add_decoration_placement :: proc(state: ^GameState, placement: DecorationPlacement) -> ^Decoration {
		return add_decoration(state, placement.type, placement.size, placement.pos)
	}

	add_decoration :: proc(
		state: ^GameState,
		type: DecorationType,
		size: f32,
		pos: ChunkRelativePosition,
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

	add_simple_npc_load_event :: proc(state: ^GameState, pos: Vector2, unique_id: UniqueEntity, color: Color, dialog: ^DialogNode) {
		add_load_event(state, pos, { dialog = dialog, color = color, id = ent_id(unique_id) }, proc(state: ^GameState, trigger: LoadEvent) {
			entity, just_added := add_entity_at_position(state, trigger.pos, trigger.data.id, 
				proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {
					#partial switch event {
					case .Loaded:
						set_entity_appearance(state, entity, .Stickman, color=entity.color)
						entity.can_interact = true
					case .PlayerInteracted:
						set_current_entity_dialog_and_advance(state, entity)
					case .DialogComplete:
						reply := entity.memory.last_dialog.val.reply
						if reply != "" {
							player := get_player(state)
							set_current_entity_dialog(state, player, reply)
						}
					}
				}
			)
			entity.memory.dialog = trigger.data.dialog
			entity.usual_color   = trigger.data.color
		})
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


	// Starting island
	{
		// land
		{
			fill_polygon(state, sand, []Vector2i {Vector2i { 79, 90 }, Vector2i { 84, 95 }, Vector2i { 91, 99 }, Vector2i { 96, 100 }, Vector2i { 103, 101 }, Vector2i { 112, 102 }, Vector2i { 121, 100 }, Vector2i { 128, 98 }, Vector2i { 139, 96 }, Vector2i { 143, 95 }, Vector2i { 152, 89 }, Vector2i { 158, 78 }, Vector2i { 158, 67 }, Vector2i { 160, 54 }, Vector2i { 159, 46 }, Vector2i { 157, 40 }, Vector2i { 152, 37 }, Vector2i { 141, 34 }, Vector2i { 125, 31 }, Vector2i { 106, 31 }, Vector2i { 90, 33 }, Vector2i { 79, 37 }, Vector2i { 75, 41 }, Vector2i { 73, 45 }, Vector2i { 73, 52 }, Vector2i { 70, 60 }, Vector2i { 67, 66 }, Vector2i { 67, 72 }, Vector2i { 71, 80 }, Vector2i { 76, 82 }, Vector2i { 79, 81 }, Vector2i { 81, 76 }, Vector2i { 85, 70 }, Vector2i { 91, 67 }, Vector2i { 96, 68 }, Vector2i { 100, 72 }, Vector2i { 102, 75 }, Vector2i { 102, 80 }, Vector2i { 100, 84 }, Vector2i { 95, 86 }, Vector2i { 90, 87 }, Vector2i { 88, 86 }, Vector2i { 83, 85 }, Vector2i { 79, 86 }, Vector2i { 78, 88 }, Vector2i { 79, 90 },})
			fill_polygon(state, grass, []Vector2i {Vector2i { 95, 37 }, Vector2i { 96, 45 }, Vector2i { 99, 56 }, Vector2i { 104, 69 }, Vector2i { 109, 80 }, Vector2i { 118, 88 }, Vector2i { 126, 94 }, Vector2i { 138, 92 }, Vector2i { 147, 87 }, Vector2i { 151, 81 }, Vector2i { 154, 72 }, Vector2i { 155, 62 }, Vector2i { 156, 52 }, Vector2i { 155, 41 }, Vector2i { 145, 37 }, Vector2i { 128, 35 }, Vector2i { 108, 35 }, Vector2i { 98, 36 }, Vector2i { 95, 37 },})
		}
	}


	// Main island
	{
		island_1_area: WorldArea

		// Grounds
		{
			fill_polygon(state, sand, []Vector2i {Vector2i{-32, 24}, Vector2i{-9, 31}, Vector2i{-2, 39}, Vector2i{-4, 60}, Vector2i{0, 69}, Vector2i{8, 76}, Vector2i{16, 78}, Vector2i{29, 78}, Vector2i{39, 74}, Vector2i{55, 75}, Vector2i{72, 77}, Vector2i{83, 89}, Vector2i{95, 95}, Vector2i{111, 98}, Vector2i{123, 95}, Vector2i{134, 87}, Vector2i{151, 68}, Vector2i{156, 40}, Vector2i{159, 0}, Vector2i{154, -31}, Vector2i{141, -40}, Vector2i{106, -47}, Vector2i{45, -43}, Vector2i{1, -48}, Vector2i{-26, -47}, Vector2i{-42, -40}, Vector2i{-55, -30}, Vector2i{-59, -13}, Vector2i{-57, 6}, Vector2i{-49, 19}, Vector2i{-36, 24}, Vector2i{-32, 24},})
			fill_polygon(state, grass, []Vector2i{Vector2i{-10, 20}, Vector2i{14, 24}, Vector2i{20, 35}, Vector2i{17, 45}, Vector2i{18, 53}, Vector2i{22, 58}, Vector2i{28, 62}, Vector2i{36, 63}, Vector2i{67, 65}, Vector2i{100, 82}, Vector2i{118, 86}, Vector2i{137, 73}, Vector2i{146, 40}, Vector2i{147, 24}, Vector2i{146, 2}, Vector2i{138, -23}, Vector2i{120, -34}, Vector2i{97, -38}, Vector2i{82, -38}, Vector2i{65, -39}, Vector2i{54, -38}, Vector2i{41, -37}, Vector2i{33, -38}, Vector2i{15, -40}, Vector2i{-8, -39}, Vector2i{-26, -36}, Vector2i{-38, -29}, Vector2i{-44, -24}, Vector2i{-48, -14}, Vector2i{-46, 2}, Vector2i{-37, 13}, Vector2i{-16, 19}, Vector2i{-10, 20},})
		}

		// Main beach area - stuff
		{
			// Bob
			{
				d0 := new_dialog({text="Hellope!", reply="HI!"}, persistent_store) // Odin mentioned!?! no wya
				d1 := new_next_dialog(d0, {text="How are you doing today?", reply="good. thanks"}, persistent_store)
				d2 := new_next_dialog(d1, {text="Nice weather we are having!", reply="indupitebly"}, persistent_store)
				d3 := new_next_dialog(d2, {text="I hope to someday be important in this world.", reply="good luck with that"}, persistent_store) // We will never hear from bob again

				add_load_event(state, { 27590.4, 24648.047 }, { dialog = d0 }, proc(state: ^GameState, trigger: LoadEvent) {
					entity, just_added := add_entity_at_position(state, trigger.pos, ent_id(.Bob), 
						proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {
							player := get_player(state)
							memory := &entity.memory

							#partial switch event {
							case .Loaded:
								set_entity_appearance(state, entity, .Blob)
								entity.can_interact = true
								entity.move_speed   = 0
							case .PlayerInteracted:
								some_guy, ok := get_entity_by_id(state, ent_id(.SomeGuy))
								if ok && some_guy.memory.state == .AttackFailed{
									set_current_entity_dialog(state, entity, "ooh, he'll remember that")
								} else {
									set_current_entity_dialog_and_advance(state, entity)
								}
							case .DialogComplete:
								if memory.last_dialog != nil {
									set_current_entity_dialog(state, player, memory.last_dialog.val.reply)
								}
							}
						}
					);
					entity.memory.dialog = trigger.data.dialog
				})
			}

			// Some guy
			{
				d0 := new_dialog({text="Whatre you lookin at?"}, persistent_store)
				d1 := new_next_dialog(d0, {text="Huh? punk."}, persistent_store)
				d2 := new_next_dialog(d1, {text="Alright, that's it. ", flags=1}, persistent_store)

				SOME_GUY_SPAWN_POS :: Vector2{ 26509.605, 24396.953 }
				add_load_event(state, SOME_GUY_SPAWN_POS, { dialog = d0 }, proc(state: ^GameState, trigger: LoadEvent) {
					entity, just_added := add_entity_at_position(state, trigger.pos, ent_id(.SomeGuy), 
						proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {
							player := get_player(state)
							memory := &entity.memory

							// useful for debug
							start_aggro := false

							#partial switch event {
							case .Loaded:
								set_entity_appearance(state, entity, .Stickman, color=to_floating_color({156, 0, 229, 255}))
								entity.can_interact = true
							case .ReOrient:
								entity.reorient_time_to_next = 0.2
								if memory.state == .Attacking {
									orient_towards_target(state, entity, 400, player.pos, player.velocity)
								} else {
									orient_towards_target(state, entity, 100, SOME_GUY_SPAWN_POS, 0)
								}
							case .CollidedWithPlayer: fallthrough
							case .PlayerInteracted:
								if memory.state == .AttackFailed {
									if event == .CollidedWithPlayer {
										set_current_entity_dialog(state, entity, "Back off buddy. Stay away from me")
										entity.target_pos = entity.pos + {100, 1}
									} else {
										set_current_entity_dialog(state, entity, "HOW")
									}
								} else {
									set_current_entity_dialog_and_advance(state, entity)
								}
							case .DialogComplete:
								if (
									memory.last_dialog != nil && 
									memory.last_dialog.val.flags == 1 &&
									memory.state != .AttackFailed 
								) {
									start_aggro = true
								}
							case .Death:
								memory.state = .AttackFailed
							case .UnloadedDeath:
								entity.health            = 10
								entity.can_damage_player = false
								entity.can_interact      = true
								set_current_entity_dialog(state, entity, "HOW.")
							}

							if start_aggro {
								entity.can_interact      = false
								entity.can_damage_player = true
								memory.state             = .Attacking

								set_current_entity_dialog(state, player, "Ahh shit")
							}
						}
					)

					entity.memory.dialog = trigger.data.dialog
				})
			}

			// Time stopper
			{
				d0 := new_dialog({text="You know I can stop time, right?", reply="sure"}, persistent_store)
				d1 := new_next_dialog(d0, {text="It's true I did it just now in fact. What do you think?", reply="about what?"}, persistent_store)
				d2 := new_next_dialog(d1, {text="That must mean it worked! nice", reply="..."}, persistent_store)

				add_simple_npc_load_event(state, { 27354.787, 22274.922 }, .TimeStopper, to_floating_color({156, 0, 229, 255}), d0)
			}


			// Ninja that can walk in water
			{
				d0 := new_dialog({text="You're not one of those ninjas that can walk on water or something are you? Surely not."}, persistent_store)
				add_simple_npc_load_event(state, Vector2{ 28888.742, 24401.602 }, .NahhYouArentOneOfThemThings, to_floating_color({156, 0, 229, 255}), d0)
			}

			// Bro thinks hes the main character
			{
				d0 := new_dialog({text="Bro thinks hes the main character ..."}, persistent_store)
				add_simple_npc_load_event(state, Vector2{ 28875.359, 22528.348 }, .BroThinks, to_floating_color({156, 0, 229, 255}), d0)
			}
		}

		// Woodlands
		{
			add_decorations(state, []DecorationPlacement{
				{ .DeadTree1, 2100, ChunkRelativePosition{{ -1 , 1 }, { 1711.1738, 2943.9685 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ -1 , 1 }, { 1241.1738, 783.96875 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ -1 , 0 }, { 2321.1738, 3263.9688 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ -1 , 1 }, { 3971.1738, 563.96875 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ 0 , 0 }, { 1121.1738, 2173.9688 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ 0 , 0 }, { 2711.1738, 3343.9688 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ 1 , 0 }, { 801.17334, 733.96875 }} },
				{ .DeadTree1, 2100, ChunkRelativePosition{{ 0 , -1 }, { 1821.1738, 3413.9688 }} },
				{ .DeadTree1, 1700, ChunkRelativePosition{{ 0 , 1 }, { 1891.1738, 1683.9685 }} },
			})
		}
	}

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
				d0 := new_dialog({text="Ohhh ... So - you're approaching me ?"}, persistent_store)
				d1 := new_next_dialog(d0, {text="No boss battle yet. Not implemented apologies"}, persistent_store)
				add_simple_npc_load_event(state, Vector2{ 25859.13, 73829.859 }, .BroThinks, to_floating_color({156, 0, 229, 255}), d0)
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

// entity is a pain to type ngl
ent_id :: proc(unique_entity: UniqueEntity) -> EntityId {
	return EntityId(unique_entity)
}

UniqueEntity :: enum EntityId {
	Player = ENTITY_ID_PLAYER, 
	Bob,
	SomeGuy,
	TimeStopper,
	NahhYouArentOneOfThemThings,
	BroThinks,
}


DialogNode :: struct {
	val  : Dialog,
	next_dialog    : ^DialogNode,
}

Dialog :: struct {
	text  : string,
	reply : string,
	flags : int,
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


