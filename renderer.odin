package game

import "core:math"
import "core:c"
import rl "vendor:raylib";

Vector2    :: rl.Vector2
Vector2i   :: [2]int
Vector2i32 :: [2]c.int
Vector2Ui  :: [2]UiLength
UiPos :: Vector2Ui
Color      :: rl.Color
Texture2D  :: rl.Texture2D

to_screen_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return camera_to_screen_pos(state.camera, state.window_size, pos)
}

to_screen_uipos :: proc(state: ^GameState, pos: Vector2) -> UiPos {
	res := camera_to_screen_pos(state.camera, state.window_size, pos)
	return to_uipos(res)
}

to_game_pos :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return screen_to_camera_pos(state.camera, state.window_size, pos)
}

to_screen_size :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return camera_to_screen_size(state.camera, pos)
}

to_game_size :: proc(state: ^GameState, pos: Vector2) -> Vector2 {
	return screen_to_camera_size(state.camera, pos)
}

to_screen_len :: proc(state: ^GameState, len: f32) -> f32 {
	return camera_to_screen_len(state.camera, len)
}

to_game_len :: proc(state: ^GameState, len: f32) -> f32 {
	return screen_to_camera_len(state.camera, len)
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
		rl.Rectangle{x = 0, y = 0, width = f32(texture.width), height = f32(texture.height)},
		rl.Rectangle{
			x = math.floor_f32(bottom_left.x),
			y = math.floor_f32(bottom_left.y),
			width  = math.ceil_f32(screen_size.x),
			height = math.ceil_f32(screen_size.y)
		},
		{},
		0,
		col,
	)
}



// A spritesheet is just a long image. Each 'sprite' in the is assumed to be square the same width as the image's height with 1 pixel of padding on all sides
draw_rect_textured_spritesheet :: proc (
	state: ^GameState,
	pos, size: Vector2,
	col: rl.Color,
	spritesheet: Spritesheet,
	sprite_coordinate: Vector2i,
	rotation: f32 = 0,
) {
	bottom_left := to_screen_pos(state, pos)//  - to_screen_size(state, size / 2.0) (handled by origin argument to raylib)
	screen_size := to_screen_size(state, size)

	draw_rect_textured_spritesheet_screenspace(
		state,
		bottom_left, screen_size,
		col,
		spritesheet,
		sprite_coordinate,
		rotation,
	)
}

draw_rect_textured_spritesheet_screenspace :: proc (
	state: ^GameState,
	bottom_left, screen_size: Vector2,
	col: rl.Color,
	spritesheet: Spritesheet,
	sprite_coordinate: Vector2i,
	rotation: f32 = 0,
) {
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
		rl.Rectangle{
			x = math.floor_f32(bottom_left.x),
			y = math.floor_f32(bottom_left.y),
			width  = math.ceil_f32(screen_size.x),
			height = math.ceil_f32(screen_size.y),
		},
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

Camera2D :: struct {
	pos  : Vector2,
	zoom : f32,
}


// My main gripe with this API naming - wtf is a 'camera pos' ?? TODO: think of better names for this set of functions

camera_to_screen_pos :: proc(camera: Camera2D, window_size: Vector2, pos: Vector2) -> Vector2 {
	screen_pos := (pos - camera.pos) * camera.zoom
	x := screen_pos.x
	y := -screen_pos.y

	offset := window_size / 2
	return { x, y } + offset;
}

screen_to_camera_pos :: proc(camera: Camera2D, window_size: Vector2, pos: Vector2) -> Vector2 {
	if camera.zoom == 0 {return 0}

	offset := window_size / 2
	screen_pos_no_offset := (pos - offset)

	x := screen_pos_no_offset.x
	y := -screen_pos_no_offset.y

	game_pos := (Vector2{ x, y } / camera.zoom) + camera.pos

	return game_pos
}

camera_to_screen_size :: proc(camera: Camera2D, pos: Vector2) -> Vector2 {
	return pos * camera.zoom
}

screen_to_camera_size :: proc(camera: Camera2D, pos: Vector2) -> Vector2 {
	return pos / camera.zoom
}

camera_to_screen_len :: proc(camera: Camera2D, len: f32) -> f32 {
	return len * camera.zoom;
}

screen_to_camera_len :: proc(camera: Camera2D, len: f32) -> f32 {
	return len / camera.zoom;
}

camera_lerp :: proc(a: Camera2D, b: Camera2D, pos_t, zoom_t: f32) -> (result: Camera2D) {
	result.pos = lerp_vec2(a.pos, b.pos, pos_t)
	result.zoom = lerp(a.zoom, b.zoom, zoom_t)
	return result
}

TextColumn :: struct {
	pos: Vector2Ui,
	gap: UiLength,
	size: UiLength,
	// 0   -> Left
	// 0.5 -> Center
	// 1.0 -> Right
	align: f32,
}

LEFT_ALIGN   :: 0
CENTER_ALIGN :: 0.5
RIGHT_ALIGN  :: 1

text_column_make :: proc(pos: UiPos, size, gap: UiLength, align : f32 = LEFT_ALIGN) -> (text: TextColumn) {
	text.pos   = pos 
	text.size  = size
	text.gap   = gap
	text.align = align
	return
}

draw_text_row_screenspace :: proc(text: ^TextColumn, format: UiString, args: ..any, color : Color = COL_FG) {
	cstr := rl.TextFormat(format, ..args)
	width := rl.MeasureText(cstr, text.size)
	
	offset := f32(width) * -text.align
	rl.DrawText(cstr, text.pos.x + UiLength(offset), text.pos.y, text.size, {0, 0,0, 255})

	text.pos.y += text.size + text.gap
}
