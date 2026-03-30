package main

import "core:math"

unit_circle :: proc(angle: f32) -> Vector2 {
	return {
		math.cos(angle),
		math.sin(angle),
	}
}
