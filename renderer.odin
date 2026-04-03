package main

import "core:math"
import "core:c"
import rl "vendor:raylib";

Vector2    :: rl.Vector2
Vector2i   :: [2]int
Vector2i32 :: [2]c.int
Color      :: rl.Color
Texture2D  :: rl.Texture2D

to_screen_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	screen_pos := (pos - state.camera_pos) * state.camera_zoom
	x := screen_pos.x
	y := -screen_pos.y

	offset := state.window_size / 2
	return { x, y } + offset;
}

to_game_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	if state.camera_zoom == 0 {return 0}

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

FillType :: enum {
	Solid,
	Outline,
}

draw_rect :: proc (state: ^GameState, pos: Vector2, size: Vector2, col: rl.Color, fillType : FillType = .Solid) {
	bottom_left := to_screen_pos(state, pos) - to_screen_size(state, size / 2.0)
	screen_size := to_screen_size(state, size)

	switch (fillType) {
	case .Outline:
		rl.DrawRectangleLines(
			c.int(bottom_left.x),
			c.int(bottom_left.y),
			c.int(screen_size.x),
			c.int(screen_size.y),
			col
		)
	case .Solid:
		rl.DrawRectangleV(bottom_left, screen_size, col)
	}
}

draw_rect_textured :: proc (state: ^GameState, pos: Vector2, size: Vector2, col: rl.Color, texture: rl.Texture2D) {
	bottom_left := to_screen_pos(state, pos) - to_screen_size(state, size / 2.0)
	screen_size := to_screen_size(state, size)
	rl.DrawTexturePro(
		texture,
		rl.Rectangle{ x = 0, y = 0, width = f32(texture.width), height = f32(texture.height) },
		rl.Rectangle{ x = bottom_left.x, y = bottom_left.y, width = screen_size.x, height = screen_size.y },
		{},
		0,
		col,
	)
}



// A spritesheet is just a long image. Each 'sprite' in the is assumed to be square the same width as the image's height with 1 pixel of padding on all sides
draw_rect_textured_spritesheet :: proc (
	state: ^GameState,
	pos: Vector2,
	size: Vector2,
	col: rl.Color,
	spritesheet: Spritesheet,
	sprite_coordinate: Vector2i,
	rotation: f32 = 0,
) {
	bottom_left := to_screen_pos(state, pos)//  - to_screen_size(state, size / 2.0) (handled by origin argument to raylib)
	screen_size := to_screen_size(state, size)

	sprite_start := sprite_coordinate * spritesheet.sprite_size

	src := rl.Rectangle{
		x      = f32(sprite_start.x + spritesheet.padding),
		y      = f32(sprite_start.y + spritesheet.padding),
		width  = f32(spritesheet.sprite_size - 2 * spritesheet.padding),
		height = f32(spritesheet.sprite_size - 2 * spritesheet.padding),
	}

	rl.DrawTexturePro(
		spritesheet.texture,
		src,
		rl.Rectangle{ x = bottom_left.x, y = bottom_left.y, width = screen_size.x, height = screen_size.y },
		screen_size / 2,
		180 * rotation / math.PI,
		col
	)
}

draw_line :: proc(state: ^GameState, a, b: Vector2, width: f32, color: rl.Color) {
	screen_a := to_screen_pos(state, a)
	screen_b := to_screen_pos(state, b)
	screen_len := to_screen_len(state, width)
	rl.DrawLineEx(screen_a, screen_b, screen_len, color)
}
