package game

import "core:math"
import "core:math/linalg"

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
