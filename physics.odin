package main

import "core:fmt"
import "core:math/linalg"
import "core:math"

/*
Current status:
     Box | Ray
Box:  x  |  x
Ray:  x  |
*/

Hitbox :: struct {
	top, left, bottom, right: f32
}

hitbox_from_pos_size :: proc(pos, size: Vector2) -> Hitbox {
	top := pos.y + size.y / 2
	bottom := pos.y - size.y / 2

	right := pos.x + size.x / 2
	left := pos.x - size.x / 2

	return {top,left,bottom,right}
}

Ray :: struct {
	start: Vector2,
	end: Vector2,
}

ray_from_start_end :: proc(start, end: Vector2) -> Ray {
	return { start, end };
}

ray_from_orign_dir :: proc(origin, dir: Vector2) -> Ray {
	return { start = origin, end = (origin+dir) };
}


BoxXBoxCollisionInfo :: struct {
	point: Vector2,
}

collide_box_with_box :: proc(a, b: Hitbox) -> (bool, BoxXBoxCollisionInfo) {
	h1, h2 := a, b
	if a.right < b.left {
		h1, h2 = a, b
	} else if b.left < a.right {
		h1, h2 = b, a
	}

	v1, v2 := a, b
	if a.bottom < b.top {
		v1, v2 = a, b
	} else if b.bottom < a.top {
		v1, v2 = b, a
	}

	x := math.lerp(h1.right, h2.left, f32(0.5))
	y := math.lerp(v1.right, v2.left, f32(0.5))
	return true, { point = Vector2{x, y} }
}

RacyastHitInfo :: struct {
	t, u: f32,
	t_pos, u_pos: Vector2,
}

// https://en.wikipedia.org/wiki/Line%E2%80%93line_intersection
// Turns out there is a lot of knowledge if you simply make the effort to learn how to read the math
collide_ray_x_ray :: proc(r1, r2: Ray) -> (hit: bool, pos: RacyastHitInfo) {
	x1, y1 := r1.start.x, r1.start.y
	x2, y2 := r1.end.x, r1.end.y
	x3, y3 := r2.start.x, r2.start.y
	x4, y4 := r2.end.x, r2.end.y

	denominator := ((y4 - y3) * (x2 - x1)) - ((x4 - x3) * (y2 - y1))

	t := (((x4 - x3) * (y1 - y3)) - ((y4 - y3) * (x1 - x3))) / denominator
	u := (((x2 - x1) * (y1 - y3)) - ((y2 - y1) * (x1 - x3))) / denominator

	pos.t = t
	pos.u = u

	pos.t_pos = Vector2{x1, y1} + t * Vector2{x2-x1, y2-y1}
	pos.u_pos =  Vector2{x3, y3} + u * Vector2{x4-x3, y4-y3}

	if 0 <= t && t <= 1 {
		if 0 <= u && u <= 1 {
			hit = true
		}
	}

	return
}

collide_point_with_box :: proc(box: Hitbox, point: Vector2) -> bool {
	if box.left < point.x && point.x < box.right {
		if box.bottom < point.y && point.y < box.top {
			return true
		}
	}
	return false
}

collide_ray_with_box :: proc(box: Hitbox, ray: Ray) -> (hit_result: bool, pos_result: Vector2) {
	if collide_point_with_box(box, ray.start) {return true, ray.start}

	box_sides := [4]Ray{
		ray_from_start_end({box.left, box.top}, {box.right, box.top}),
		ray_from_start_end({box.left, box.bottom}, {box.right, box.bottom}),
		ray_from_start_end({box.left, box.top}, {box.left, box.bottom}),
		ray_from_start_end({box.right, box.top}, {box.right, box.bottom}),
	}

	last_dist := math.INF_F32

	for side in box_sides {
		hit, info := collide_ray_x_ray(ray, side)
		if hit {
			pos := info.t_pos
			dist := linalg.length2(ray.start - pos)
			if dist < last_dist {
				hit_result = true
				pos_result = pos
				last_dist = dist
			}
		}
	}

	return
}

