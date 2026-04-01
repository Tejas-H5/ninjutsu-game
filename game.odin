package main

import "core:fmt"
import "core:c"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

import rl "vendor:raylib";

DASH_MULTIPLIER_MAX :: 1
DASH_MULTIPLIER_PULSE :: DASH_MULTIPLIER_MAX
DASH_DECAY :: 0
SLASH_MULTIPLIER_MAX :: 10
SLASH_DECAY :: 0
KNOCKBACK_MAGNITUDE :: 20000
INITIAL_PLAYER_HEALTH :: 100
PLAYER_DAMAGE :: 100
TIME_SLOWDOWN :: 10
MOVE_SPEED :: 2000

QUARTER_TURN :: math.PI / 2

PLAYER_WALKING_SEQUENCE := [?]int { 0, 1, 2, 1, 0, 3, 4, 3, }
PLAYER_DEATH_SEQUENCE   := [?]int { 5, 6, 7 }
SLASHING_SEQUENCE       := [?]int { 2 } // TODO: dedicated sprite?

ENEMIES :: true
ENEMY_STUCK_COOLDOWN :: 0.3
ENEMY_MOVE_SPEED_MIN :: 600
ENEMY_MOVE_SPEED_MAX :: 800

// Any more, and the game starts lagging like hell.
MAX_ENEMIES :: 3000

DEBUG_LINES :: false


PlayerActionState :: enum {
	Nothing,
	Slashing,
	Dashing,
	KnockedBack,
}

EntityType :: enum int {
	Player,
	Enemy,
}

Player :: struct {
	prev_position : Vector2,
	pos           :  Vector2,
	size          : f32,
	hitbox_size   : Vector2,
	health        : f32,
	velocity      : Vector2,

	target_dash_pos: Vector2,

	// ringbuffer, so that its not infinite.
	slash_points    : [4096]Vector2,
	slash_points_idx: int,
	slash_points_len: int,

	move_speed      : f32,
	target_pos      : Vector2,
	locked_on       : bool,
	dash_multiplier : f32,
	block_dash      : bool,
	block_slash     : bool,
	pulse_slash : bool,
	opacity         : f32,
	action          : PlayerActionState,

	knockback : Vector2,
	angle : f32,
	target_angle : f32,

	sprite: rl.Texture2D,
	animation: AnimationState,
}

AnimationPhase :: enum {
	Walking,
	Death,
	Slashing,
}

AnimationState :: struct {
	idx   : int,
	timer : f32,
	phase : AnimationPhase,
}

Enemy :: struct {
	pos                    : Vector2,
	size                   : f32,
	move_speed             : f32,
	hitbox_size            : Vector2,
	hit_cooldown           : f32,
	damage_player_cooldown : f32,
	velocity               : Vector2,
	health                 : f32,
	dead_duration          : f32,

	animation  : AnimationState,

	stuck : bool,
	stuck_cooldown : f32,
	stuck_dir : Vector2,
}

GameStateView :: enum {
	Start,
	Game,
}

GameState :: struct {
	player: Player,

	input: GameInput,

	stats: struct {
		deaths: int,
	},

	enemies: [MAX_ENEMIES]Enemy,
	allocated_enemies: []Enemy,

	window_size: Vector2,
	camera_pos: Vector2,
	camera_zoom: f32,

	physics_dt: f32,
	physics: SparsePyramid,
	grids: [1]SparseGrid,

	time: f64,
	time_since_physics_update: f32,

	ui: struct {
		resurrect_or_quit: struct {
			idx: int,
			got_axis: bool,
		},
	},

	requested_quit: bool,

	view: GameStateView,
	previous_view: GameStateView,
}

GameInput :: struct {
	slash     : bool,
	dash      : bool,
	direction : Vector2,
	screen_position : Vector2,
	submit    : bool,
	cancel    : bool
}

add_enemy :: proc(state: ^GameState, enemy: Enemy) -> ^Enemy {
	idx := len(state.allocated_enemies)
	if len(state.enemies) == idx {return nil}

	state.enemies[idx] = enemy
	state.allocated_enemies = state.enemies[0: idx + 1]
	return &state.enemies[idx]
}

get_direction_input :: proc() -> Vector2 {
	x: f32 = 0
	if rl.IsKeyDown(.LEFT) {
		x = -1
	} else if rl.IsKeyDown(.RIGHT) {
		x = +1
	}

	y: f32 = 0
	if rl.IsKeyDown(.DOWN) {
		y = -1
	} else if rl.IsKeyDown(.UP) {
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

lerp :: proc(a, b, t: f32) -> f32 {
	if t < 0 {return a}
	if t > 1 {return b}
	return math.lerp(a, b, t)
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
	size : UiSize = 100

	if phase == .Render {
		center := state.window_size / 2

		start_text := ui_text(fmt.ctprintf("Start"), size)
		width := start_text.width + size
		color := rl.Color{ 255, 0, 0, 255 }

		x := c.int(center.x) - width / 2
		y := c.int(center.y) - start_text.height / 2

		render_selector(x, y, size, color)
		x += size

		rl.DrawText(start_text.text, x, y, size, color)

		if state.input.submit {
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
	input_dt := state.physics_dt
	if player_was_slashing {
		update_dt = state.physics_dt / TIME_SLOWDOWN
	}
	dt := f32(0)
	if phase == .Update {
		dt = update_dt
	}

	// Most input processing has to happen every _frame_ in the render phase instead of every physics update.
	if phase == .Render {
		// Populate solely from input devices
		{
			state.input.slash     = rl.IsKeyDown(.Z)
			state.input.dash      = rl.IsKeyDown(.X)
			state.input.cancel    = rl.IsKeyPressed(.ESCAPE)
			state.input.submit    = rl.IsKeyPressed(.ENTER)

			state.input.direction = get_direction_input()
			state.input.screen_position = rl.GetMousePosition()
		}

		// handle input
		if player_is_alive {
			// No cooldowns. This is because:
			// - performing a dash/slash is already a bit tiring
			// - dashing makes the player invisible, which also makes it hard for you to know where you are
			// - dashing makes the player move much faster, which is not always ideal
			// So because they both have natural tradeoffs already, we dont need to make it feel any worse
			slash_input, dash_input := state.input.slash, state.input.dash

			if !dash_input {
				player.block_dash = false
			} 
			if !slash_input {
				player.block_slash = false
			}

			if player.action != .KnockedBack {
				prev_action := player.action

				player.target_dash_pos = to_game_pos(state, state.input.screen_position)

				if dash_input && !player.block_dash {
					if player.action == .Nothing {
						player.action = .Dashing
						player.dash_multiplier = DASH_MULTIPLIER_MAX
					} else if player.action == .Slashing {
						player.dash_multiplier = math.min(player.dash_multiplier + 1, DASH_MULTIPLIER_PULSE)
						player.block_dash = false
						player.pulse_slash = true
					}
				}

				if slash_input {
					if prev_action == .Nothing && !player.block_slash {
						player.dash_multiplier = SLASH_MULTIPLIER_MAX
						player.slash_points_idx = 0
						player.slash_points_len = 1
						player.slash_points[0] = player.pos
						player.action = .Slashing
						player.block_slash = true
					}
				} 

				if !slash_input && !dash_input {
					player.action          = .Nothing
					player.dash_multiplier = 0
				}
			}
		}
	}

	target_camera_pos  := state.camera_pos
	target_camera_zoom := state.camera_zoom

	player_damage := f32(0)

	has_submit_input := state.input.submit

	// Physics world setup
	if phase == .Update {
		sparse_pyramid_reset(&state.physics)

		hitbox := hitbox_from_pos_size(player.pos, player.hitbox_size)
		sparse_pyramid_add(&state.physics, { box=hitbox, type=int(EntityType.Player), idx=0 })

		if ENEMIES {
			for &enemy, idx in state.allocated_enemies {
				hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)
				sparse_pyramid_add(&state.physics, { box=hitbox, type=int(EntityType.Enemy), idx=idx })
			}
		}

		if !logged {
			logged = true
			log_sparse_pyramid(&state.physics)
		}
	}

	// player
	{
		if phase == .Update {
			target_opacity := f32(1.0)
			if player.action == .Dashing {
				target_opacity = 0.0
			}

			phase_speed :: 100
			player.opacity = 1//lerp(player.opacity, target_opacity, dt * phase_speed)

			// Player Movement
			{
				if state.input.direction != 0 {
					// rotate_speed :: 20
					// set_player_target_angle(
					// 	player,
					// 	move_angle_towards(
					// 		player.angle, 
					// 		math.atan2(state.input.direction.y, state.input.direction.x),
					// 		rotate_speed * input_dt
					// 	)
					// )
					// set_player_target_angle(player, player.target_angle - rotate_speed * state.input.direction.x * input_dt)
				}


				target_pos_exact := to_game_pos(state, state.input.screen_position)

				// Target the closest enemy 
				{
					hits := query_colliders_intersecting_hitbox(
						&state.physics,
						hitbox_from_pos_size(target_pos_exact, 500),
						limit=100,
						ignore_type=int(EntityType.Player),
					)

					if len(hits) > 0 {
						min_dist := f32(2000000)
						for &item in hits {
							assert(item.type == int(EntityType.Enemy))
							enemy := &state.allocated_enemies[item.idx]
							if enemy.health <= 0 { continue }

							center := hitbox_centroid(item.box)
							dist := linalg.length(center - target_pos_exact)
							if dist < min_dist {
								min_dist = dist
								player.target_pos = center
								player.locked_on = true
							}
						}
					} else {
						player.target_pos = player.pos
						player.locked_on = false
					}
				}

				player_to_screen := player.target_pos - player.pos
				set_player_target_angle(player, math.atan2(player_to_screen.y, player_to_screen.x))

				player.move_speed = player.locked_on ? MOVE_SPEED : 0 // * math.min(linalg.length(player_to_screen), 300) / 300

				if player.action == .Nothing || player.action == .Dashing || player.action == .Slashing || player.pulse_slash {
					player.pulse_slash = false
					player.angle = player.target_angle
				}

				if player.action == .KnockedBack {
					player.velocity = player.knockback
					knockback_decay :: 30.0
					if linalg.length(player.knockback) > 1 {
						player.knockback = linalg.lerp(player.knockback, Vector2{0, 0}, dt * knockback_decay)
					} else {
						player.action = .Nothing
					}
				} else {
					// move_vector := unit_circle(player.angle) * state.input.direction.y
					dash_vector := unit_circle(player.angle) * player.dash_multiplier
					player.velocity = dash_vector * player.move_speed
				}

				if player.action == .Slashing {
					// push to ringbuffer
					{
						if player.slash_points_len < len(player.slash_points) {
							player.slash_points_idx += 1
							player.slash_points_len += 1
						} else {
							player.slash_points_idx += 1
							if player.slash_points_idx >= player.slash_points_len {
								player.slash_points_idx = 0
							}
						}
						player.slash_points[player.slash_points_idx] = player.pos
					}
				}

				player.prev_position = player.pos
				player.pos += player.velocity * dt

				if player.action == .Slashing {
					damage_ray := ray_from_start_end(player.prev_position, player.pos)
					damage_enemies(state, damage_ray)
				}

				// Player sprite animation
				sink : f32 = 0
				step_person_animation(
					state,
					&player.animation,
					player.velocity,
					player_is_alive,
					player.action == .Slashing,
					&sink,
				)
			}

			// Dash/Slash decay
			if player.action == .Slashing || player.action == .Dashing {
				#partial switch player.action {
				case .Slashing:
					player.dash_multiplier = lerp(player.dash_multiplier, 0, dt * SLASH_DECAY)
				case .Dashing:
					player.dash_multiplier = lerp(player.dash_multiplier, 0, dt * DASH_DECAY)
				}

				if player.dash_multiplier < 1.0 {
					player.action = .Nothing
				}
			}
		}

		if phase == .Render {
			color := rl.Color{0,0,0, u8(player.opacity * 255)}

			if DEBUG_LINES {
				draw_line(state, player.pos, player.pos + player.velocity * 3, 2,  {255, 0, 0, 255});
			}

			if player.locked_on {
				draw_rect(state, player.target_pos, 200, {255, 0,0, 255}, .Outline)
			}

			if player.dash_multiplier > 0.1 {

				#partial switch player.action {
				case .Slashing:
					for i in 1..<player.slash_points_len {
						prev_pos := player.slash_points[(player.slash_points_idx + 1 + i - 1) % player.slash_points_len]
						pos := player.slash_points[(player.slash_points_idx + i + 1) % player.slash_points_len]
						line_thickness := TIME_SLOWDOWN * linalg.length(prev_pos - pos) / (SLASH_MULTIPLIER_MAX)
						draw_line(state, prev_pos, pos, line_thickness, color);
					}
				case .Dashing:
				// Nothing, yet
				}
			}

			switch player.action {
			case .Nothing:  // Nothing. yet
			case .Slashing: // Nothing. yet
			case .Dashing:  // Nothing. yet
			case .KnockedBack:
				color.r = u8(lerp(255, 0, linalg.length(player.knockback) / KNOCKBACK_MAGNITUDE))
			}

			render_person_sprite(
				state,
				player.pos, player.size, color,
				player.animation, player.velocity, player.sprite
			)

			// Crosshair for aiming
			crosshair_distance :: 300
			// crosshair_pos := player.pos + unit_circle(player.target_angle) * crosshair_distance
			crosshair_pos := to_game_pos(state, state.input.screen_position)
			draw_crosshairs(state, crosshair_pos, 100, 4, {0,0,0,255})

			if DEBUG_LINES {
				draw_rect(state, player.pos, player.hitbox_size, color, .Outline)
			}
		}
	}

	// Slashing. Apply damage to enemies _before_ they apply damage to the player
	if phase == .Render || phase == .Update {
		// apply damage once we've completed the whole stroke. Like in the animes fr fr
		// Or not. Im thinking about it
		// if player_was_slashing && player.action == .Nothing {
		// 	for i in 1..<player.slash_points_len {
		// 		prev_pos := player.slash_points[(player.slash_points_idx + 1 + i - 1) % player.slash_points_len]
		// 		pos := player.slash_points[(player.slash_points_idx + i + 1) % player.slash_points_len]
		// 		ray := ray_from_start_end(prev_pos, pos)
		// 		damage_enemies(state, ray)
		// 	}
		// }
	}

	if ENEMIES {
		if phase == .Render {
			for &enemy in state.allocated_enemies {
				normal_color := rl.Color{ 0, 0, 255, 255}
				hit_color    := rl.Color{ 255, 0, 0, 255}
				color        := rl.ColorLerp(normal_color, hit_color, enemy.hit_cooldown)

				render_person_sprite(
					state,
					enemy.pos, enemy.size, color,
					enemy.animation, enemy.velocity, player.sprite,
				)

				if DEBUG_LINES {
					draw_rect(state, enemy.pos, enemy.hitbox_size, color, .Outline)
				}
			}
		}

		if phase == .Update {
			for &enemy, enemy_idx in state.allocated_enemies {
				if enemy.hit_cooldown > 0    {enemy.hit_cooldown -= 5 * dt}

				enemy_is_alive := enemy.health > 0

				prev_pos := enemy.pos

				if player_is_alive && enemy_is_alive {
					// Move towards the player
					// (But they need to not bump into each other tho you know what im sayin)
					{
						target := estimate_decent_intercept_point(enemy.pos, enemy.move_speed, player.pos, player.velocity, dt)

						if DEBUG_LINES {
							draw_rect(state, target, {100, 100}, {255, 0,0,255}, .Outline)
						}

						to_target := linalg.normalize0(target - enemy.pos)

						directions_to_try := [?]Vector2{
							Vector2{to_target.x, to_target.y},    // Towards to_target
							Vector2{-to_target.y, to_target.x},   // Perpendicular
							Vector2{to_target.y, -to_target.x},   // Other perpendicular
							-Vector2{to_target.x, to_target.y},   // Away from target
						}

						found_direction := false

						for dir in directions_to_try {
							new_pos := enemy.pos + enemy.move_speed * dir * dt

							// TODO: we need to speed up this part, its extremely slow
							hits := query_colliders_intersecting_hitbox(
								&state.physics,
								hitbox_from_pos_size(new_pos, enemy.hitbox_size),
								limit=2,
								ignore_type = int(EntityType.Player)
							)

							if len(hits) > 1 {
								// we got [this enemy, some other enemy], so this space is occupied. pick another direction
								continue
							}

							found_direction = true
							enemy.pos = new_pos
							break
						}

						if !found_direction {
							if !enemy.stuck {
								enemy.stuck = true
								enemy.stuck_dir = Vector2{ rand.float32_range(-1, 1), rand.float32_range(-1, 1) }
							}

							enemy.pos += enemy.move_speed * enemy.stuck_dir * dt
							enemy.stuck_cooldown = ENEMY_STUCK_COOLDOWN
						} else {
							if enemy.stuck_cooldown > 0 {
								enemy.stuck_cooldown -= dt
							} else {
								enemy.stuck = false
							}
						}
					}

					// Damage player
					{
						enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)

						if enemy.damage_player_cooldown > 0.0001 {
							enemy.damage_player_cooldown -= 10 * dt
						} else {
							// Player can phase through enemies when dashing. Some real ninja samurai type shit
							player_can_take_damage := player_is_alive && player.action == .Nothing || player.action == .Dashing 

							if player_can_take_damage || player.action == .KnockedBack {
								player_hitbox := hitbox_from_pos_size(player.pos, player.hitbox_size)
								hit := collide_box_with_box(player_hitbox, enemy_hitbox)
								if hit {
									if player.action == .KnockedBack {
										// Continue knocking the plaer back. This way, the player won't get stuck in crowds
										player.knockback = enemy.move_speed * 10 * linalg.normalize0(player.pos - enemy.pos)
										player.action    = .KnockedBack
									} else {
										// Damage the player
										enemy.damage_player_cooldown = 1
										player.knockback = KNOCKBACK_MAGNITUDE * linalg.normalize0(player.pos - enemy.pos)
										player.action    = .KnockedBack

										player_damage += 10;
									}
								}
							}
						}
					}
				}

				// Enemy sprite animation
				enemy.velocity = enemy.pos - prev_pos
				step_person_animation(
					state,
					&enemy.animation,
					enemy.velocity,
					enemy.health > 0,
					false,
					&enemy.dead_duration
				)
			}
		}
	}

	// camera
	if phase == .Update {
		target_camera_pos = player.pos;

		target_camera_zoom = 0.5
		if player.action == .Slashing {
			target_camera_zoom = 0.45
		}

		camera_pos_speed :: 20
		state.camera_pos = linalg.lerp(state.camera_pos, target_camera_pos, dt * camera_pos_speed)
		// state.camera_pos = target_camera_pos

		camera_zoom_speed :: 40.0
		state.camera_zoom = linalg.lerp(state.camera_zoom, target_camera_zoom, dt * camera_zoom_speed)
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
			size : UiSize = 100

			resurrect_text := ui_text(fmt.ctprintf("Resurrect"), size)
			quit_text := ui_text(fmt.ctprintf("Quit"), size)

			height := size
			selector_size := height
			width := resurrect_text.width + quit_text.width + selector_size + selector_size

			x := c.int(center.x) - width / 2
			y := c.int(center.y) - size / 2

			// Draw background
			{
				color := rl.Color{ 0, 0, 0, 100 }
				y := c.int(center.y) - height / 2
				rl.DrawRectangle(x, y, width, height, color)
			}

			color: rl.Color
			is_chosen: bool

			current_choice := 0
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? rl.Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
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
			color = is_chosen ? rl.Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
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

		// Debug text (TODO: rewrite)
		{
			y      : c.int = 10
			size   : c.int = 30
			offset : c.int = size + 10

			// TODO: proper health bar
			rl.DrawText(rl.TextFormat("health: %v", player.health), 10, y, size, {0, 0,0, 255})
			y += offset

			rl.DrawText(rl.TextFormat("action: %v", player.action), 10, y, size, {0, 0,0, 255})
			y += offset

			rl.DrawText(rl.TextFormat("items: %v", state.physics.grids[0].count), 10, y, size, {0, 0,0, 255})
			y += offset

			pos := to_game_pos(state, state.input.screen_position)
			rl.DrawText(rl.TextFormat("mouse: %v", pos), 10, y, size, {0, 0,0, 255})
			y += offset

			// for e, i in state.enemies {
			// 	if i >= state.total_enemies {break}
			// 	rl.DrawText(rl.TextFormat("cooldown %v: %v", i, e.damage_player_cooldown), 10, y, size, {0, 0,0, 255})
			// 	y += offset
			// }
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
		for i := 0; i < len(state.allocated_enemies); i += 1 {
			enemy := state.allocated_enemies[i]
			if enemy.dead_duration > 3 {
				unordered_remove_slice(&state.allocated_enemies, i)
				i -= 1;
			}
		}
	}
}

render_selector :: proc(x, y, size: c.int, color: rl.Color) {
	selector_center := Vector2i32{ x + size / 2, y + size / 2 }
	selector_inner_size := c.int(size / 2)
	x := selector_center.x - selector_inner_size / 2
	y := selector_center.y - selector_inner_size / 2
	rl.DrawRectangle(x, y, selector_inner_size, selector_inner_size, color)
}

render_current_view :: proc(state: ^GameState, phase: RenderPhase) {
	if state.previous_view != state.view {
		// Cleanup previous view
		switch state.previous_view {
		case .Start:
		case .Game:
		}

		// Initialize next view
		switch state.view {
		case .Start:
		case .Game:
			// NOTE: assumed we can never transition away from here, so no cleanup code is present yet

			g1_size := f32(0)

			player := &state.player; {
				player.size = 100
				player_hitbox_side := f32(13.0 / 32.0) * player.size
				player.hitbox_size = Vector2{player_hitbox_side, player_hitbox_side}
				player.health = INITIAL_PLAYER_HEALTH;
				player.sprite = rl.LoadTexture("./assets/sprite1.png")

				g1_size = math.ceil(max(g1_size, player_hitbox_side + 1))
			}


			// TODO: defer to wave system

			INITIAL_ENEMIES :: 200

			for i in 0..<INITIAL_ENEMIES {
				angle := rand.float32_range(0, 2 * math.PI)
				distance := rand.float32_range(1000, 5000)

				size := f32(100)
				hitbox_side_length := f32(13.0 / 32.0) * size
				g1_size = math.ceil(max(g1_size, hitbox_side_length + 1)) 

				add_enemy(state, Enemy{
					pos = player.pos + distance * unit_circle(angle),
					size = 100,
					health = 10,
					hitbox_size = Vector2{hitbox_side_length, hitbox_side_length},
					move_speed = rand.float32_range(ENEMY_MOVE_SPEED_MIN, ENEMY_MOVE_SPEED_MAX)
				})
			}

			// NOTE: leaking grids here. Needs handling later
			state.grids = [1]SparseGrid {
				{ grid_size = 2 * g1_size },
			}
			state.physics.grids = state.grids[:]
		}

		state.previous_view = state.view
	}

	// always render the game
	render_game(state, phase)

	if state.view == .Start {
		render_start_screen(state, phase)
	}
}

render_person_sprite :: proc(
	state: ^GameState,
	pos: Vector2, size: f32, color: rl.Color,
	animation: AnimationState, direction: Vector2, spritesheet: rl.Texture2D
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
	draw_rect_textured_spritesheet(state, pos, size, color, spritesheet, sprite_idx, angle + QUARTER_TURN)
}

run_game2 :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		state.camera_zoom = 1

		rl.ClearBackground({255, 255, 255, 255})
	} rl.EndDrawing();
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

step_person_animation :: proc(
	state: ^GameState,
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
		speed := 10 * state.physics_dt
		if input < 0.001 && idx == 0 {
			speed = 0
		}
		step_spritesheet(PLAYER_WALKING_SEQUENCE[:], anim, 1, speed)
	case .Death:
		speed := 4 * state.physics_dt
		if anim.idx < len(PLAYER_DEATH_SEQUENCE) - 1 {
			step_spritesheet(PLAYER_DEATH_SEQUENCE[:], anim, 1, speed)
		} else {
			dead_time^ += state.physics_dt
		}
	case .Slashing:
		if anim.idx < len(SLASHING_SEQUENCE) - 1 {
			speed := 4 * state.physics_dt
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
		rl.ClearBackground({255, 255, 255, 255})

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

set_player_target_angle :: proc(player: ^Player, angle: f32) {
	angle := angle
	if angle < 0 {
		angle += math.TAU
	} else if angle > math.TAU {
		angle -= math.TAU
	}
	player.target_angle = angle
}

draw_crosshairs :: proc(state: ^GameState, pos: Vector2, size: f32, thickness: f32, color: rl.Color) {
	draw_line(state, pos - {size, 0}, pos + {size, 0}, thickness, color)
	draw_line(state, pos - {0, size}, pos + {0, size}, thickness, color)
}


damage_enemies :: proc(state: ^GameState, damage_ray: Ray) {
	hits := query_colliders_intersecting_ray(
		&state.physics,
		damage_ray,
		limit=1_000_000,
		ignore_type=int(EntityType.Player)
	)

	for item in hits {
		assert(item.type == int(EntityType.Enemy))
		enemy := &state.allocated_enemies[item.idx]
		if enemy.hit_cooldown <= 0 {
			enemy.health -= PLAYER_DAMAGE
			enemy.hit_cooldown = 1
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
