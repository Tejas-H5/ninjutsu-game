package main

import "core:c"
import "core:strings"
import "core:fmt"
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

update_physics :: proc(state: ^GameState) {
	dt := state.physics_dt

	target_camera_pos  := state.camera_pos
	target_camera_zoom := state.camera_zoom

	player := &state.player;
	player_hitbox := hitbox_from_pos_size(player.pos, player.size)
	input_vector := player.direction_input
	input_vector_len := linalg.length(input_vector);

	// Enemies
	{
		for &enemy, i in state.enemies {
			if i >= state.total_enemies {break}

			if enemy.hit_cooldown > 0    {enemy.hit_cooldown -= 5 * dt}

			if enemy.damage_player_cooldown > 0.0001 {
				enemy.damage_player_cooldown -= 10 * dt
			} else {
				enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.size)
				hit := collide_box_with_box(player_hitbox, enemy_hitbox)
				if hit {
					// Damage the player
					enemy.damage_player_cooldown = 1
					player.knockback = KNOCKBACK_MAGNITUDE * linalg.normalize0(player.pos - enemy.pos)
					player.action    = .KnockedBack
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
			velocity: Vector2

			if player.action == .KnockedBack {
				velocity = player.knockback
				knockback_decay :: 30.0
				if linalg.length(player.knockback) > 1 {
					player.knockback = linalg.lerp(player.knockback, Vector2{0, 0}, dt * knockback_decay)
				} else {
					player.action = .Nothing
				}
			} else {
				move_speed := player.move_speed * player.dash_multiplier
				velocity = input_vector * move_speed
			}

			player.prev_position = player.pos
			player.pos += velocity * dt

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

render_frame :: proc(state: ^GameState) {
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
		player := state.player

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
}


run_game :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.ClearBackground({255, 255, 255, 255})

		player := &state.player

		// handle game input
		{

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

		// Debug text
		{
			y      : c.int = 10
			size   : c.int = 30
			offset : c.int = size + 10

			rl.DrawText(rl.TextFormat("action: %v", player.action), 10, y, size, {0, 0,0, 255})
			y += offset
			//
			// for e, i in state.enemies {
			// 	if i >= state.total_enemies {break}
			// 	rl.DrawText(rl.TextFormat("cooldown %v: %v", i, e.damage_player_cooldown), 10, y, size, {0, 0,0, 255})
			// 	y += offset
			// }
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
