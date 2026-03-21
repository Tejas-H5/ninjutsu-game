package main

import "vendor:box2d"
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

ranges_overlap :: proc(a0, a1, b0, b1: f32) -> bool {
	if a0 < b0 {return b0 < a1;}
	return a0 < b1;
}

collide_box_with_box :: proc(a, b: Hitbox) -> bool {
	if ranges_overlap(a.left, a.right, b.left, b.right) {
		if ranges_overlap(a.bottom, a.top, b.bottom, b.top) {
			return true
		}
	}
	return false
}

RacyastHitInfo :: struct {
	t, u: f32,
	t_pos, u_pos: Vector2,
}

// https://paulbourke.net/geometry/pointlineplane/
// A lot better of a resource imo.
collide_ray_with_ray :: proc(r1, r2: Ray) -> (hit: bool, pos: RacyastHitInfo) {
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

BoxSides :: enum {
	Top,
	Left,
	Bottom,
	Right,
	Inside,
}

RaycastBoxHitInfo :: struct {
	pos: Vector2,
	sides: [BoxSides]struct{ hit: bool, pos: Vector2 },
}

collide_ray_with_box :: proc(ray: Ray, box: Hitbox) -> (hit_result: bool, info_result: RaycastBoxHitInfo) {
	if collide_point_with_box(box, ray.start) {
		return true, {
			sides= #partial { .Inside = { hit=true, pos=ray.start }},
			pos=ray.start
		}
	}

	rays := [BoxSides]Ray{
		.Top    = ray_from_start_end({box.left, box.top}, {box.right, box.top}),
		.Bottom = ray_from_start_end({box.left, box.bottom}, {box.right, box.bottom}),
		.Left   = ray_from_start_end({box.left, box.top}, {box.left, box.bottom}),
		.Right  = ray_from_start_end({box.right, box.top}, {box.right, box.bottom}),
		.Inside = {},
	}

	last_dist := math.INF_F32

	for side, side_enum in rays {
		if side_enum == .Inside {continue}

		hit, info := collide_ray_with_ray(ray, side)
		if hit {
			pos := info.t_pos
			info_result.sides[side_enum] = { hit = true, pos = info.t_pos }

			dist := linalg.length2(ray.start - pos)
			if dist < last_dist {
				hit_result = true
				info_result.pos = pos
				last_dist = dist
			}
		}
	}

	return
}

