package game

import hm "core:container/handle_map"
import "core:slice"
import "core:fmt"
import "core:c"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib";

// Player
PLAYER_CAMERA_ZOOM     :: 0.8   // how close is the camera? Zoom out further - the player is more OP, but aiming is a lot harder.
SLASH_SPEED            :: 2000  // The base movemvent speed to use while slashing. Gets multiplied by the slash multipler. xd
SLASH_MULTIPLIER       :: 200   // timescaled speed increase while slashing
SLASH_LIMIT            :: 0.20  // Time we are allowed to spend slashing
TIME_SLOWDOWN          :: 30    // How much do we slow down time while the player is slashing?
KNOCKBACK_MAGNITUDE    :: 10000 // Force with which enemies knock a player back
INITIAL_PLAYER_HEALTH  :: 100   // -
PLAYER_TO_ENEMY_DAMAGE :: 100   // The damage a player does to enemies
WALK_SPEED             :: 900   // Speed to use while walking
CAMERA_MOVE_SPEED      :: 50    // The speed at which the camera moves to the player. Has a large effect on gameplay
MAP_MIN_ZOOM :: 0.01

DEV_TOOLS_ENABLED :: true
when DEV_TOOLS_ENABLED {
	global_devtools : Devtools
}

// Enemies
MAX_ENEMIES :: 3000   // The maximum number of enemies we can ever spawn. Any more, and the game starts lagging like hell.
ENEMY_STUCK_COOLDOWN :: 0.3  // When an enemy has nowhere to go, it stays 'stuck' for this long, instead of jittering at 60fps

// Decorations
MAX_DECORATIONS :: 1000

// Animations
PLAYER_WALKING_SEQUENCE := [?]int { 0, 1, 2, 1, 0, 3, 4, 3, }
PLAYER_DEATH_SEQUENCE   := [?]int { 5, 6, 7 }
SLASHING_SEQUENCE       := [?]int { 2 } // TODO: dedicated sprite

// Debug flags
DEBUG_LINES :: false // Set to true to see hitboxes and such
IS_DEBUGGING_LOADING_UNLOADING :: false
IS_DEBUGGING_GAME :: true
IS_DEBUGGING_WORLD :: false

INITIAL_ENEMIES     :: 1
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
	current_pos: Vector2, capable_speed: f32, 
	target_pos, target_vel: Vector2,
	dt: f32
) -> Vector2 {
	// Don't overthink it. for now
	return target_pos + 20 * target_vel * dt
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
	size : UiLength = 100

	if phase == .Render {
		center := state.window_size / 2

		start_text := ui_text(fmt.ctprintf("Start"), size)
		width := start_text.width + size
		color := Color{ 255, 0, 0, 255 }

		x := c.int(center.x) - width / 2
		y := c.int(center.y) - start_text.height / 2

		render_selector(x, y, size, color)
		x += size

		rl.DrawText(start_text.text, x, y, size, color)

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

	player := &state.player;
	player_is_alive := state.player.health > 0

	player_was_slashing := player.action == .Slashing

	update_dt := state.physics_dt
	unscaled_dt := state.physics_dt
	if player_was_slashing || player.viewing_map {
		update_dt = state.physics_dt / TIME_SLOWDOWN
	}
	dt := f32(0)
	if phase == .Update {
		dt = update_dt
	}

	bottom_left := to_game_pos(state, {0, state.window_size.y})
	top_right   := to_game_pos(state, {state.window_size.x, 0})

	player_camera := get_player_camera(player)
	player_camera_size := screen_to_camera_size(player_camera, state.window_size)
	player_view_box := hitbox_from_pos_size(player.pos, player_camera_size)
	chunks_to_load_box := grow_hitbox(player_view_box, 0.25)
	// prevent moving left/right by 2 pixels from loading/unloading chunks.
	chunks_to_unload_box := grow_hitbox(chunks_to_load_box, 0.25)

	// Load and unload proximity triggers
	if phase == .Update {
		

		// unload loaded chunks
		for i := 0; i < len(state.chunks_loaded); i += 1 {
			loaded_chunk := state.chunks_loaded[i]

			chunk_size := Vector2{CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH}
			chunk_pos    := chunk_coord_to_pos(loaded_chunk.coord) + chunk_size / 2
			chunk_hitbox := hitbox_from_pos_size(chunk_pos, {CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH})

			if !collide_box_with_box(chunk_hitbox, chunks_to_unload_box) {
				for &trigger in loaded_chunk.chunk.loadevents {
					process_load_event(state, loaded_chunk, trigger, .Unload)
				}

				loaded_chunk.chunk.loaded = false
				unordered_remove(&state.chunks_loaded, i)
				i -= 1;
			}
		}

		// load unloaded chunks
		it := get_chunk_iter_excluding_surroundings(state, {chunks_to_load_box.left, chunks_to_load_box.bottom }, {chunks_to_load_box.right, chunks_to_load_box.top })
		for chunk, coord in iter_chunks(&it) {
			if !chunk.loaded {
				chunk.loaded = true
				append(&state.chunks_loaded, ChunkCoordPair{chunk, coord})

				for &trigger in chunk.loadevents {
					process_load_event(state, {chunk, coord}, trigger, .Load)
				}
			}
		}
	}

	if phase == .Render {
		it := get_chunk_iter(state, bottom_left, top_right)
		for chunk, coord in iter_chunks(&it) {
			chunk_pos := chunk_coord_to_pos(coord)

			for x in 0..<CHUNK_GROUND_ROW_COUNT {
				for y in 0..<CHUNK_GROUND_ROW_COUNT {
					ground := ground_at(chunk, {x, y}) 
					if ground.type == .None {continue}

					pos := chunk_pos + 
						CHUNK_GROUND_HALF_OFFSET + 
						Vector2{ f32(x * CHUNK_GROUND_SIZE), f32(y * CHUNK_GROUND_SIZE) }

					draw_rect_textured_spritesheet(
						state, pos,
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
			chunk_pos    := chunk_coord_to_pos(loaded_chunk.coord) + chunk_size / 2
			chunk_hitbox := hitbox_from_pos_size(chunk_pos, {CHUNK_WORLD_WIDTH, CHUNK_WORLD_WIDTH})
			draw_debug_hitbox(state, chunk_hitbox)
		}

		draw_debug_hitbox(state, player_view_box, Color{0, 0, 255, 100})
		draw_debug_hitbox(state, chunks_to_load_box, Color{0, 255, 0, 100})
		draw_debug_hitbox(state, chunks_to_unload_box, Color{255, 0, 0, 100})
	}


	// Most input processing has to happen every _frame_ in the render phase instead of every physics update.
	if phase == .Render {
		// Populate solely from input devices
		{
			state.input.button1              = rl.IsKeyDown(.Z)
			state.input.button1_press         = rl.IsKeyPressed(.Z)
			state.input.button2              = rl.IsKeyDown(.X)
			state.input.button2_press         = rl.IsKeyPressed(.X)
			state.input.button3              = rl.IsKeyPressed(.C)
			state.input.mapbutton            = rl.IsKeyPressed(.V)
			state.input.cancel               = rl.IsKeyPressed(.ESCAPE)
			state.input.submit               = rl.IsKeyPressed(.ENTER)
			state.input.shift                = rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			state.input.direction            = get_direction_input()
			state.input.prev_screen_position = state.input.screen_position
			state.input.screen_position      = rl.GetMousePosition()
			state.input.click                = rl.IsMouseButtonPressed(.LEFT)
			state.input.click_hold           = rl.IsMouseButtonDown(.LEFT)
			state.input.rclick               = rl.IsMouseButtonPressed(.RIGHT)
		}

		// handle input
		{
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
						player.map_camera = {player.pos, 0.1}
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
						player.map_camera_target.pos = to_game_pos(state, state.input.screen_position)
					} else {
						player.map_camera_target.pos = player.map_camera.pos
					}

					if state.input.direction.y > 0 {
						player.map_camera.zoom *= (1 + unscaled_dt * state.input.direction.y)
						if player.map_camera.zoom > 1 {
							player.map_camera.zoom = 1
						}
					} else if state.input.direction.y < 0 {
						player.map_camera.zoom /= (1 - unscaled_dt * state.input.direction.y)
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
								if enemy, ok := hm.get(&state.enemies, handle); ok {
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
							player.camera_lock_pos = to_game_pos(state, state.input.screen_position)
						}
					}

					if player.action != .KnockedBack {
						prev_action := player.action

						if walk_input {
							if player.action == .Nothing {
								player.action = .Walking
							}
						}

						if slash_input {
							if prev_action != .Slashing && !player.block_slash {
								// Start slashing.
								player.action = .Slashing
								player.block_slash = true
								player.slash_timer = 0

								// ringbuffer 
								{
									player.slash_points_idx = 0
									player.slash_points_len = 1
									player.slash_points[0] = { pos=player.pos,slash_timer=player.slash_timer }
								}
							}
						} 

						if !slash_input && !walk_input {
							player.action = .Nothing
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

		hitbox := hitbox_from_pos_size(player.pos, player.hitbox_size)
		sparse_grid_add(state.entity_grid, hitbox, int(EntityType.Player), {}, LAYER_MASK_PLAYER) 

		// Enemies
		{
			it := hm.iterator_make(&state.enemies)
			for enemy, handle in hm.iterate(&it) {
				if enemy.health <= 0 {continue}

				mask := LAYER_MASK_OBSTRUCTION
				if enemy.can_damage_player {
					// The player needs to be able to slice through this enemy, so it is no longer an obstruction
					mask = LAYER_MASK_ENEMY | LAYER_MASK_DAMAGE
				}

				// Publish interactions to physics engine
				if enemy.can_interact {
					mask = mask | LAYER_MASK_INTERACTION
				}
				
				hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)
				sparse_grid_add(state.entity_grid, hitbox, int(EntityType.Enemy), handle, mask) 
			}
		}

		// Decorations
		{
			it := get_chunk_iter(state, bottom_left, top_right)
			for chunk, coord in iter_chunks(&it) {
				for &decoration, idx in chunk.decorations {
					chunk_pos := chunk_coord_to_pos(coord)
					hitbox := hitbox_from_pos_size(chunk_pos + decoration.pos, decoration.hitbox_size)
					// NOTE: Right now the index has no meaning, so it's set to -1. 
					// Eventually, we may want to have a list of 'loaded decorations' and 'loaded enemies', in which case
					// it does have meaning. 
					sparse_grid_add(state.large_items_grid, hitbox, int(EntityType.Decoration), {}, LAYER_MASK_OBSTRUCTION) 

					if should_be_transparent_when_player_is_under(decoration.type) {
						// Actual size, not hitbox size.
						hitbox := hitbox_from_pos_size(chunk_pos + decoration.pos, 0.8 * decoration.size)
						id := get_chunk_decoration_id(chunk, idx)
						sparse_grid_add(state.large_items_grid, hitbox, int(EntityType.Decoration), transmute(Handle)id, LAYER_MASK_TRANSPARENT_COVER) 
					}
				}
			}
		}
	}

	// player
	{
		if phase == .Update {
			target_opacity := f32(1.0)
			if player.action == .Walking {
				target_opacity = 0.0
			}

			phase_speed :: 100
			player.opacity = 1

			// Query interactions available for the player
			if player_is_alive {
				pos := to_game_pos(state, state.input.screen_position)
				player.interaction = query_interactions(state, pos)
			} else {
				player.interaction = nil
			}

			// Player Movement
			if player_is_alive {
				// Look at target
				{
					player.target_pos = to_game_pos(state, state.input.screen_position)
					player_to_target := player.target_pos - player.pos
					set_player_target_angle(
						player,
						math.atan2(player_to_target.y, player_to_target.x),
					)
					if player.action == .Nothing || player.action == .Walking || player.action == .Slashing {
						player.angle = player.target_angle
					}
				}

				prevent_overshoot := false
				new_velocity : Vector2

				// figure out velocity. 
				switch{
				case player.action == .KnockedBack:
					new_velocity = player.knockback
					knockback_decay :: 30.0
					if linalg.length(player.knockback) > 1 {
						player.knockback = linalg.lerp(player.knockback, Vector2{0, 0}, dt * knockback_decay)
					} else {
						player.action = .Nothing
					}
				case:
					prevent_overshoot = true

					player_to_target := player.target_pos - player.pos
					move_speed : f32

					if linalg.length(player_to_target) > 5 {
						#partial switch player.action {
						case .Slashing:
							move_speed = SLASH_SPEED * SLASH_MULTIPLIER
						case .Walking:
							move_speed = WALK_SPEED
						}
					} 

					new_velocity = unit_circle(player.angle) * move_speed
				}

				// apply velocity
				{
					// Other systems might also care about it, so we save it on the player
					player.velocity = new_velocity

					player.prev_position = player.pos
					target_to_player := player.pos - player.target_pos

					new_pos : Vector2
					found_pos := false

					
					for divisor := 1; divisor <= 8; divisor *= 2 {
						new_pos = player.pos + player.velocity * dt / f32(divisor)
						hits := query_colliders_intersecting_hitbox(
							&state.physics,
							hitbox_from_pos_size(new_pos, player.hitbox_size),
							1,
							LAYER_MASK_OBSTRUCTION,
						)

						if len(hits) == 0 {
							found_pos = true
							break;
						}
					}

					if found_pos {
						// prevent overshooting the target
						player.pos = new_pos
						if was_overshoot(player.target_pos, player.prev_position, player.pos) {
							player.pos = player.target_pos
						}
					} else {
						// TODO: make sure the player cant get stuck in stuff, push the player out.
						// TODO: use racyasting to find a beter position instead of just not assigning the position
					}
				}

				if player.action == .Slashing {
					// apply damage instantly.
					damage_ray := ray_from_start_end(player.prev_position, player.pos)
					damage_enemies(state, damage_ray)

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
					player.slash_points[player.slash_points_idx] = { pos=player.pos,slash_timer=player.slash_timer }
				} else {

					player_can_take_damage := false
					if player.action == .Nothing || player.action == .Walking  {
						player_can_take_damage = true
					}

					// Recieve damage. It's more efficient to do it here since there is just one player, so fewer physisc queries

					if player_can_take_damage {
						hits := query_colliders_intersecting_hitbox(
							&state.physics,
							hitbox_from_pos_size(player.pos, player.hitbox_size),
							16,
							LAYER_MASK_DAMAGE
						)

						for &hit in hits {
							#partial switch EntityType(hit.type) {
							case .Enemy:
								enemy, ok := hm.get(&state.enemies, hit.handle)
								if !ok {continue}
								if !enemy.can_damage_player {continue}

								enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)

								if enemy.damage_player_cooldown > 0.0001 {
									enemy.damage_player_cooldown -= 10 * dt
									continue
								} 

								if player.action == .KnockedBack {
									// Continue knocking the plaer back. This way, the player won't get stuck in crowds
									player.knockback = KNOCKBACK_MAGNITUDE * linalg.normalize0(player.knockback)
									player.action    = .KnockedBack
								} else {
									// Damage the player
									enemy.damage_player_cooldown = 1
									player.knockback = KNOCKBACK_MAGNITUDE * linalg.normalize0(player.pos - enemy.pos)
									player.action    = .KnockedBack

									player_damage += 10;
								}
							case:
								fmt.assertf(false, "unhanled damage source")
							}
						}
					}
				}

				// Player sprite animation
				sink : f32 = 0
				step_character_animation(
					state,
					unscaled_dt,
					&player.animation,
					player.velocity,
					player_is_alive,
					player.action == .Slashing,
					&sink,
				)
			}

			// Slash can't be infinite, the player is too OP and there is no sense of speed/urgency
			if player.action == .Slashing {
				player.slash_timer += unscaled_dt
				if player.slash_timer > SLASH_LIMIT {
					player.slash_timer = 0
					player.action      = .Nothing
				}
			}

			// Move player map
			{
				// not using map_camera_target.zoom xd
				target := player.map_camera_target.pos
				to_target := linalg.normalize0(target - player.map_camera.pos)
				prev_pos := player.map_camera.pos
				player.map_camera.pos += to_target * 10000 * unscaled_dt
				if was_overshoot(target, prev_pos, player.map_camera.pos) {
					player.map_camera.pos = target
				}
			}

			// Figure out which decorations need to be a bit transparent
			{
				hits := query_colliders_intersecting_hitbox(
					&state.physics,
					hitbox_from_pos_size(player.pos, player.hitbox_size),
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
			color := Color{0,0,0, u8(player.opacity * 255)}

			if DEBUG_LINES {
				draw_line(state, player.pos, player.pos + player.velocity * 3, 2,  {255, 0, 0, 255});
			}

			switch player.action {
			case .Nothing:  
				// Nothing. yet
			case .Slashing:
				// Draw trail
				// The thickness of the train is supposed to convey how much time you have left, 
				// but I'm not sure how good of a job it's actually doing ...
				for i in 1..<player.slash_points_len {
					slash_point_prev := player.slash_points[(player.slash_points_idx + 1 + i - 1) % player.slash_points_len]
					slash_point      := player.slash_points[(player.slash_points_idx + i + 1) % player.slash_points_len]
					t := 2 * slash_point.slash_timer / (SLASH_LIMIT)
					if t > 1 {
						t = f32(1.0) - (t - 1)
					}
					line_thickness := player.size * 0.2 * t
					draw_line(state, slash_point_prev.pos, slash_point.pos, line_thickness, color);
				}
			case .Walking:  
				// Nothing. yet
			case .KnockedBack:
				color.r = u8(lerp(255, 0, linalg.length(player.knockback) / KNOCKBACK_MAGNITUDE))
			}

			render_character_sprite(
				state,
				player.pos, player.size, color,
				player.animation, player.velocity,
				.Stickman,
			)

			// Crosshair for aiming
			crosshair_distance :: 300
			// crosshair_pos := player.pos + unit_circle(player.target_angle) * crosshair_distance
			crosshair_pos := player.target_pos
			draw_crosshairs(state, crosshair_pos, 50 / state.camera.zoom, 4 / state.camera.zoom, {0,0,0,255})

			if DEBUG_LINES {
				draw_rect(state, player.pos, player.hitbox_size, COL_DEBUG, .Solid)
			}

			if player.interaction != nil {
				if enemy, ok := hm.get(&state.enemies, player.interaction.handle); ok {
					pos  := to_screen_uipos(state, enemy.pos + {0, -enemy.size / 2 })
					text := text_column_make(pos, 30, 5, CENTER_ALIGN)
					draw_text_row_screenspace(&text, "[X] interact")
				}
			}
		}
	}

	// Enemies
	{
		if phase == .Render {
			render_enemy :: proc(state: ^GameState, enemy: ^Enemy) {
				player := &state.player;
				normal_color := enemy.color
				hit_color    := Color{ 255, 0, 0, 255}
				dead_color   := Color{125,125,125,255}

				if enemy.health <= 0 {
					normal_color = dead_color
				}
				color := rl.ColorLerp(normal_color, hit_color, enemy.hit_cooldown)

				debug_log("rendering enemy fr, %v", enemy.pos)
				render_character_sprite(
					state,
					enemy.pos, enemy.size, color,
					enemy.animation, enemy.target_pos - enemy.pos, 
					enemy.type,
				)

				if DEBUG_LINES {
					draw_rect(state, enemy.pos, enemy.hitbox_size, COL_DEBUG, .Solid)
				}
			}

			// Draw dead enemies under alive ones
			it := hm.iterator_make(&state.enemies);
			for enemy, handle in hm.iterate(&it) {
				if enemy.health <= 0 {continue}
				render_enemy(state, enemy)
			}
			it = hm.iterator_make(&state.enemies);
			for enemy, handle in hm.iterate(&it) {
				if enemy.health > 0 {continue}
				render_enemy(state, enemy)
			}
		}

		if phase == .Update {
			update_enemies(state, dt)
		}
	}

	// Draw decorations that sit above the player
	if phase == .Render {
		it := get_chunk_iter(state, bottom_left, top_right)
		for chunk, coord in iter_chunks(&it) {
			chunk_pos := chunk_coord_to_pos(coord)

			for &decoration, idx in chunk.decorations {
				col := COL_WHITE
				id := get_chunk_decoration_id(chunk, idx)
				if slice.contains(state.transparent_decor[:], i32(idx)) {
					col.a = 125
				}

				draw_decoration(state, decoration.type, chunk_pos + decoration.pos, decoration.size, col)
			}	
		}
	}

	// Draw camera lock, or map origin
	if phase == .Render {
		draw_crosshair := false
		if player.camera_lock {
			crosshair_pos := player.camera_lock_pos
			draw_crosshairs(state, crosshair_pos, 50 / state.camera.zoom, 4 / state.camera.zoom, {255,0,0,255})
		} else if player.viewing_map {
			crosshair_pos := player.map_camera.pos
			draw_crosshairs(state, crosshair_pos, 50 / state.camera.zoom, 4 / state.camera.zoom, {255,0,0,255})
		}
	}

	// camera
	if phase == .Update {
		target_camera : Camera2D 
		if player.viewing_map {
			target_camera = player.map_camera
		} else {
			target_camera = get_player_camera(player)

			if IS_DEBUGGING_LOADING_UNLOADING {
				target_camera.zoom /= 3
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
			unscaled_dt * camera_pos_speed,
			unscaled_dt * camera_zoom_speed
		)
	}

	// Dialog
	{
		dialog := &state.ui.npc_dialog

		if enemy, ok := hm.get(&state.enemies, dialog.entity); ok {
			text := dialog.text
			talking_speed   := f32(50)
			dialog_duration := f32(len(text)) + 1 * talking_speed

			if phase == .Update {
				if dialog.text_idxf < dialog_duration {
					dialog.text_idxf += talking_speed * dt
				}
			}

			if phase == .Render {
				if dialog.text_idxf < dialog_duration {
					up_to      := math.min(int(dialog.text_idxf), len(text))
					text_slice := text[:up_to]

					pos := enemy.pos
					offset := Vector2{enemy.size, enemy.size} / 2
					draw_line(state, pos + offset, pos + 2 * offset, 10 / state.camera.zoom, COL_FG)

					text := text_column_make(to_screen_uipos(state, pos + 3 * offset), 30, 10, CENTER_ALIGN)
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

			center := Vector2{
				state.window_size.x / 2,
				2 * state.window_size.y / 3,
			}
			size : UiLength = 100

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
			color = is_chosen ? Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
			resurrect_choice := current_choice

			// Selector
			if is_chosen {
				render_selector(x, y, size, color)
			}
			x += selector_size

			// Resurrect button
			{
				rl.DrawText(resurrect_text.text, x, y, size, color)
				x += resurrect_text.width
			}

			current_choice += 1
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
			quit_choice := current_choice
			
			// Selector
			if is_chosen {
				render_selector(x, y, size, color)
			}
			x += selector_size

			// Quit button
			{
				rl.DrawText(quit_text.text, x, y, size, color)
				x += quit_text.width
			}

			// Dont want to accidentally choose when slashing
			if has_submit_input {
				switch {
				case state.ui.resurrect_or_quit.idx == resurrect_choice:
					state.stats.deaths += 1
					player := &state.player
					player.health = INITIAL_PLAYER_HEALTH
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
			text := text_column_make({ 10, 10 }, 30, 10)

			// TODO: proper health bar
			draw_text_row_screenspace(&text, "health: %v", player.health)
			draw_text_row_screenspace(&text, "action: %v", player.action)

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
				draw_text_row_screenspace(&text, "enemies: %v", hm.len(state.enemies))
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
			player.health -= player_damage

			if player.health <= 0 {
				// Gotta do something. I don't know what yet
			}
		}

		// Kill off any dead enemies
		it := hm.iterator_make(&state.enemies);
		for enemy, handle in hm.iterate(&it) {
			if enemy.dead_duration > 3 {
				hm.remove(&state.enemies, handle)
			}
		}
	}

	when DEV_TOOLS_ENABLED {
		run_devtools(state, &global_devtools, phase)
	}
}

render_selector :: proc(x, y, size: c.int, color: Color) {
	selector_center := Vector2i32{ x + size / 2, y + size / 2 }
	selector_inner_size := c.int(size / 2)
	x := selector_center.x - selector_inner_size / 2
	y := selector_center.y - selector_inner_size / 2
	rl.DrawRectangle(x, y, selector_inner_size, selector_inner_size, color)
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
	pos: Vector2, size: f32, color: Color,
	animation: AnimationState, direction: Vector2,
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

	draw_rect_textured_spritesheet(state, pos, size, color, state.assets.chacracters, {sprite_idx, y}, angle + QUARTER_TURN)
}

step_spritesheet :: proc(sequence: []int, anim: ^AnimationState, interval: f32, dt: f32) -> int {
	anim.timer += dt
	if anim.timer > interval {
		anim.timer = 0
		anim.idx += 1
		if anim.idx >= len(sequence) {
			anim.idx = 0
		}
	}

	return sequence[anim.idx]
}

step_character_animation :: proc(
	state: ^GameState,
	dt: f32,
	anim: ^AnimationState,
	dir: Vector2,
	is_alive: bool,
	is_slashing: bool,
	dead_time: ^f32
) {
	input := linalg.length(dir)

	prev_phase := anim.phase

	switch {
	case !is_alive: 
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
		speed := 10 * dt
		if input < 0.001 && idx == 0 {
			speed = 0
		}
		step_spritesheet(PLAYER_WALKING_SEQUENCE[:], anim, 1, speed)
	case .Death:
		speed := 4 * dt
		if anim.idx < len(PLAYER_DEATH_SEQUENCE) - 1 {
			step_spritesheet(PLAYER_DEATH_SEQUENCE[:], anim, 1, speed)
		} else {
			dead_time^ += dt
		}
	case .Slashing:
		if anim.idx < len(SLASHING_SEQUENCE) - 1 {
			speed := 4 * dt
			step_spritesheet(SLASHING_SEQUENCE[:], anim, 1, speed)
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
		rl.ClearBackground(COL_WATER)

		// Run physics updates with a fixed timestep. This means that
		// a) our physics will be deterministic (on the same machine, anyway), which is awesome
		// b) I can do x = lerp(x, a, b) and it's totally fine
		time := rl.GetTime()
		dt := time - state.time
		state.time_since_physics_update += f32(dt)
		state.time = time
		for state.time_since_physics_update > state.physics_dt {
			state.time_since_physics_update -= state.physics_dt
			render_current_view(state, .Update)
		}

		render_current_view(state, .Render)
	} rl.EndDrawing();

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

set_player_target_angle :: proc(player: ^Player, angle: f32) {
	player.target_angle = normalize_angle(angle)
}

draw_crosshairs :: proc(state: ^GameState, pos: Vector2, size: f32, thickness: f32, color: Color) {
	draw_line(state, pos - {size, 0}, pos + {size, 0}, thickness, color)
	draw_line(state, pos - {0, size}, pos + {0, size}, thickness, color)
}

damage_enemies :: proc(state: ^GameState, damage_ray: Ray) {
	hits := query_colliders_intersecting_ray(
		&state.physics,
		damage_ray,
		limit=1_000_000,
		mask=LAYER_MASK_ENEMY,
	)

	player := &state.player

	for &item in hits {
		assert(EntityType(item.type) == .Enemy)

		enemy, ok := hm.get(&state.enemies, item.handle);
		if !ok {continue}

		if enemy.hit_cooldown > 0 {continue}
		if enemy.health <= 0      {continue}
		if !enemy.can_damage_player {continue} // Correspondingly, we can't damage enemies that can't damage us.

		enemy.health -= PLAYER_TO_ENEMY_DAMAGE
		enemy.hit_cooldown = 1	

		player.angle = get_angle_vec(player.target_pos - player.pos)

		// On the fence about regenerating the slash when we hit stuff. I think its too OP.
		if player.action == .Slashing {
			player.slash_timer = 0
		}
	}
}

move_angle_towards :: proc(current, target, delta: f32) -> f32 {
	return current + math.clamp(
		math.angle_diff(current, target),
		-delta,
		delta
	)
}

new_game_state :: proc(allocator := context.allocator) -> ^GameState {
	state := new(GameState, allocator)

	load_spritesheet :: proc(bytes: []u8, sprite_size: int, padding : int = 0) -> Spritesheet {
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

	assets.chacracters = load_spritesheet(#load("./assets/sprite1.png"),     32, 1)
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
			{ grid_size = 300 },
			{ grid_size = CHUNK_WORLD_WIDTH },
		}
		state.entity_grid      = &state.grids_backing_store[0]
		state.large_items_grid = &state.grids_backing_store[1]
		state.physics.grids = state.grids_backing_store[:]
	}

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

draw_decoration :: proc(state: ^GameState, type: DecorationType, pos: Vector2, size: f32, col: Color) {
	draw_rect_textured_spritesheet(
		state, pos,
		size = {size, size},
		col = col,
		spritesheet = state.assets.decorations,
		sprite_coordinate = DECORATION_TYPES[type].spritesheet_coord,
	)
}


add_enemy_at_position :: proc(state: ^GameState, type: CharacterType, pos: Vector2) -> ^Enemy {
	size := f32(100)

	hitbox_size_sprite := CHARACTER_TYPES[type].hitbox_size
	hitbox_side_length := f32(hitbox_size_sprite / f32(state.assets.chacracters.sprite_size)) * size

	enemy := Enemy {
		type        = type,
		pos         = pos,
		target_pos  = pos + { 0, -1 }, // look down
		size        = 100,
		health      = 10,
		hitbox_size = Vector2{hitbox_side_length, hitbox_side_length},
		color       = COL_WHITE
	}

	handle, _ := hm.add(&state.enemies, enemy)
	return hm.get(&state.enemies, handle)
}

// Should not be affected by switching to the map view, for example.
// We use this to correctly load and unload physics entities and proximity triggers based on the player's view.
get_player_camera :: proc(player: ^Player) -> (result: Camera2D) {
	if player.camera_lock {
		result.pos = player.camera_lock_pos
	} else {
		result.pos = player.pos
	}

	result.zoom = f32(PLAYER_CAMERA_ZOOM)

	return
}


ProcessTriggerType :: enum {
	Load,
	Unload,
}

process_load_event :: proc(state: ^GameState, chunk: ChunkCoordPair, trigger: LoadEvent, action: ProcessTriggerType) {
	trigger_pos := chunk_coord_to_pos(chunk.coord) + trigger.pos

	debug_log("proximity trigger, %v, %v, %v", chunk.coord, trigger, action)

	switch action {
	case .Load:
		trigger.load(state, trigger)
	case .Unload:
		trigger.unload(state, trigger)
	}
}


draw_debug_hitbox :: proc(state: ^GameState, hitbox: Hitbox, col := COL_DEBUG) {
	pos := hitbox_centroid(hitbox)
	size := Vector2{
		hitbox_width(hitbox),
		hitbox_height(hitbox),
	}
	draw_rect(state, pos, size, col, .Solid)
}


update_enemies :: proc(state: ^GameState, dt: f32) {
	it := hm.iterator_make(&state.enemies)
	for enemy, handle in hm.iterate(&it) {
		player := &state.player;
		player_is_alive := state.player.health > 0

		if enemy.hit_cooldown > 0 {
			enemy.hit_cooldown -= 5 * dt
		}

		enemy_is_alive := enemy.health > 0

		if player_is_alive && enemy_is_alive {
			if enemy.move_speed > 0 {
				// Move towards the player
				// (But they need to not bump into each other tho you know what im sayin)

				enemy.prev_pos = enemy.pos
				wanted_target := estimate_decent_intercept_point(enemy.pos, enemy.move_speed, player.pos, player.velocity, dt)
				responsiveness :: 2
				enemy.target_pos = linalg.lerp(enemy.target_pos, wanted_target, dt * responsiveness)

				if DEBUG_LINES {
					draw_rect(state, enemy.target_pos, {100, 100}, {255, 0,0,255}, .Outline)
				}

				to_target := linalg.normalize0(enemy.target_pos - enemy.pos)

				directions_to_try := [?]Vector2{
					Vector2{to_target.x, to_target.y},    // Towards to_target
					Vector2{-to_target.y, to_target.x},   // Perpendicular
					Vector2{to_target.y, -to_target.x},   // Other perpendicular
					-Vector2{to_target.x, to_target.y},   // Away from target
				}

				found_pos := false
				new_pos: Vector2

				for &dir in directions_to_try {
					new_pos = enemy.pos + enemy.move_speed * dir * dt

					hits := query_colliders_intersecting_hitbox(
						&state.physics,
						hitbox_from_pos_size(new_pos, enemy.hitbox_size),
						limit=10,
						mask=LAYER_MASK_OBSTRUCTION | LAYER_MASK_ENEMY
					)

					found := false
					for &hit in hits {
						if EntityType(hit.type) == .Enemy {
							if hit.handle == handle {continue}

							enemy, ok := hm.get(&state.enemies, hit.handle); 
							if !ok {continue}
						}

						found = true
						break;
					}

					if found {
						// we got [this enemy, some other enemy], so this space is occupied. pick another direction
						continue
					}

					found_pos = true
					break
				}

				if found_pos {
					enemy.pos = new_pos
				}
			} else {
				// Simply look down
				enemy.target_pos = enemy.pos + {0, -1}
			}
		}

		anim_dt := dt
		if enemy.move_speed == 0 {
			anim_dt = 0
		}

		step_character_animation(
			state,
			anim_dt,
			&enemy.animation,
			enemy.prev_pos - enemy.pos,
			enemy.health > 0,
			false,
			&enemy.dead_duration
		)
	}
}					

query_interactions :: proc(state: ^GameState, pos: Vector2) -> ^SparseGridItem {
	hits := query_colliders_intersecting_point(&state.physics, pos, mask = LAYER_MASK_INTERACTION)
	interacted := false
	for hit in hits {
		if EntityType(hit.type) == .Enemy {
			if enemy, ok := hm.get(&state.enemies, hit.handle); ok {
				return hit
			}
		}
	}

	return nil
}

set_current_entity_dialog :: proc(state: ^GameState, text: string, entity: Handle) {
	dialog := &state.ui.npc_dialog
	dialog.text      = text
	dialog.entity    = entity
	dialog.text_idxf = 0
}
