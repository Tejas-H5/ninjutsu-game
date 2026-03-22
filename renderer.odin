package main

import rl "vendor:raylib";

Vector2 :: rl.Vector2

to_screen_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	screen_pos := (pos - state.camera_pos) * state.camera_zoom
	x := screen_pos.x
	y := -screen_pos.y

	offset := state.window_size / 2
	return { x, y } + offset;
}

to_game_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	offset := state.window_size / 2
	screen_pos_no_offset := (pos - offset)

	x := screen_pos_no_offset.x
	y := -screen_pos_no_offset.y

	game_pos := (Vector2{ x, y } / state.camera_zoom) + state.camera_pos

	return game_pos
}


to_screen_size :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return pos * state.camera_zoom
}

to_game_size :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return pos / state.camera_zoom
}

to_screen_len :: proc(state: ^GameState, len: f32) -> f32 {
	return len * state.camera_zoom;
}

to_game_len :: proc(state: ^GameState, len: f32) -> f32 {
	return len / state.camera_zoom;
}


draw_rect :: proc (state: ^GameState, pos: Vector2, size: Vector2, col: rl.Color) {
	bottom_left := to_screen_pos(state, pos) - to_screen_size(state, size / 2.0)
	screen_size := to_screen_size(state, size)
	rl.DrawRectangleV(bottom_left, screen_size, col)
}

draw_line :: proc(state: ^GameState, a, b: Vector2, width: f32, color: rl.Color) {
	screen_a := to_screen_pos(state, a)
	screen_b := to_screen_pos(state, b)
	screen_len := to_screen_len(state, width)
	rl.DrawLineEx(screen_a, screen_b, screen_len, color)
}
