package main

import "core:math"

unit_circle :: proc(angle: f32) -> Vector2 {
	return {
		math.cos(angle),
		math.sin(angle),
	}
}

lerp :: proc(a, b, t: f32) -> f32 {
	return math.lerp(a, b, math.saturate(t))
}

get_angle :: proc(x, y: f32) -> f32 {
	return math.atan2(y, x)
}

get_angle_vec :: proc(vec: Vector2) -> f32 {
	return math.atan2(vec.y, vec.x)
}
