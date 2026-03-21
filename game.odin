package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib";

DASH_MULTIPLIER_MAX :: 10

PlayerActionState :: enum {
	Nothing,
	Slashing,
	Dashing,
}

Player :: struct {
	pos:  Vector2,
	size: Vector2,
	hit: bool,

	dash_start_pos:  Vector2,
	move_speed:      f32,
	dash_multiplier: f32,
	opacity:         f32,
	action:          PlayerActionState,
	direction_input: Vector2,
	target_direction_input: Vector2,
}

Enemy :: struct {
	pos: Vector2,
}

GameState :: struct {
	player: Player,
	enemy: Enemy,

	window_size: Vector2,
	camera_pos: Vector2,
	camera_zoom: f32,

	physics_dt: f32,
	time_since_physics_update: f32,
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
		player.move_speed = 200
		player.size = {50, 100}
	}

	state.enemy.pos.x = -100
	state.physics_dt = 1.0 / 120.0
}

run_game :: proc(state: ^GameState) {
	// I want the rendering code and physics code to be adjacent, pretty much.
	// I also want the physics to be deterministic.
	physics_steps := 0
	physics_dt    := state.physics_dt

	state.time_since_physics_update += rl.GetFrameTime()
	for state.time_since_physics_update > state.physics_dt {
		state.time_since_physics_update -= state.physics_dt
		physics_steps += 1
	}

	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.ClearBackground({255, 255, 255, 255})

		target_camera_pos  := state.camera_pos
		target_camera_zoom := state.camera_zoom

		// handle game input
		{
			player := &state.player

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


		// enemy
		{
			enemy := state.enemy
			color := rl.Color{ 0, 0, 255, 255 }
			draw_rect(state, enemy.pos, {50, 100}, color)
		}


		// player
		{
			player := &state.player

			// update
			for _ in 0..<physics_steps {

				if linalg.length(player.direction_input) < 0.1 {
					player.direction_input = player.target_direction_input
				} else {
					responsiveness := f32(40)
					if player.action != .Nothing {
						responsiveness = 0
					}

					player.direction_input = linalg.lerp(player.direction_input, player.target_direction_input, responsiveness * physics_dt)
				}

				target_opacity := f32(1.0)
				if player.action == .Dashing {
					target_opacity = 0.0
				}

				move_speed := player.move_speed * player.dash_multiplier
				input_vector := player.direction_input
				input_vector_len := linalg.length(input_vector);
				velocity := input_vector * move_speed
				player.pos += velocity * physics_dt

				dash_decay :: 30.0
				player.dash_multiplier = math.lerp(player.dash_multiplier, 1, physics_dt * dash_decay)

				if player.dash_multiplier < 1.1 {
					player.action = .Nothing
				}

				target_camera_pos = player.pos;
				target_camera_zoom = math.lerp(f32(0.5), f32(0.5), input_vector_len)

				phase_speed :: 50
				player.opacity = math.lerp(player.opacity, target_opacity, physics_dt * phase_speed)


				// camera
				{
					camera_pos_speed :: 20.0
					state.camera_pos = linalg.lerp(state.camera_pos, target_camera_pos, physics_dt * camera_pos_speed)

					camera_zoom_speed :: 20.0
					state.camera_zoom = linalg.lerp(state.camera_zoom, target_camera_zoom, physics_dt * camera_zoom_speed)
				}
			}

			ray := ray_from_start_end({-100, 0}, {100, 0})
			draw_line(state, ray.start, ray.end, 4, {0,0,0,255})
			hitbox := hitbox_from_pos_size(player.pos, player.size)
			fmt.printfln("%v", hitbox)
			hit, pos := collide_ray_with_box(hitbox, ray)
			player.hit = hit
			if hit {
				draw_rect(state, pos, {10, 10}, {0, 255, 0, 255})
			}

			// render
			{
				color := rl.Color{0,0,0, u8(player.opacity * 255)}
				if player.hit {
					color.r = 255
				}

				if player.dash_multiplier > 1.1 {
					t := (player.dash_multiplier - 1) / (DASH_MULTIPLIER_MAX - 1)

					switch player.action {
					case .Nothing: 
					// Nothing. yet
					case .Slashing:
						draw_line(state, player.dash_start_pos, player.pos, t * 20,  color);
					case .Dashing:
					// Nothing. yet
					}
				}

				draw_rect(state, player.pos, player.size, color)
			}
		}
	} rl.EndDrawing();
}

