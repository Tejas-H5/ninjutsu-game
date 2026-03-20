package main

import "core:fmt"
import "core:log"
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
	pos:             rl.Vector2,
	dash_start_pos:  rl.Vector2,
	move_speed:      f32,
	dash_multiplier: f32,
	opacity:         f32,
	action:          PlayerActionState,
}

Enemy :: struct {
	pos: rl.Vector2,
}

GameState :: struct {
	player: Player,
	enemy: Enemy,

	window_size: rl.Vector2,
	fixed_dt: f32,
	camera_pos: rl.Vector2,
	camera_zoom: f32,
}

to_screen_pos :: proc(state: GameState, pos: rl.Vector2) -> rl.Vector2 {
	screen_pos := (pos - state.camera_pos) * state.camera_zoom

	x := screen_pos.x
	y := -screen_pos.y
	offset := state.window_size / 2

	return { x, y } + offset;
}

to_screen_size :: proc(state: GameState, pos: rl.Vector2) -> rl.Vector2 {
	return pos * state.camera_zoom
}

draw_rect :: proc (state: GameState, pos: rl.Vector2, size: rl.Vector2, col: rl.Color) {
	bottom_left := to_screen_pos(state, pos) - to_screen_size(state, size / 2.0)
	screen_size := to_screen_size(state, size)
	rl.DrawRectangleV(bottom_left, screen_size, col)
}

draw_player :: proc (state: GameState) {
	player := state.player
	color := rl.Color{ 0, 0, 0, u8(player.opacity * 255) }

	if player.dash_multiplier > 1.1 {
		t := (player.dash_multiplier - 1) / (DASH_MULTIPLIER_MAX - 1)

		switch player.action {
		case .Nothing: 
			// Nothing. yet
		case .Slashing:
			rl.DrawLineEx(
				to_screen_pos(state, player.dash_start_pos),
				to_screen_pos(state, player.pos),
				t * 20,
				{0, 0, 0, 255}
			)
		case .Dashing:
			// Nothing. yet
		}
	}

	draw_rect(state, player.pos, {50, 100}, color)
}

draw_enemy :: proc (state: GameState, enemy: Enemy) {
	enemy := state.enemy
	color := rl.Color{ 0, 0, 255, 255 }
	draw_rect(state, enemy.pos, {50, 100}, color)
}

get_direction_input :: proc() -> rl.Vector2 {
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

	return { x, y }
}

get_direction_input_normalized :: proc() -> rl.Vector2 {
	dir := get_direction_input()
	return linalg.normalize0(dir)
}

update_game :: proc(state: ^GameState) {
	dt := state.fixed_dt

	target_camera_pos  := state.camera_pos
	target_camera_zoom := state.camera_zoom

	move_speed := 0

	player := &state.player; {
		target_opacity := f32(1.0)
		if player.action == .Dashing {
			target_opacity = 0.0
		}

		move_speed := player.move_speed * player.dash_multiplier
		input_vector := get_direction_input_normalized()
		input_vector_len := linalg.length(input_vector);
		velocity := input_vector * move_speed
		player.pos += velocity * dt

		dash_decay :: 30.0
		player.dash_multiplier = math.lerp(player.dash_multiplier, 1, dt * dash_decay)

		if player.dash_multiplier < 1.1 {
			player.action = .Nothing
		}

		target_camera_pos = player.pos;
		target_camera_zoom = math.lerp(f32(1.0), f32(0.5), input_vector_len)

		phase_speed :: 50
		player.opacity = math.lerp(player.opacity, target_opacity, dt * phase_speed)
	}

	camera_pos_speed :: 20.0
	state.camera_pos = linalg.lerp(state.camera_pos, target_camera_pos, dt * camera_pos_speed)

	camera_zoom_speed :: 20.0
	state.camera_zoom = linalg.lerp(state.camera_zoom, target_camera_zoom, dt * camera_zoom_speed)
}

main :: proc() {
	rl.InitWindow(0, 0, "Ninja")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})


	defer rl.CloseWindow();

	state: GameState

	state.player.move_speed = 2000
	state.enemy.pos.x = -100
	state.fixed_dt = 1.0 / 120.0

	time_since_physics_update: f32 = 0

	for !rl.WindowShouldClose() {
		// Updating

		player := &state.player
		slash_input, dash_input := false, false
		if player.action == .Nothing {
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

		time_since_physics_update += rl.GetFrameTime()
		for time_since_physics_update > state.fixed_dt {
			time_since_physics_update -= state.fixed_dt
			update_game(&state)
		}

		// Drawing 

		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.BeginDrawing(); {
			rl.ClearBackground({255, 255, 255, 255})

			draw_enemy(state, state.enemy);
			draw_player(state);
		} rl.EndDrawing();
	}
}
