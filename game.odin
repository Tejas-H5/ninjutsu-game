package game

import "core:math/rand"
import "core:c"
import hm "core:container/handle_map"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"

import rl "vendor:raylib"

// Player
PLAYER_CAMERA_ZOOM :: 0.8 // how close is the camera? Zoom out further - the player is more OP, but aiming is a lot harder.
SLASH_SPEED :: 2000 // The base movemvent speed to use while slashing. Gets multiplied by the slash multipler. xd
SLASH_MULTIPLIER :: 200 // timescaled speed increase while slashing
SLASH_LIMIT :: 0.20 // Time we are allowed to spend slashing
TIME_SLOWDOWN :: 30 // How much do we slow down time while the player is slashing?
KNOCKBACK_MAGNITUDE :: 10000 // Force with which entities knock a player back
INITIAL_PLAYER_HEALTH :: 100 // -
PLAYER_TO_ENEMY_DAMAGE :: 100 // The damage a player does to entities
WALK_SPEED :: 900 // Speed to use while walking
CAMERA_MOVE_SPEED :: 50 // The speed at which the camera moves to the player. Has a large effect on gameplay
MAP_MIN_ZOOM :: 0.01

DEV_TOOLS_ENABLED :: false
when DEV_TOOLS_ENABLED {
	global_devtools: Devtools
}

// Entities
MAX_ENTITIES :: 3000 // The maximum number of entities we can ever spawn. Any more, and the game starts lagging like hell.
ENEMY_STUCK_COOLDOWN :: 0.3 // When an entity has nowhere to go, it stays 'stuck' for this long, instead of jittering at 60fps

// Decorations
MAX_DECORATIONS :: 1000

// Animations
PLAYER_WALKING_SEQUENCE := [?]int{0, 1, 2, 1, 0, 3, 4, 3}
PLAYER_DEATH_SEQUENCE := [?]int{5, 6, 7}
SLASHING_SEQUENCE := [?]int{2} // TODO: dedicated sprite
MAX_DEATH_DURATION :: 3

// Debug flags
IS_DEBUGGING_GAME              :: true
DEBUG_LINES                    :: IS_DEBUGGING_GAME && true // Set to true to see hitboxes and such
IS_DEBUGGING_LOADING_UNLOADING :: IS_DEBUGGING_GAME && false
IS_DEBUGGING_WORLD             :: IS_DEBUGGING_GAME && false

INITIAL_ENTITIES :: 1
INITIAL_DECORATIONS :: 1

get_direction_input :: proc() -> Vector2 {
	x: f32 = 0
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
		x = -1
	} else if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
		x = +1
	}

	y: f32 = 0
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		y = -1
	} else if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
		y = +1
	}

	return linalg.normalize0(Vector2{x, y})
}

estimate_decent_intercept_point :: proc(
	current_pos: Vector2,
	capable_speed: f32,
	target_pos, target_vel: Vector2,
	dt: f32,
) -> Vector2 {
	// Don't overthink it. for now
	return target_pos + 4 * target_vel * dt
}

get_dt :: proc(state: ^GameState, phase: RenderPhase) -> (dt: f32) {
	if phase == .Update {
		dt = state.physics_dt
	}
	return
}

RenderPhase :: enum {
	Render,
	Update,
}

render_start_screen :: proc(state: ^GameState, phase: RenderPhase) {
	size: UiLength = 100

	if phase == .Render {
		center := state.window_size / 2

		start_text := ui_text(fmt.ctprintf("Start"), size)
		width := start_text.width + size
		color := COL_UI_SELECTED

		x := c.int(center.x) - width / 2
		y := c.int(center.y) - start_text.height / 2

		render_selector(x, y, size, color)
		x += size

		rl.DrawText(start_text.text, x, y, size, to_int_color(color))

		if state.input.submit || state.input.button1 {
			state.view = .Game
		}
	}
}

logged := false

// Allows rendering and updating code to share computations without having
// to constantly extract functions, and having two sources of truth
render_game :: proc(state: ^GameState, phase: RenderPhase) {
	// Decision: We just dont want to multiply by the 'framerate' ever. All animations will occur with a fixed timestep

	player := &state.player
	player_is_alive := state.player.entity.health > 0

	player_was_slashing := player.entity.action == .Slashing

	state.dt          = f32(0)
	state.unscaled_dt = f32(0)
	if phase == .Update {
		state.unscaled_dt = f32(state.physics_dt)
		state.dt          = f32(state.physics_dt)
		if player_was_slashing || player.viewing_map {
			state.dt = state.physics_dt / TIME_SLOWDOWN
		}
	}

	bottom_left := to_game_pos(state, {0, state.window_size.y})
	top_right := to_game_pos(state, {state.window_size.x, 0})

	player_camera := get_player_camera(player)
	player_camera_size := screen_to_camera_size(player_camera, state.window_size)
	player_view_box := hitbox_from_pos_size(player.entity.pos, player_camera_size)
	chunks_to_load_box := grow_hitbox(player_view_box, 0.25)
	// prevent moving left/right by 2 pixels from loading/unloading chunks.
	chunks_to_unload_box := grow_hitbox(chunks_to_load_box, 0.25)
	entities_to_unload_box := hitbox_from_pos_size(
		player.entity.pos,
		{CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH} * 2,
	)

	// Load and unload proximity triggers
	if phase == .Update {
		// by unloading stuff before loading stuff always, we maximize the room that the load methods have.

		// unload loaded chunks
		for i := 0; i < len(state.chunks_loaded); i += 1 {
			loaded_chunk := state.chunks_loaded[i]

			chunk_size := Vector2{CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH}
			chunk_pos := chunk_coord_to_pos(loaded_chunk.coord) + chunk_size / 2
			chunk_hitbox := hitbox_from_pos_size(chunk_pos, {CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH})

			if !collide_box_with_box(chunk_hitbox, chunks_to_unload_box) {
				loaded_chunk.chunk.loaded = false
				unordered_remove(&state.chunks_loaded, i)
				i -= 1

				// Loaded entities unload differently
			}
		}

		// unload entities no longer in the region.
		for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
			if entity.id == ENTITY_ID_PLAYER {
				// never unload the player though
				continue
			}

			entity_hitbox := hitbox_from_pos_size(entity.pos, entity.hitbox_size)
			if !collide_box_with_box(entity_hitbox, entities_to_unload_box) {
				debug_log("unloaded %v", entity.id)
				hm.remove(&state.entities, handle)
			}
		}

		// load unloaded chunks

		load_from := Vector2{chunks_to_load_box.left, chunks_to_load_box.bottom}
		load_to := Vector2{chunks_to_load_box.right, chunks_to_load_box.top}
		for it := get_chunk_iter_excluding_surroundings(
			state,
			load_from,
			load_to,
		); chunk, coord in iter_chunks(&it) {
			if !chunk.loaded {
				chunk.loaded = true
				append(&state.chunks_loaded, ChunkCoordPair{chunk, coord})

				for &trigger in chunk.loadevents {
					trigger.load(state, trigger)
				}
			}
		}
	}

	if phase == .Render {
		it := get_chunk_iter(state, bottom_left, top_right)
		for chunk, coord in iter_chunks(&it) {
			chunk_pos := chunk_coord_to_pos(coord)

			for x in 0 ..< CHUNK_GROUND_ROW_COUNT {
				for y in 0 ..< CHUNK_GROUND_ROW_COUNT {
					ground := ground_at(chunk, {x, y})
					if ground.type == .None {continue}

					pos :=
						chunk_pos +
						CHUNK_GROUND_HALF_OFFSET +
						Vector2{f32(x * CHUNK_GROUND_SIZE), f32(y * CHUNK_GROUND_SIZE)}

					draw_rect_textured_spritesheet(
						state,
						pos,
						size = {CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE},
						col = ground.tint,
						spritesheet = state.assets.environment,
						sprite_coordinate = ENVIRONMENT_TYPES[ground.type],
					)
				}
			}
		}
	}

	// Debug loaded chunks
	if IS_DEBUGGING_LOADING_UNLOADING && phase == .Render {
		for loaded_chunk in state.chunks_loaded {
			chunk_size := Vector2{CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH}
			chunk_pos := chunk_coord_to_pos(loaded_chunk.coord) + chunk_size / 2
			chunk_hitbox := hitbox_from_pos_size(chunk_pos, {CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH})
			draw_debug_hitbox(state, chunk_hitbox)
		}

		draw_debug_hitbox(state, player_view_box, to_floating_color({0, 0, 255, 100}))
		draw_debug_hitbox(state, chunks_to_load_box, to_floating_color({0, 255, 0, 100}))
		draw_debug_hitbox(state, chunks_to_unload_box, to_floating_color({255, 0, 0, 100}))
		draw_debug_hitbox(state, entities_to_unload_box, to_floating_color({0, 255, 255, 100}))
	}

	// Most input processing has to happen every _frame_ in the render phase instead of every physics update.
	if phase == .Render {
		// Populate solely from input devices
		{
			state.input.button1 = rl.IsKeyDown(.Z)
			state.input.button1_press = rl.IsKeyPressed(.Z)
			state.input.button2 = rl.IsKeyDown(.X)
			state.input.button2_press = rl.IsKeyPressed(.X)
			state.input.button3 = rl.IsKeyPressed(.C)
			state.input.mapbutton = rl.IsKeyPressed(.V)
			state.input.cancel = rl.IsKeyPressed(.ESCAPE)
			state.input.submit = rl.IsKeyPressed(.ENTER)
			state.input.shift = rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			state.input.direction = get_direction_input()
			state.input.prev_screen_position = state.input.screen_position
			state.input.screen_position = rl.GetMousePosition()
			state.input.click = rl.IsMouseButtonPressed(.LEFT)
			state.input.click_hold = rl.IsMouseButtonDown(.LEFT)
			state.input.rclick = rl.IsMouseButtonPressed(.RIGHT)
		}

		// handle input
		if state.view == .Game {
			if player_is_alive {
				slash_input, walk_input := state.input.button1, state.input.button2
				walk_input_pressed := state.input.button2_press

				if state.input.cancel {
					if player.viewing_map {
						player.viewing_map = false
					} else {
						state.requested_quit = true
					}
				}

				if state.input.mapbutton {
					player.viewing_map = !player.viewing_map
					if player.viewing_map {
						player.map_camera = {player.entity.pos, 0.1}
					}
				}

				if !slash_input {
					player.block_slash = false
				}

				if player.viewing_map {
					if state.input.button1 && !player.block_slash {
						player.block_slash = true
						player.map_camera.pos = to_game_pos(state, state.input.screen_position)
					} else if state.input.button2 {
						player.map_camera_target.pos = to_game_pos(
							state,
							state.input.screen_position,
						)
					} else {
						player.map_camera_target.pos = player.map_camera.pos
					}

					if state.input.direction.y > 0 {
						player.map_camera.zoom *= (1 + state.unscaled_dt * state.input.direction.y)
						if player.map_camera.zoom > 1 {
							player.map_camera.zoom = 1
						}
					} else if state.input.direction.y < 0 {
						player.map_camera.zoom /= (1 - state.unscaled_dt * state.input.direction.y)
						if player.map_camera.zoom < MAP_MIN_ZOOM {
							player.map_camera.zoom = MAP_MIN_ZOOM
						}
					}
				} else {
					if walk_input {
						// We may want to interact with something instead
						// NOTE: only works because physics system sticks around despite not being a .Update phase. Object permanence yay

						if player.interaction != nil {
							// This key has been overloaded to also do interacting
							walk_input = false

							if walk_input_pressed {
								handle := player.interaction.handle
								if enemy, ok := hm.get(&state.entities, handle); ok {
									if enemy.update_fn != nil {
										enemy->update_fn(state, .PlayerInteracted)
									}
								}
							}
						}
					}

					if state.input.button3 {
						if player.camera_lock {
							player.camera_lock = false
						} else {
							player.camera_lock = true
							player.camera_lock_pos = to_game_pos(
								state,
								state.input.screen_position,
							)
						}
					}

					if player.entity.action != .KnockedBack {
						prev_action := player.entity.action

						if walk_input {
							if player.entity.action == .Nothing {
								player.entity.action = .Walking
							}
						}

						if slash_input {
							if prev_action != .Slashing && !player.block_slash {
								// Start slashing.
								player.entity.action = .Slashing
								player.block_slash = true
								player.slash_timer = 0

								// ringbuffer
								{
									player.slash_points_idx = 0
									player.slash_points_len = 1
									player.slash_points[0] = {
										pos         = player.entity.pos,
										slash_timer = player.slash_timer,
									}
								}
							}
						}

						if !slash_input && !walk_input {
							player.entity.action = .Nothing
						}
					}
				}
			}
		}
	}

	player_damage := f32(0)
	has_submit_input := state.input.submit

	// physics setup
	// NOTE: this is probably slow af. We'll need to make it fast at some point.
	if phase == .Update && state.view == .Game {
		sparse_pyramid_reset(&state.physics)

		// Entities
		{
			it := hm.iterator_make(&state.entities)
			for entity, handle in hm.iterate(&it) {
				if entity.health <= 0 {continue}

				mask := LAYER_MASK_PLAYER
				if entity.id != ENTITY_ID_PLAYER {
					mask = LAYER_MASK_OBSTRUCTION
					if entity.can_damage_player {
						// The player needs to be able to slice through this entity, so it is no longer an obstruction
						mask = LAYER_MASK_ENEMY | LAYER_MASK_DAMAGE
					}

					// Publish interactions to physics engine
					if entity.can_interact {
						mask = mask | LAYER_MASK_INTERACTION
					}
				}

				hitbox := hitbox_from_pos_size(entity.pos, entity.hitbox_size)
				sparse_grid_add(state.entity_grid, hitbox, int(EntityType.Entity), handle, mask)
			}
		}

		// Decorations
		{
			it := get_chunk_iter(state, bottom_left, top_right)
			for chunk, coord in iter_chunks(&it) {
				for &decoration, idx in chunk.decorations {
					chunk_pos := chunk_coord_to_pos(coord)
					hitbox := hitbox_from_pos_size(
						chunk_pos + decoration.pos,
						decoration.hitbox_size,
					)

					// NOTE: Right now the index has no meaning, so it's set to -1.
					// Eventually, we may want to have a list of 'loaded decorations' and 'loaded entities', in which case
					// it does have meaning.
					sparse_grid_add(
						state.large_items_grid,
						hitbox,
						int(EntityType.Decoration),
						{},
						LAYER_MASK_OBSTRUCTION,
					)

					if should_be_transparent_when_player_is_under(decoration.type) {
						// Actual size, not hitbox size.
						hitbox := hitbox_from_pos_size(
							chunk_pos + decoration.pos,
							0.8 * decoration.size,
						)
						id := get_chunk_decoration_id(chunk, idx)
						sparse_grid_add(
							state.large_items_grid,
							hitbox,
							int(EntityType.Decoration),
							transmute(Handle)id,
							LAYER_MASK_TRANSPARENT_COVER,
						)
					}
				}
			}
		}
	}

	// player
	{
		if phase == .Update {
			player.entity.target_pos = to_game_pos(state, state.input.screen_position)

			// Query interactions available for the player
			if player_is_alive {
				pos := to_game_pos(state, state.input.screen_position)
				player.interaction = query_interactions(state, pos)
			} else {
				player.interaction = nil
			}

			if player.entity.action == .Slashing {
				// apply damage instantly.
				damage_ray := ray_from_start_end(player.entity.prev_pos, player.entity.pos)
				damage_entities(state, damage_ray)

				// push point to ringbuffer
				if player.slash_points_len < len(player.slash_points) {
					player.slash_points_idx += 1
					player.slash_points_len += 1
				} else {
					player.slash_points_idx += 1
					if player.slash_points_idx >= player.slash_points_len {
						player.slash_points_idx = 0
					}
				}
				player.slash_points[player.slash_points_idx] = {
					pos         = player.entity.pos,
					slash_timer = player.slash_timer,
				}
			} else {
				player_can_take_damage := false
				if player.entity.action == .Nothing || player.entity.action == .Walking {
					player_can_take_damage = true
				}

				// Recieve damage. It's more efficient to do it here since there is just one player, so fewer physisc queries

				if player_can_take_damage {
					hits := query_colliders_intersecting_hitbox(
						&state.physics,
						hitbox_from_pos_size(player.entity.pos, player.entity.hitbox_size),
						16,
						LAYER_MASK_DAMAGE,
						ignore_type=int(EntityType.Entity), ignore_handle = player.entity.handle,
					)

					for &hit in hits {
						#partial switch EntityType(hit.type) {
						case .Entity:
							entity, ok := hm.get(&state.entities, hit.handle)
							if !ok {continue}
							if !entity.can_damage_player {continue}

							entity_hitbox := hitbox_from_pos_size(entity.pos, entity.hitbox_size)

							if entity.hit_cooldown > 0.0001 {
								entity.hit_cooldown -= 10 * state.dt
								continue
							}

							if player.entity.action == .KnockedBack {
								// Continue knocking the plaer back. This way, the player won't get stuck in crowds
								player.entity.knockback =
									KNOCKBACK_MAGNITUDE *
									linalg.normalize0(player.entity.knockback)
								player.entity.action = .KnockedBack
							} else {
								// Damage the player
								player.entity.hit_cooldown = 1
								player.entity.knockback =
									KNOCKBACK_MAGNITUDE *
									linalg.normalize0(player.entity.pos - entity.pos)
								player.entity.action = .KnockedBack
								player_damage += 10
							}
						case:
							fmt.assertf(false, "unhanled damage source")
						}
					}
				}
			}

			// Slash can't be infinite, the player is too OP and there is no sense of speed/urgency
			if player.entity.action == .Slashing {
				player.slash_timer += state.unscaled_dt
				if player.slash_timer > SLASH_LIMIT {
					player.slash_timer = 0
					player.entity.action = .Nothing
				}
			}

			// Move player map
			{
				// not using map_camera_target.zoom xd
				target := player.map_camera_target.pos
				to_target := linalg.normalize0(target - player.map_camera.pos)
				prev_pos := player.map_camera.pos
				player.map_camera.pos += to_target * 10000 * state.unscaled_dt
				if was_overshoot(target, prev_pos, player.map_camera.pos) {
					player.map_camera.pos = target
				}
			}

			// Figure out which decorations need to be a bit transparent
			{
				hits := query_colliders_intersecting_hitbox(
					&state.physics,
					hitbox_from_pos_size(player.entity.pos, player.entity.hitbox_size),
					MAX_TRANSPARENT_DECOR,
					LAYER_MASK_TRANSPARENT_COVER,
				)
				clear(&state.transparent_decor)
				for hit in hits {
					assert(EntityType(hit.type) == .Decoration)
					idx := transmute(i32)hit.handle
					append(&state.transparent_decor, idx)
				}
			}
		}

		if phase == .Render {
			color := Color{0, 0, 0, 1}

			if DEBUG_LINES {
				draw_line(
					state,
					player.entity.pos,
					player.entity.pos + player.entity.velocity * 3,
					2,
					to_floating_color({255, 0, 0, 255}),
				)
			}

			switch player.entity.action {
			case .Nothing:
			// Nothing. yet
			case .Slashing:
				// Draw trail
				// The thickness of the train is supposed to convey how much time you have left,
				// but I'm not sure how good of a job it's actually doing ...
				for i in 1 ..< player.slash_points_len {
					slash_point_prev :=
						player.slash_points[(player.slash_points_idx + 1 + i - 1) % player.slash_points_len]
					slash_point :=
						player.slash_points[(player.slash_points_idx + i + 1) % player.slash_points_len]
					t := 2 * slash_point.slash_timer / (SLASH_LIMIT)
					if t > 1 {
						t = f32(1.0) - (t - 1)
					}
					line_thickness := player.entity.size * 0.2 * t
					draw_line(state, slash_point_prev.pos, slash_point.pos, line_thickness, color)
				}
			case .Walking:
			// Nothing. yet
			case .KnockedBack:
				color.r = lerp(1, 0, linalg.length(player.entity.knockback) / KNOCKBACK_MAGNITUDE)
			}

			// Crosshair for aiming
			crosshair_distance :: 300
			// crosshair_pos := player.pos + unit_circle(player.target_angle) * crosshair_distance
			crosshair_pos := player.entity.target_pos
			draw_crosshairs(
				state,
				crosshair_pos,
				50 / state.camera.zoom,
				4 / state.camera.zoom,
				COL_FG,
			)

			if DEBUG_LINES {
				draw_rect(state, player.entity.pos, player.entity.hitbox_size, COL_DEBUG, .Solid)
			}

			if player.interaction != nil {
				if entity, ok := hm.get(&state.entities, player.interaction.handle); ok {
					pos := to_screen_uipos(state, entity.pos + {0, -entity.size / 2})
					text := text_column_make(pos, 30, 5, CENTER_ALIGN)
					draw_text_row_screenspace(&text, "[X] interact")
				}
			}
		}
	}

	// Entities
	{
		if phase == .Render {
			render_entity :: proc(state: ^GameState, entity: ^Entity) {
				render_character_sprite(
					state,
					entity.pos,
					entity.size,
					entity.color,
					entity.animation,
					entity.target_pos - entity.pos,
					entity.type,
				)

				if DEBUG_LINES {
					draw_rect(state, entity.pos, entity.hitbox_size, COL_DEBUG, .Solid)

					if DEBUG_LINES {
						draw_rect(
							state,
							entity.target_pos,
							{100, 100},
							to_floating_color({255, 0, 0, 100}),
						)
					}
				}
			}

			// Draw dead entities under alive ones
			for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
				if entity.health <= 0 {continue}
				render_entity(state, entity)
			}

			for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
				if entity.health > 0 {continue}
				render_entity(state, entity)
			}
		}

		if phase == .Update {
			for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
				if entity.hit_cooldown > 0 {
					entity.hit_cooldown -= 5 * state.dt
				}

				entity_is_alive := entity.health > 0
				if entity_is_alive {
					// Needs to happen every frame actually
					entity->update_fn(state, .ReOrient)
				}

				entity_movement(state, entity)

				// Animate color
				{
					usual_color := entity.usual_color
					if !entity_is_alive {
						usual_color = COL_DEAD
					}

					color_lerp :: proc(a, b: Color, t: f32) -> Color {
						return {
							lerp(a.r, b.r, t),
							lerp(a.g, b.g, t),
							lerp(a.b, b.b, t),
							lerp(a.a, b.a, t),
						}
					}

					if entity.hit_cooldown > 0 {
						entity.color = color_lerp(usual_color, COL_DAMAGE, entity.hit_cooldown)
					} else {
						responsiveness :: 5
						entity.color = color_lerp(entity.color, usual_color, responsiveness * state.dt)
					}
				}

				step_character_animation(
					state,
					&entity.animation,
					(entity.prev_pos - entity.pos) * entity.move_speed,
					entity.health > 0,
					false,
					&entity.dead_duration,
				)
			}
		}
	}

	// Draw decorations that sit above entities
	if phase == .Render {
		it := get_chunk_iter(state, bottom_left, top_right)
		for chunk, coord in iter_chunks(&it) {
			chunk_pos := chunk_coord_to_pos(coord)

			for &decoration, idx in chunk.decorations {
				col := COL_WHITE
				id := get_chunk_decoration_id(chunk, idx)
				if slice.contains(state.transparent_decor[:], i32(idx)) {
					col.a = 0.5
				}

				draw_decoration(
					state,
					decoration.type,
					chunk_pos + decoration.pos,
					decoration.size,
					col,
				)
			}
		}
	}

	// Draw camera lock, or map origin
	if phase == .Render {
		draw_crosshair := false
		if player.camera_lock {
			crosshair_pos := player.camera_lock_pos
			draw_crosshairs(
				state,
				crosshair_pos,
				50 / state.camera.zoom,
				4 / state.camera.zoom,
				COL_UI_SELECTED,
			)
		} else if player.viewing_map {
			crosshair_pos := player.map_camera.pos
			draw_crosshairs(
				state,
				crosshair_pos,
				50 / state.camera.zoom,
				4 / state.camera.zoom,
				COL_UI_SELECTED,
			)
		}
	}

	// camera
	if phase == .Update {
		target_camera: Camera2D
		if player.viewing_map {
			target_camera = player.map_camera
		} else {
			target_camera = get_player_camera(player)

			if IS_DEBUGGING_LOADING_UNLOADING {
				target_camera.zoom /= 5
			}
		}

		camera_zoom_speed :: 40.0
		camera_pos_speed := f32(CAMERA_MOVE_SPEED)
		if player_was_slashing {
			camera_pos_speed = 0
		}

		state.camera = camera_lerp(
			state.camera,
			target_camera,
			state.unscaled_dt * camera_pos_speed,
			state.unscaled_dt * camera_zoom_speed,
		)
	}

	// Dialog
	{
		dialog := &state.ui.npc_dialog
		if entity, ok := hm.get(&state.entities, dialog.entity); ok {
			text := dialog.text
			talking_speed := f32(50)
			dialog_duration := f32(len(text)) + 1 * talking_speed

			if phase == .Update {
				if dialog.text_idxf < dialog_duration {
					dialog.text_idxf += talking_speed * state.dt
				} else {
					set_current_entity_dialog(state, "", {})
				}
			}

			if phase == .Render {
				if dialog.text_idxf < dialog_duration {
					up_to := math.min(int(dialog.text_idxf), len(text))
					text_slice := text[:up_to]

					pos := entity.pos
					offset := Vector2{entity.size, entity.size} / 2
					draw_line(
						state,
						pos + offset,
						pos + 2 * offset,
						10 / state.camera.zoom,
						COL_FG,
					)

					text := text_column_make(
						to_screen_uipos(state, pos + 3 * offset),
						30,
						10,
						CENTER_ALIGN,
					)
					draw_text_row_screenspace(&text, "%v", text_slice)
				}
			}
		}
	}


	// UI
	if state.view == .Game && phase == .Render {
		switch {
		case !player_is_alive:
			choices := 2
			switch {
			case state.input.direction.x < -0.5:
				if !state.ui.resurrect_or_quit.got_axis {
					state.ui.resurrect_or_quit.got_axis = true
					state.ui.resurrect_or_quit.idx -= 1
					if state.ui.resurrect_or_quit.idx < 0 {
						// state.ui.resurrect_or_quit.idx = choices - 1
						state.ui.resurrect_or_quit.idx = 0
					}
				}
			case state.input.direction.x > 0.5:
				if !state.ui.resurrect_or_quit.got_axis {
					state.ui.resurrect_or_quit.got_axis = true
					state.ui.resurrect_or_quit.idx += 1
					if state.ui.resurrect_or_quit.idx >= choices {
						// state.ui.resurrect_or_quit.idx = 0
						state.ui.resurrect_or_quit.idx = choices - 1
					}
				}
			case:
				state.ui.resurrect_or_quit.got_axis = false
			}

			center := Vector2{state.window_size.x / 2, 2 * state.window_size.y / 3}
			size: UiLength = 100

			resurrect_text := ui_text(fmt.ctprintf("Resurrect"), size)
			quit_text := ui_text(fmt.ctprintf("Quit"), size)

			height := size
			selector_size := height
			width := resurrect_text.width + quit_text.width + selector_size + selector_size

			x := c.int(center.x) - width / 2
			y := c.int(center.y) - size / 2

			color: Color
			is_chosen: bool

			current_choice := 0
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? COL_UI_SELECTED : COL_UI_FG
			resurrect_choice := current_choice

			// Selector
			if is_chosen {
				render_selector(x, y, size, color)
			}
			x += selector_size

			// Resurrect button
			{
				rl.DrawText(resurrect_text.text, x, y, size, to_int_color(color))
				x += resurrect_text.width
			}

			current_choice += 1
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? COL_UI_SELECTED : COL_UI_FG
			quit_choice := current_choice

			// Selector
			if is_chosen {
				render_selector(x, y, size, color)
			}
			x += selector_size

			// Quit button
			{
				rl.DrawText(quit_text.text, x, y, size, to_int_color(color))
				x += quit_text.width
			}

			// Dont want to accidentally choose when slashing
			if has_submit_input {
				switch {
				case state.ui.resurrect_or_quit.idx == resurrect_choice:
					state.stats.deaths += 1
					player := &state.player
					player.entity.health = INITIAL_PLAYER_HEALTH
				case state.ui.resurrect_or_quit.idx == quit_choice:
					state.requested_quit = true
				}
			}
		case:
			state.ui.resurrect_or_quit.idx = 0
			state.ui.resurrect_or_quit.got_axis = false
		}

		// debug text
		if IS_DEBUGGING_GAME {
			text := text_column_make({10, 10}, 30, 10)

			// TODO: proper health bar
			draw_text_row_screenspace(&text, "health: %v", player.entity.health)
			draw_text_row_screenspace(&text, "action: %v", player.entity.action)

			{
				i, c := get_total_items_capacity(state.entity_grid)
				draw_text_row_screenspace(&text, "entities: %v/%v", i, c)
			}

			{
				i, c := get_total_items_capacity(state.large_items_grid)
				draw_text_row_screenspace(&text, "large items: %v/%v", i, c)
			}

			{
				i, c := get_total_items_capacity(state.large_items_grid)
				draw_text_row_screenspace(&text, "entities: %v", hm.len(state.entities))
			}

			pos := to_game_pos(state, state.input.screen_position)
			ground_pos := world_pos_to_ground_pos(pos)
			draw_text_row_screenspace(&text, "mouse pos: %v, chunk: %v", pos, ground_pos)
			draw_text_row_screenspace(&text, "zoom: %v", state.camera.zoom)
			draw_text_row_screenspace(&text, "chunks triggered: %v", len(state.chunks_loaded))
		}
	}

	// Postprocessing
	if phase == .Update {
		// Apply damage to player
		if player_damage > 0 {
			player.entity.health -= player_damage
		}

		// Kill off any dead entities
		for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
			if entity.id == ENTITY_ID_PLAYER {
				// Not the player tho
				continue
			}

			if entity.health <= 0 && entity.dead_duration >= MAX_DEATH_DURATION {
				entity->update_fn(state, .UnloadedDeath)

				// Entity can choose to revive themselves here if they wish, so we check health again
				if entity.health <= 0 {
					hm.remove(&state.entities, handle)
				}
			}
		}
	}

	when DEV_TOOLS_ENABLED {
		run_devtools(state, &global_devtools, phase)
	}
}

render_selector :: proc(x, y, size: c.int, color: Color) {
	selector_center := Vector2i32{x + size / 2, y + size / 2}
	selector_inner_size := c.int(size / 2)
	x := selector_center.x - selector_inner_size / 2
	y := selector_center.y - selector_inner_size / 2
	rl.DrawRectangle(x, y, selector_inner_size, selector_inner_size, to_int_color(color))
}

render_current_view :: proc(state: ^GameState, phase: RenderPhase) {
	if state.previous_view != state.view {
		// totally unused! no way!

		// Cleanup previous view
		switch state.previous_view {
		case .Start:
		case .Game:
		}

		// Initialize next view
		switch state.view {
		case .Start:
		case .Game:
		}

		state.previous_view = state.view
	}

	// always render the game
	render_game(state, phase)

	if state.view == .Start {
		render_start_screen(state, phase)
	}
}

render_character_sprite :: proc(
	state: ^GameState,
	pos: Vector2,
	size: f32,
	color: Color,
	animation: AnimationState,
	direction: Vector2,
	character: CharacterType,
) {
	sprite_idx: int
	switch animation.phase {
	case .Walking:
		sprite_idx = PLAYER_WALKING_SEQUENCE[animation.idx]
	case .Death:
		sprite_idx = PLAYER_DEATH_SEQUENCE[animation.idx]
	case .Slashing:
		sprite_idx = SLASHING_SEQUENCE[animation.idx]
	}
	angle := math.atan2(-direction.y, direction.x)

	y := CHARACTER_TYPES[character].row_idx

	draw_rect_textured_spritesheet(
		state,
		pos,
		size,
		color,
		state.assets.chacracters,
		{sprite_idx, y},
		angle + QUARTER_TURN,
	)
}

StepMode :: enum {
	Loop,
	NoLoop,
}

step_spritesheet :: proc(
	sequence: []int,
	anim: ^AnimationState,
	interval: f32,
	dt: f32,
	mode: StepMode,
) -> int {
	anim.timer += dt
	if anim.timer > interval {
		anim.timer = 0
		anim.idx += 1

		if anim.idx >= len(sequence) {
			switch mode {
			case .Loop:
				anim.idx = 0
			case .NoLoop:
				anim.idx = len(sequence) - 1
			}
		}
	}

	return sequence[anim.idx]
}

step_spritesheet_backwards :: proc(
	sequence: []int,
	anim: ^AnimationState,
	interval: f32,
	dt: f32,
	mode: StepMode,
) -> int {
	anim.timer += dt
	if anim.timer > interval {
		anim.timer = 0
		anim.idx -= 1

		if anim.idx < 0 {
			switch mode {
			case .Loop:
				anim.idx = len(sequence) - 1
			case .NoLoop:
				anim.idx = 0
			}
		}
	}

	return sequence[anim.idx]
}

step_character_animation :: proc(
	state: ^GameState,
	anim: ^AnimationState,
	dir: Vector2,
	is_alive: bool,
	is_slashing: bool,
	dead_time: ^f32,
) {
	input := linalg.length(dir)

	prev_phase := anim.phase

	switch {
	case !is_alive || dead_time^ > 0:
		anim.phase = .Death
	// TODO: resurrecting as the reverse of the death animation
	case is_slashing:
		anim.phase = .Slashing
	case:
		anim.phase = .Walking
	}

	if prev_phase != anim.phase {
		anim.idx = 0
	}

	switch anim.phase {
	case .Walking:
		// If we stop walking, we should continue the animation till we reach idx 0, so that our arms
		// aren't stuck in a walking position.
		idx := PLAYER_WALKING_SEQUENCE[anim.idx]
		speed := 10 * state.dt
		if input < 0.001 && idx == 0 {
			speed = 0
		}
		step_spritesheet(PLAYER_WALKING_SEQUENCE[:], anim, 1, speed, .Loop)
	case .Death:
		speed := 4 * state.dt
		if !is_alive {
			// die
			if anim.idx < len(PLAYER_DEATH_SEQUENCE) - 1 {
				step_spritesheet(PLAYER_DEATH_SEQUENCE[:], anim, 1, speed, .NoLoop)
			} else {
				dead_time^ += state.dt
			}
		} else {
			// revive (!)
			if anim.idx > 0 {
				step_spritesheet_backwards(PLAYER_DEATH_SEQUENCE[:], anim, 1, speed, .NoLoop)
			} else {
				dead_time^ = 0
			}
		}
	case .Slashing:
		if anim.idx < len(SLASHING_SEQUENCE) - 1 {
			speed := 4 * state.dt
			step_spritesheet(SLASHING_SEQUENCE[:], anim, 1, speed, .NoLoop)
		}
	}
}

run_game :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		rl.DrawFPS(10, c.int(state.window_size.y) - 40)

		if state.time == 0 {
			state.time = rl.GetTime()
			state.physics_dt = 1.0 / 120.0
		}

		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.ClearBackground(to_int_color(COL_WATER))

		// Run physics updates with a fixed timestep. This means that
		// a) our physics will be deterministic (on the same machine, anyway), which is awesome
		// b) I can do x = lerp(x, a, b) and it's totally fine
		time := rl.GetTime()
		dt := math.min(time - state.time, 0.5)
		state.time_since_physics_update += f32(dt)
		state.time = time
		for state.time_since_physics_update > state.physics_dt {
			state.time_since_physics_update -= state.physics_dt
			render_current_view(state, .Update)
		}

		render_current_view(state, .Render)
	}; rl.EndDrawing()

	free_all(context.temp_allocator)
}

normalize_angle :: proc(angle: f32) -> f32 {
	angle := angle
	if angle < 0 {
		angle += math.TAU
	} else if angle > math.TAU {
		angle -= math.TAU
	}

	return angle
}

draw_crosshairs :: proc(state: ^GameState, pos: Vector2, size: f32, thickness: f32, color: Color) {
	draw_line(state, pos - {size, 0}, pos + {size, 0}, thickness, color)
	draw_line(state, pos - {0, size}, pos + {0, size}, thickness, color)
}

damage_entities :: proc(state: ^GameState, damage_ray: Ray) {
	hits := query_colliders_intersecting_ray(
		&state.physics,
		damage_ray,
		limit = 1_000_000,
		mask = LAYER_MASK_ENEMY,
	)

	player := &state.player

	for &item in hits {
		assert(EntityType(item.type) == .Entity)

		entity, ok := hm.get(&state.entities, item.handle)
		if !ok {continue}

		if entity.hit_cooldown > 0 {continue}
		if entity.health <= 0 {continue}
		if !entity.can_damage_player {continue} 	// Correspondingly, we can't damage entities that can't damage us.

		entity.health -= PLAYER_TO_ENEMY_DAMAGE
		if entity.health <= 0 {
			entity->update_fn(state, .Death)
		}

		entity.hit_cooldown = 1
		player.entity.angle = get_angle_vec(player.entity.target_pos - player.entity.pos)

		// On the fence about regenerating the slash when we hit stuff. I think its too OP.
		if player.entity.action == .Slashing {
			player.slash_timer = 0
		}
	}
}

move_angle_towards :: proc(current, target, delta: f32) -> f32 {
	return current + math.clamp(math.angle_diff(current, target), -delta, delta)
}

new_game_state :: proc(allocator := context.allocator) -> ^GameState {
	state := new(GameState, allocator)

	load_spritesheet :: proc(bytes: []u8, sprite_size: int, padding: int = 0) -> Spritesheet {
		image := rl.LoadImageFromMemory(".png", raw_data(bytes), c.int(len(bytes)))
		sprite_size := sprite_size
		if sprite_size == -1 {
			sprite_size = int(image.height)
		}
		return {
			texture = rl.LoadTextureFromImage(image),
			sprite_size = sprite_size,
			padding = padding,
		}
	}

	assets := &state.assets

	assets.chacracters = load_spritesheet(#load("./assets/sprite1.png"), 32, 1)
	// 1px padding on environment is good - avoids seams
	assets.environment = load_spritesheet(#load("./assets/environment.png"), 64, 1)
	assets.decorations = load_spritesheet(#load("./assets/decorations.png"), 64, 1)

	if IS_DEBUGGING_GAME {
		// Get straight into it
		state.view = .Game
	}

	// physics
	{
		// Fine tune based on entity sizes, performance, etc.
		// NOTE: must be sorted ascending in size
		state.grids_backing_store = [2]SparseGrid {
			{grid_size = 300},
			{grid_size = CHUNK_WORLD_WIDTH},
		}
		state.entity_grid = &state.grids_backing_store[0]
		state.large_items_grid = &state.grids_backing_store[1]
		state.physics.grids = state.grids_backing_store[:]
	}

	state.player.entity, _ = add_entity_at_position(state, {}, ENTITY_ID_PLAYER)

	create_world(state)

	idx := 0
	for coord, &chunk in state.chunks {
		chunk.idx = idx
	}

	when DEV_TOOLS_ENABLED {
		init_devtools(&global_devtools)
	}

	return state
}

draw_decoration :: proc(
	state: ^GameState,
	type: DecorationType,
	pos: Vector2,
	size: f32,
	col: Color,
) {
	draw_rect_textured_spritesheet(
		state,
		pos,
		size = {size, size},
		col = col,
		spritesheet = state.assets.decorations,
		sprite_coordinate = DECORATION_TYPES[type].spritesheet_coord,
	)
}

// If not unique, we can have an 'arbitrary' number of this npc/entity
NOT_UNIQUE :: EntityId(0)

nil_update_fn :: proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType) {}

add_entity_at_position :: proc(
	state: ^GameState,
	pos: Vector2,
	unique_id := NOT_UNIQUE,
	update_fn := nil_update_fn,
) -> (
	^Entity,
	bool,
) {
	if unique_id != NOT_UNIQUE {
		already_added: ^Entity

		it := hm.iterator_make(&state.entities)
		for entity, handle in hm.iterate(&it) {
			if entity.id == unique_id {
				already_added = entity
				break
			}
		}

		if already_added != nil {
			return already_added, false
		}
	}

	entity := Entity {
		id         = unique_id,
		update_fn  = update_fn,
		pos        = pos,
		target_pos = pos + {0, -1},
	}

	entity->update_fn(state, .Loaded)

	handle, _ := hm.add(&state.entities, entity)
	return hm.get(&state.entities, handle)
}

// Should mainly be appearance and not really related to behaviours
set_entity_appearance :: proc(
	state: ^GameState,
	entity: ^Entity,
	type: CharacterType,
	color := COL_WHITE,
	size: f32 = 100,
	health: f32 = 10,
) {
	debug_log("%v", entity.pos)
	hitbox_size_sprite := CHARACTER_TYPES[type].hitbox_size
	hitbox_side_length :=
		f32(hitbox_size_sprite / f32(state.assets.chacracters.sprite_size)) * size
	entity.type = type
	entity.hitbox_size = Vector2{hitbox_side_length, hitbox_side_length}
	entity.color = color
	entity.usual_color = color
	entity.size = size
	entity.health = health
}

get_entity_by_id :: proc(state: ^GameState, id: EntityId) -> (^Entity, bool) {
	for it := hm.iterator_make(&state.entities); entity, handle in hm.iterate(&it) {
		if entity.id == id {
			return entity, true
		}
	}

	return nil, false
}

// Should not be affected by switching to the map view, for example.
// We use this to correctly load and unload physics entities and proximity triggers based on the player's view.
get_player_camera :: proc(player: ^Player) -> (result: Camera2D) {
	if player.camera_lock {
		result.pos = player.camera_lock_pos
	} else {
		result.pos = player.entity.pos
	}

	result.zoom = f32(PLAYER_CAMERA_ZOOM)

	return
}

draw_debug_hitbox :: proc(state: ^GameState, hitbox: Hitbox, col := COL_DEBUG) {
	pos := hitbox_centroid(hitbox)
	size := Vector2{hitbox_width(hitbox), hitbox_height(hitbox)}
	draw_rect(state, pos, size, col, .Solid)
}

entity_movement :: proc(state: ^GameState, entity: ^Entity) {
	if entity.health > 0 {
		// Look at target
		{
			entity_to_target := entity.target_pos - entity.pos
			entity.target_angle = normalize_angle(
				math.atan2(entity_to_target.y, entity_to_target.x),
			)
			if entity.action != .KnockedBack {
				entity.angle = entity.target_angle
			}
		}

		prevent_overshoot := false
		new_velocity: Vector2

		// figure out velocity.
		if entity.action == .KnockedBack {
			new_velocity = entity.knockback
			knockback_decay :: 30.0
			if linalg.length(entity.knockback) > 1 {
				entity.knockback = linalg.lerp(
					entity.knockback,
					Vector2{0, 0},
					state.dt * knockback_decay,
				)
			} else {
				entity.knockback = 0
				entity.action = .Nothing
			}
		} else {
			prevent_overshoot = true

			entity_to_target := entity.target_pos - entity.pos
			move_speed: f32

			if linalg.length(entity_to_target) > 5 {
				#partial switch entity.action {
				case .Slashing:
					move_speed = SLASH_SPEED * SLASH_MULTIPLIER
				case .Walking:
					move_speed = entity.move_speed
				}
			}

			new_velocity = unit_circle(entity.angle) * move_speed
		}

		// apply velocity
		{
			// Other systems might also care about it
			entity.velocity = new_velocity
			entity.prev_pos = entity.pos

			new_pos: Vector2
			found_pos := false

			// TODO: only do the racast and whatnot for objects moving quickly
			hit: ^SparseGridItem
			for divisor := 1; divisor <= 16; divisor *= 2 {
				new_pos = entity.pos + entity.velocity * state.dt / f32(divisor)
				if divisor > 8 {
					new_pos = entity.pos
					entity.velocity = 0
				}

				// Check movement ray
				if divisor <= 8 {
					movement_ray := ray_from_start_end(entity.prev_pos, new_pos)
					hits := query_colliders_intersecting_ray(
						&state.physics,
						movement_ray,
						1,
						LAYER_MASK_OBSTRUCTION,
						ignore_type = int(EntityType.Entity),
						ignore_handle = entity.handle,
					)

					if len(hits) > 0 {
						if divisor == 8 {
							hit = hits[0]
							break
						} else {
							continue
						}
					}
				}

				// Then, query hitbox
				{
					new_entity_hitbox := hitbox_from_pos_size(new_pos, entity.hitbox_size)
					hits := query_colliders_intersecting_hitbox(
						&state.physics,
						new_entity_hitbox,
						4,
						LAYER_MASK_OBSTRUCTION,
						ignore_type = int(EntityType.Entity),
						ignore_handle = entity.handle,
					)

					if len(hits) == 0 {
						found_pos = true
						entity.last_entity_collision_handle = {}
						break
					}

					if divisor == 8 && len(hits) > 0 {
						hit = hits[0]
						break
					}
				}
			}

			handle := hit != nil ? hit.handle : {}
			if entity.last_entity_collision_handle != handle {
				entity.last_entity_collision_handle = handle
				if entity, ok := hm.get(&state.entities, handle); ok {
					entity->update_fn(state, .CollidedWithPlayer)
				}
			}

			if found_pos {
				// prevent overshooting the target
				entity.pos = new_pos
				if was_overshoot(entity.target_pos, entity.prev_pos, entity.pos) {
					entity.pos = entity.target_pos
				}
			} else {
				entity.action = .KnockedBack
				if entity.knockback == 0 {
					entity.knockback = 3000 * unit_circle(rand.float32_range(0, 1))
				}
				// TODO: make sure the entity cant get stuck in stuff, push the player out. PHysic engine!
				// TODO: use racyasting to find a beter position instead of just not assigning the position
			}
		}
	}
}

query_interactions :: proc(state: ^GameState, pos: Vector2) -> ^SparseGridItem {
	hits := query_colliders_intersecting_point(&state.physics, pos, mask = LAYER_MASK_INTERACTION)
	interacted := false
	for hit in hits {
		if EntityType(hit.type) == .Entity {
			if entity, ok := hm.get(&state.entities, hit.handle); ok {
				return hit
			}
		}
	}

	return nil
}

set_current_entity_dialog :: proc(state: ^GameState, text: string, entity: Handle) {
	dialog := &state.ui.npc_dialog
	dialog.text = text
	dialog.text_idxf = 0
	if dialog.entity != entity {
		prev_entity := dialog.entity
		// set before we call the update_fn, prevent infinite recursion
		dialog.entity = entity
		if entity, ok := hm.get(&state.entities, prev_entity); ok {
			entity->update_fn(state, .DialogComplete)
		}
	}
}

orient_towards_target :: proc(
	state: ^GameState,
	entity: ^Entity,
	speed : f32,
	target_pos: Vector2,
	target_vecloity: Vector2,
	responsiveness : f32 = 10,
) {
	if entity.action != .Walking && entity.action != .Nothing && entity.action != .Slashing {
		return
	}

	entity.move_speed = speed

	if entity.move_speed == 0 {
		// Simply look down
		entity.target_pos = entity.pos + {0, -1}
		entity.action = .Nothing
		return;
	}

	entity.action = .Walking

	// Move towards the player
	// (But they need to not bump into each other tho you know what im sayin)

	entity.prev_pos = entity.pos
	wanted_target := estimate_decent_intercept_point(
		entity.pos,
		entity.move_speed,
		target_pos,
		target_vecloity,
		state.dt,
	)
	entity.target_pos = wanted_target
	debug_log("sped: %v", entity.target_pos - entity.pos)
	// linalg.lerp(
	// 	entity.target_pos,
	// 	wanted_target,
	// 	state.dt * responsiveness,
	// )

	// to_target := linalg.normalize0(entity.target_pos - entity.pos)

	// directions_to_try := [?]Vector2 {
	// 	Vector2{to_target.x, to_target.y}, // Towards to_target
	// 	Vector2{-to_target.y, to_target.x}, // Perpendicular
	// 	Vector2{to_target.y, -to_target.x}, // Other perpendicular
	// 	-Vector2{to_target.x, to_target.y}, // Away from target
	// }
	//
	// for &dir in directions_to_try {
	// 	new_pos := entity.pos + entity.move_speed * dir * state.dt
	//
	// 	hits := query_colliders_intersecting_hitbox(
	// 		&state.physics,
	// 		hitbox_from_pos_size(new_pos, entity.hitbox_size),
	// 		limit       = 10,
	// 		mask        = LAYER_MASK_OBSTRUCTION | LAYER_MASK_ENEMY,
	// 		ignore_type = int(EntityType.Entity), ignore_handle = entity.handle,
	// 	)
	//
	// 	if len(hits) > 0 {
	// 		// we got [this entity, some other entity], so this space is occupied. pick another direction
	// 		continue
	// 	}
	//
	// 	entity.target_pos = entity.pos + dir * entity.move_speed
	// }
}

get_player :: proc(state: ^GameState) -> ^Entity {
	player, ok := get_entity_by_id(state, ent_id(.Player))
	assert(ok)
	return player
}

