package game

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

QUARTER_TURN :: math.PI / 2

unit_circle :: proc(angle: f32) -> Vector2 {
	return {
		math.cos(angle),
		math.sin(angle),
	}
}

lerp :: proc(a, b, t: f32) -> f32 {
	return math.lerp(a, b, math.saturate(t))
}

lerp_vec2 :: proc(a, b: Vector2, t: f32) -> Vector2 {
	t := math.saturate(t)
	if linalg.length2(a-b) < 0.0001 {
		return b
	}

	return linalg.lerp(a, b, t)
}

get_angle :: proc(x, y: f32) -> f32 {
	return math.atan2(y, x)
}

get_angle_vec :: proc(vec: Vector2) -> f32 {
	return math.atan2(vec.y, vec.x)
}

was_overshoot :: proc(target: Vector2, prev_pos: Vector2, pos: Vector2) -> bool {
	prev_to_target := target - prev_pos
	curr_to_target := target - pos
	return linalg.dot(prev_to_target, curr_to_target) < 0
}

vec2ui_to_vec2f :: proc(vec: Vector2Ui) -> Vector2 {
	return {
		f32(vec.x),
		f32(vec.y),
	}
}

to_uipos :: proc(vec: Vector2) -> UiPos {
	return {
		UiLength(vec.x),
		UiLength(vec.y),
	}
}

to_int_color :: proc(c: Color, loc := #caller_location) -> rl.Color {
	assert(c.r <= 1.1, loc = loc)
	assert(c.g <= 1.1, loc = loc)
	assert(c.b <= 1.1, loc = loc)
	assert(c.a <= 1.1, loc = loc)

	return {
		u8(c.r * 255),
		u8(c.g * 255),
		u8(c.b * 255),
		u8(c.a * 255),
	}
}

to_floating_color :: proc "c" (c: rl.Color) -> Color {
	return {
		f32(c.r) / 255,
		f32(c.g) / 255,
		f32(c.b) / 255,
		f32(c.a) / 255,
	}
}
