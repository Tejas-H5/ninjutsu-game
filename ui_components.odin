package main

import rl "vendor:raylib";
import c "core:c"

ui_draw_rect :: proc(outline: rl.Color, outlineThicness: f32, color: rl.Color) {
	rect := ui_get_rect()

	x := c.int(rect.left)
	y := c.int(rect.top)
	width := c.int(rect.right - rect.left)
	height := c.int(rect.bottom - rect.top)

	rl.DrawRectangle(x, y, width, height, outline)

	{
		x := x + c.int(outlineThicness) / 2
		y := y + c.int(outlineThicness) / 2
		width := width - c.int(outlineThicness)
		height := height - c.int(outlineThicness)

		rl.DrawRectangle(x, y, width, height, color)
	}
}

UiMeasurement :: struct {
	width, height: f32,
}

UiRenderMode :: enum {
	Measure,
	Draw,
}

