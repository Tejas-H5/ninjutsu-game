package main

import "core:c"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib";

DASH_MULTIPLIER_MAX :: 10
KNOCKBACK_MAGNITUDE :: 10000

PlayerActionState :: enum {
	Nothing,
	Slashing,
	Dashing,
	KnockedBack,
}

Player :: struct {
	prev_position: Vector2,
	pos:  Vector2,
	size: Vector2,
	health: f32,
	velocity: Vector2,

	dash_start_pos:  Vector2,
	move_speed:      f32,
	dash_multiplier: f32,
	opacity:         f32,
	action:          PlayerActionState,

	knockback:              Vector2,
	direction_input:        Vector2,
	target_direction_input: Vector2,
}

Enemy :: struct {
	pos:          Vector2,
	size:         Vector2,
	hit_cooldown: f32,
	damage_player_cooldown: f32,
}

GameState :: struct {
	player: Player,

	enemies: [1000]Enemy,
	total_enemies: int,

	window_size: Vector2,
	camera_pos: Vector2,
	camera_zoom: f32,

	physics_dt: f32,
	time: f64,
	time_since_physics_update: f32,
}

add_enemy :: proc(state: ^GameState) -> ^Enemy {
	if len(state.enemies) == state.total_enemies {return nil}

	idx := state.total_enemies
	state.total_enemies += 1
	
	enemy := &state.enemies[idx]

	return enemy
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

init_game :: proc(state: ^GameState) {
	player := &state.player; {
		player.move_speed = 2000
		player.size = {50, 100}
		player.health = 100;
	}

	for i in 0..<10 {
		enemy := add_enemy(state)
		enemy^ = Enemy {
			pos  = {f32(i) * 200, 400},
			size = {50, 100},
		}
	}

	state.physics_dt = 1.0 / 120.0
	state.time = rl.GetTime()
}

estimate_decent_intercept_point :: proc(
	current_pos: Vector2, capable_speed: f32, 
	target_pos, target_vel: Vector2
) -> Vector2 {
	// Don't overthink it. for now
	return target_pos + 4 * target_vel
}

update_physics :: proc(state: ^GameState) {
	dt := state.physics_dt

	target_camera_pos  := state.camera_pos
	target_camera_zoom := state.camera_zoom

	player := &state.player;
	player_hitbox := hitbox_from_pos_size(player.pos, player.size)
	input_vector := player.direction_input
	input_vector_len := linalg.length(input_vector);

	player_damage := f32(0)
	player_is_alive := is_player_alive(state)

	// Enemies
	{
		enemy_move_speed :: 1100

		for &enemy, i in state.enemies {
			if i >= state.total_enemies {break}

			if enemy.hit_cooldown > 0    {enemy.hit_cooldown -= 5 * dt}

			if player_is_alive {
				// Move towards the player
				{
					target: Vector2

					to_player := linalg.normalize0(player.pos - enemy.pos)
					to_where_player_will_be := linalg.normalize0(
						estimate_decent_intercept_point(enemy.pos, enemy_move_speed, player.pos, player.velocity) - 
						enemy.pos
					)

					enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.size)

					target = to_where_player_will_be

					directions_to_try := [?]Vector2{
						Vector2{target.x, target.y},    // Towards target
						Vector2{-target.y, target.x},   // Perpendicular
						Vector2{target.y, -target.x},   // Other perpendicular
						-Vector2{target.x, target.y},   // Away from target
					}

					for dir in directions_to_try {
						prev_pos := enemy.pos
						enemy.pos += enemy_move_speed * dir * dt
						enemy_hitbox = hitbox_from_pos_size(enemy.pos, enemy.size)

						rolled_back := false

						// But they need to not bump into each other tho you know what im sayin
						for other_enemy, i_other in state.enemies {
							if i >= state.total_enemies {break}
							if i == i_other {continue}

							other_enemy_hitbox := hitbox_from_pos_size(other_enemy.pos, other_enemy.size)
							hit := collide_box_with_box(enemy_hitbox, other_enemy_hitbox) 
							if hit {
								// Space is occupied. roll back the change, recompute hitbox
								enemy.pos = prev_pos
								enemy.pos -= to_player * dt
								rolled_back = true
								break;
							}
						}

						if !rolled_back {break}
					}
				}

				// Damage player
				{
					enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.size)

					if enemy.damage_player_cooldown > 0.0001 {
						enemy.damage_player_cooldown -= 10 * dt
					} else {
						// Player can phase through enemies when dashing. Some real ninja samurai type shit
						if player.action != .Dashing {
							hit := collide_box_with_box(player_hitbox, enemy_hitbox)
							if hit {
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
	}

	// Player
	{
		// Allows for aiming, _and_ turning/stopping on a dime.
		if linalg.dot(player.direction_input, player.target_direction_input) < 0.5 {
			player.direction_input = player.target_direction_input
		} else {
			responsiveness := f32(20)
			if player.action != .Nothing {
				responsiveness = 0
			}

			player.direction_input = linalg.lerp(player.direction_input, player.target_direction_input, responsiveness * dt)
		}

		target_opacity := f32(1.0)
		if player.action == .Dashing {
			target_opacity = 0.0
		}

		phase_speed :: 100
		player.opacity = lerp(player.opacity, target_opacity, dt * phase_speed)

		// Player Movement
		{
			if player.action == .KnockedBack {
				player.velocity = player.knockback
				knockback_decay :: 30.0
				if linalg.length(player.knockback) > 1 {
					player.knockback = linalg.lerp(player.knockback, Vector2{0, 0}, dt * knockback_decay)
				} else {
					player.action = .Nothing
				}
			} else {
				move_speed := player.move_speed * player.dash_multiplier
				player.velocity = input_vector * move_speed
			}

			player.prev_position = player.pos
			player.pos += player.velocity * dt

			if player.action == .Slashing {
				// Damage enemies
				damage_ray := ray_from_start_end(player.prev_position, player.pos)

				for &enemy, i in state.enemies {
					if i >= state.total_enemies {break}

					if enemy.hit_cooldown <= 0 {
						hitbox := hitbox_from_pos_size(enemy.pos, enemy.size)
						hit, info := collide_ray_with_box(damage_ray, hitbox)
						if hit {
							enemy.hit_cooldown = 1
						}
					}
				}
			}
		}

		// Dash/Slash decay
		dash_decay :: 30.0
		player.dash_multiplier = lerp(player.dash_multiplier, 1, dt * dash_decay)
		if player.dash_multiplier < 1.1 {
			if player.action == .Dashing || player.action == .Slashing {
				player.action = .Nothing
			}
		}
	}

	if player_damage > 0 {
		player.health -= player_damage

		if player.health <= 0 {
			// Gotta do something. I don't know what yet
		}
	}

	// camera
	{
		target_camera_pos = player.pos;
		target_camera_zoom = lerp(f32(0.5), f32(0.45), input_vector_len)

		camera_pos_speed :: 20.0
		state.camera_pos = linalg.lerp(state.camera_pos, target_camera_pos, dt * camera_pos_speed)

		camera_zoom_speed :: 20.0
		state.camera_zoom = linalg.lerp(state.camera_zoom, target_camera_zoom, dt * camera_zoom_speed)
	}
}

lerp :: proc(a, b, t: f32) -> f32 {
	if t < 0 {return a}
	if t > 1 {return b}
	return math.lerp(a, b, t)
}

is_player_alive :: proc(state: ^GameState) -> bool {
	return false
	// return state.player.health > 0
}

render_frame :: proc(state: ^GameState) {
	player := state.player
	player_is_alive := is_player_alive(state)

	// enemies
	{
		for &enemy, i in state.enemies {
			if i >= state.total_enemies {break}

			color := rl.ColorLerp(
				rl.Color{ 0, 0, 255, 255},
				rl.Color{ 255, 0, 0, 255},
				enemy.hit_cooldown
			)
			draw_rect(state, enemy.pos, enemy.size, color)
		}
	}

	// player
	{
		color := rl.Color{0,0,0, u8(player.opacity * 255)}

		draw_line(state, player.pos, player.pos + player.direction_input * 400, 2,  {255, 0, 0, 255});

		if player.dash_multiplier > 1.1 {
			t := (player.dash_multiplier - 1) / (DASH_MULTIPLIER_MAX - 1)

			#partial switch player.action {
			case .Slashing:
				draw_line(state, player.dash_start_pos, player.pos, t * 20,  color);
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

		draw_rect(state, player.pos, player.size, color)
	}

	// UI
	ui_begin(state.window_size); {

		// Retry / Quit
		if !player_is_alive {
			button_size := f32(100)
			start, middle, end := ui_split(.Vertical, 0.5, button_size, 0.5)

			ui_begin_rect(middle); {
				button_font_size := button_size * 0.8

				// NOTE: code not ideal, we'll fix later

				resurrect_button_text := rl.TextFormat("Resurrect")
				resurrect_button_width := rl.MeasureText(resurrect_button_text, c.int(button_font_size))

				quit_button_text := rl.TextFormat("Quit")
				quit_button_width := rl.MeasureText(quit_button_text, c.int(button_font_size))

				selector_width := ui_get_rect_height()

				start, middle, end := ui_split(.Horizontal, 0.5, selector_width, 0.5)

				ui_begin_rect(middle); {


					ui_draw_rect(rl.Color{0, 0, 0, 255}, 4, rl.Color{255, 0, 0, 255})

				} ui_end_rect();
			} ui_end_rect();

			center := state.window_size / 2.0

			// Nahhh web is better here

			x    : c.int = c.int(center.x) - 100
			y    : c.int = c.int(center.y)
			size : c.int = c.int(state.window_size.y * 0.1)

			rl.DrawText("Resurrect", x, y, size, {0, 0,0, 255})

			x += 300

			rl.DrawText(rl.TextFormat("Quit", player.health), x, y, size, {0, 0,0, 255})
		}


		// Debug text
		{
			y      : c.int = 10
			size   : c.int = 30
			offset : c.int = size + 10

			// TODO: proper health bar
			rl.DrawText(rl.TextFormat("health: %v", player.health), 10, y, size, {0, 0,0, 255})
			y += offset

			rl.DrawText(rl.TextFormat("action: %v", player.action), 10, y, size, {0, 0,0, 255})
			y += offset

			//
			// for e, i in state.enemies {
			// 	if i >= state.total_enemies {break}
			// 	rl.DrawText(rl.TextFormat("cooldown %v: %v", i, e.damage_player_cooldown), 10, y, size, {0, 0,0, 255})
			// 	y += offset
			// }
		}
	} ui_end()
}


run_game :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.ClearBackground({255, 255, 255, 255})

		player := &state.player
		player_is_alive := is_player_alive(state)

		// handle game input
		if player_is_alive {
			player.target_direction_input = get_direction_input()
			has_direction_input := linalg.length(player.direction_input) > 0.5

			slash_input, dash_input := false, false
			if has_direction_input {
				// No cooldowns. This is because:
				// - performing a dash/slash is already a bit tiring
				// - dashing makes the player invisible, which also makes it hard for you to know where you are
				// - dashing makes the player move much faster, which is not always ideal

				slash_input = rl.IsKeyPressed(.X)
				dash_input  = rl.IsKeyPressed(.Z)
			}

			if player.action != .KnockedBack {
				if slash_input || dash_input {
					player.dash_multiplier = DASH_MULTIPLIER_MAX
					player.dash_start_pos = player.pos
				}
				if slash_input {
					player.action = .Slashing
				}
				if dash_input {
					player.action = .Dashing
				}
			}
		}

		time := rl.GetTime()
		dt := time - state.time
		state.time_since_physics_update += f32(dt)
		state.time = time
		for state.time_since_physics_update > state.physics_dt {
			state.time_since_physics_update -= state.physics_dt
			update_physics(state)
		}

		render_frame(state);
	} rl.EndDrawing();

	free_all(context.temp_allocator)
}
