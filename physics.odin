package main

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

hitbox_width :: proc(box: Hitbox) -> f32 {
	return box.right - box.left
}

hitbox_height :: proc(box: Hitbox) -> f32 {
	return box.top - box.bottom
}

hitbox_centroid :: proc(box: Hitbox) -> Vector2 {
	return {
		box.left + hitbox_width(box) / 2,
		box.top  + hitbox_height(box) / 2,
	}
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

// I want to simply not consider the pathological case where all 1mill items are in the same grid cell
MAX_ITEMS_PER_CELL :: 5
SparseGridSlot :: struct{
	items : [MAX_ITEMS_PER_CELL]SparseGridItem,
	count: int,
}

SparsePyramid :: struct {
	grids: []SparseGrid,
}

SparseGrid :: struct {
	items_map : map[Vector2i]SparseGridSlot,
	grid_size : f32,

	// debugging
	count : int,
}

SparseGridItem :: struct {
	box: Hitbox,
	// It's assumed you are storing your entities in an array of some sort,
	// possibly partitioned by type, and that the entities have a unique index into the array.
	// This is used to ensure only 1 collision pair per entity later.
	item_type, item_idx: int,
}


// TODO: deprecate in favour of moving items.
sparse_grid_reset :: proc(m: ^SparseGrid) {
	clear_map(&m.items_map)
}

sparse_pyramid_reset :: proc(p: ^SparsePyramid) {
	for &g in p.grids {
		sparse_grid_reset(&g)
	}
}

sparse_grid_get_key :: proc(m: ^SparseGrid, centroid: Vector2) -> Vector2i {
	return {
		int(math.floor(centroid.x / m.grid_size)),
		int(math.floor(centroid.y / m.grid_size)),
	}
}

sparse_grid_get_key_from_hitbox :: proc(m: ^SparseGrid, hitbox: Hitbox) -> Vector2i {
	centroid := hitbox_centroid(hitbox)
	return sparse_grid_get_key(m, centroid)
}

sparse_grid_get_slot :: proc(m: ^SparseGrid, key: Vector2i) -> ^SparseGridSlot {
	v, ok := &m.items_map[key]
	if !ok {
		m.items_map[key] = SparseGridSlot{}
		v = &m.items_map[key]
	}

	return v
}

sparse_grid_add :: proc(g: ^SparseGrid, item: SparseGridItem) {
	// The sparse grid can't detect collisions properly if the items are too big
	assert(g.grid_size > 0.1)
	assert(hitbox_width(item.box) < g.grid_size)
	assert(hitbox_height(item.box) < g.grid_size)

	centroid := hitbox_centroid(item.box)
	key      := sparse_grid_get_key(g, centroid)
	slot     := sparse_grid_get_slot(g, key)

	if slot.count < len(slot.items) {
		slot.items[slot.count] = item
		slot.count += 1
		g.count    += 1
	}
}

sparse_pyramid_add :: proc(p: ^SparsePyramid, item: SparseGridItem) -> (added: bool) {
	size := math.max(hitbox_width(item.box), hitbox_height(item.box))

	for &grid in p.grids {
		if grid.grid_size > size {
			sparse_grid_add(&grid, item)
			added = true
			break;
		}
	}

	return
}

// NOTE: API is totally wrong, yet again

SparseGridCollisionProc :: #type proc(a, b: ^SparseGridItem, data: rawptr)

SURROUNDING_OFFSETS :: [9]Vector2i {
	{-1,-1}, {0,-1}, {1,-1},
	{-1,0},  {0,0},  {1,0},
	{-1,1},  {0,1},  {1,1},
}

// All item pairs will get collided exactly once
sparse_pyramid_for_each_collision :: proc(g: ^SparsePyramid, data: rawptr, callback: SparseGridCollisionProc) {
	// NOTE: items on lower grid levels should always be able to collide with objects on higher grid levels,
	// but this is not necessarily true the other way around. 
	// For that reason, the code to enforce just 1 collision instead of 2 checks a.level < b.level before allowing it
	//  (in fact, I've just updated the loop to enforce this rather than doing it explicitly)

	for &level, item_level_idx in g.grids {
		for slot_cell, &slot in level.items_map {
			for &item in slot.items[:slot.count] {

				for other_item_level_idx in item_level_idx..<len(g.grids) {
					other_level := &g.grids[other_item_level_idx]
					other_slot_cell := sparse_grid_get_key_from_hitbox(other_level, item.box)

					for offset in SURROUNDING_OFFSETS {
						other_slot, ok := &other_level.items_map[other_slot_cell + offset]
						if !ok {continue}

						for &other_item in other_slot.items[:other_slot.count] {

							collision_allowed := false

							// This code ensures only one collision pair is generated per object.
							// This is actually _easier_ than e.g. enforcing 2 collision pairs per object.
							if item_level_idx < other_item_level_idx {
								collision_allowed = true
							} else {
								assert(item_level_idx == other_item_level_idx)

								if item.item_type < other_item.item_type {
									collision_allowed = true
								} else if item.item_type == other_item.item_type {
									if item.item_idx < other_item.item_idx {
										collision_allowed = true
									}
								}
							}

							if !collision_allowed {continue}
							if item == other_item {continue}
							if !collide_box_with_box(item.box, other_item.box) {continue}

							callback(&item, &other_item, data)
						}
					}
				}
			}
		}
	}
}

// Useful for testing, but probably too slow to ship
Collision :: struct{ a: SparseGridItem, b: SparseGridItem }
Collisions :: struct { collisions: [dynamic]Collision }
collect_collisions :: proc(p: ^SparsePyramid) -> Collisions {
	data: Collisions
	sparse_pyramid_for_each_collision(p, &data, proc (a, b: ^SparseGridItem, dataptr: rawptr) {
		data := cast(^Collisions)dataptr
		append(&data.collisions, Collision{ a=a^, b=b^ })
	})
	return data
}

