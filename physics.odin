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
	left, bottom, right, top: f32,
}

hitbox_from_pos_size :: proc(pos, size: Vector2) -> Hitbox {
	top    := pos.y + size.y / 2
	bottom := pos.y - size.y / 2
	right  := pos.x + size.x / 2
	left   := pos.x - size.x / 2

	assert(bottom < top)
	assert(left < right)

	return {
		top    = top,
		left   = left,
		bottom = bottom,
		right  = right,
	}
}

Ray :: struct {
	pos: Vector2,
	dir: Vector2,
	len: f32,
}

ray_from_start_end :: proc(start, end: Vector2) -> Ray {
	start_to_end := end - start
	length := linalg.length(start_to_end)
	dir    := start_to_end == 0 ? 0 : start_to_end / length

	return {
		pos = start,
		dir = dir,
		len = length,
	};
}

ray_from_orign_dir :: proc(origin, dir: Vector2) -> Ray {
	return ray_from_start_end(origin, origin + dir)
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
		box.left    + hitbox_width(box) / 2,
		box.bottom  + hitbox_height(box) / 2,
	}
}

RacyastHitInfo :: struct {
	t, u: f32,
	t_pos, u_pos: Vector2,
}

// https://paulbourke.net/geometry/pointlineplane/
// A lot better of a resource imo.
collide_ray_with_ray :: proc(r1, r2: Ray) -> (hit: bool, pos: RacyastHitInfo) {
	r1_start := r1.pos
	r1_end   := r1_start + r1.dir * r1.len
	r2_start := r2.pos
	r2_end   := r2_start + r2.dir * r2.len

	x1, y1 := r1_start.x, r1_start.y
	x2, y2 := r1_end.x, r1_end.y
	x3, y3 := r2_start.x, r2_start.y
	x4, y4 := r2_end.x, r2_end.y

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
	// We need to compute these to figure out pos anyway
	sides: [BoxSides]struct{ hit: bool, pos: Vector2 },
}

collide_ray_with_box :: proc(ray: Ray, box: Hitbox) -> (hit_result: bool, info_result: RaycastBoxHitInfo) {
	if collide_point_with_box(box, ray.pos) {
		return true, {
			sides= #partial { .Inside = { hit=true, pos=ray.pos }},
			pos=ray.pos
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

			dist := linalg.length2(ray.pos - pos)
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
MAX_DETECTABLE_COLLISIONS :: MAX_ITEMS_PER_CELL * 9

SparseGridSlot :: struct{
	items : [MAX_ITEMS_PER_CELL]SparseGridItem,
	count: int,
	// Used by raycast queries to avoid duplicating collision reports. 
	last_ray_id: int,
}

// A pyramid of sparse grids. e.g
// grid_size=2,
// grid_size=4,
// grid_size=8,
SparsePyramid :: struct {
	grids: []SparseGrid,
	query_result_buffer: [dynamic]^SparseGridItem,

	ray_id: int,
}

// A single layer in the sparse pyramid. 
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
	type, idx: int,
}


// TODO: deprecate in favour of moving items.
sparse_grid_reset :: proc(m: ^SparseGrid) {
	for k, &slot in m.items_map {
		slot.count = 0
		slot.last_ray_id = 0
	}
	m.count = 0
}

sparse_pyramid_reset :: proc(p: ^SparsePyramid) {
	for &g in p.grids {
		sparse_grid_reset(&g)
	}
	p.ray_id = 1
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

sparse_pyramid_add :: proc(p: ^SparsePyramid, item: SparseGridItem) {
	size := math.max(hitbox_width(item.box), hitbox_height(item.box))

	added := false

	for &grid in p.grids {
		if grid.grid_size > size {
			sparse_grid_add(&grid, item)
			added = true
			break
		}
	}

	// There were no grids large enough for this object to be added;
	assert(added)
}

// NOTE: API is totally wrong, yet again

SparseGridCollisionProc :: #type proc(a, b: ^SparseGridItem, data: rawptr)

SURROUNDING_OFFSETS :: [9]Vector2i {
	{-1,-1},
	{0,-1}, 
	{1,-1},
	{-1,0},
	{0,0}, 
	{1,0},
	{-1,1},
	{0,1}, 
	{1,1},
}

SURROUNDING_OFFSETS_F32 :: [9]Vector2 {
	{-1,-1},
	{0,-1}, 
	{1,-1},
	{-1,0},
	{0,0}, 
	{1,0},
	{-1,1},
	{0,1}, 
	{1,1},
}

// All item pairs will get collided exactly once
sparse_pyramid_for_each_collision :: proc(p: ^SparsePyramid, data: rawptr, callback: SparseGridCollisionProc) {
	// NOTE: items on lower grid levels should always be able to collide with objects on higher grid levels,
	// but this is not necessarily true the other way around. 
	// For that reason, the code to enforce just 1 collision instead of 2 checks a.level < b.level before allowing it
	//  (in fact, I've just updated the loop to enforce this rather than doing it explicitly)

	for &level, item_level_idx in p.grids {
		for slot_cell, &slot in level.items_map {
			for &item in slot.items[:slot.count] {

				for other_item_level_idx in item_level_idx..<len(p.grids) {
					other_level := &p.grids[other_item_level_idx]
					other_slot_cell := sparse_grid_get_key_from_hitbox(other_level, item.box)

					for offset in SURROUNDING_OFFSETS {
						other_slot, ok := &other_level.items_map[other_slot_cell + offset]
						if !ok {continue}

						for &other_item in other_slot.items[:other_slot.count] {
							if item == other_item {continue}

							// This code ensures only one collision pair is generated per object.
							// This is actually _easier_ than e.g. enforcing 2 collision pairs per object.
							collision_allowed := false; {
								if item_level_idx < other_item_level_idx {
									collision_allowed = true
								} else {
									ensure(item_level_idx == other_item_level_idx)

									if item.type < other_item.type {
										collision_allowed = true
									} else if item.type == other_item.type {
										if item.idx < other_item.idx {
											collision_allowed = true
										}
									}
								}
							}

							if !collision_allowed {continue}
							if !collide_box_with_box(item.box, other_item.box) {continue}

							callback(&item, &other_item, data)
						}
					}
				}
			}
		}
	}
}

// NOTE: returns a view into a temporary buffer that gets invalidated/overwritten by new queries. 
query_colliders_intersecting_hitbox :: proc(
	p: ^SparsePyramid,
	hitbox: Hitbox,
	// Calibrated for colliding a single entity in the grid against another entity. 
	// For larger selection actions, you'll want to set a bigger limit.
	limit: int = 16, 
	// TODO: consider layer mask
	ignore_type := -1
) -> []^SparseGridItem {
	clear_dynamic_array(&p.query_result_buffer)

	// NOTE: this code only works because each collider is guaranteed to be assigned to a single cell
	// within a single layer. There are some other ideas I've been having r.e. putting cells into multiple layers
	// to speed up queyring, but this massively complicates the issue of not reporting duplicate collisions, so probably not 
	// worth it for now.

	centroid := hitbox_centroid(hitbox)

	outer_for: for &grid, grid_level in p.grids {
		delta := grid.grid_size

		// extend grid search by 1 grid - need to search all surrounding grid cells as well
		start_x, end_x := centroid.x - delta, centroid.x + 1.1 * delta
		start_y, end_y := centroid.y - delta, centroid.y + 1.1 * delta 

		for x := start_x; x <= end_x; x += delta {
			for y := start_y; y <= end_y; y += delta {

				key := sparse_grid_get_key(&grid, {x, y})
				slot := sparse_grid_get_slot(&grid, key)

				for &item in slot.items[:slot.count] {
					if item.type == ignore_type {continue}

					if collide_box_with_box(item.box, hitbox) {
						append(&p.query_result_buffer, &item)

						if len(p.query_result_buffer) >= limit {
							break outer_for
						}
					}
				}
			}
		}
	}

	return p.query_result_buffer[:]
}

query_colliders_intersecting_ray :: proc(
	p: ^SparsePyramid,
	ray: Ray,
	// Calibrated for colliding a single entity in the grid against another entity. 
	// For larger selection actions, you'll want to set a bigger limit.
	limit: int = 16, 
	// TODO: consider layer mask
	ignore_type := -1
) -> []^SparseGridItem { // We may need to return a specific raycast query result. We're dropping a lot of information returned by a raycast here.
	clear_dynamic_array(&p.query_result_buffer)

	// TODO: need to check at least 1 surrounding, and without duplicating reporting.

	ray_id := p.ray_id
	p.ray_id += 1

	outer_for: for &grid in p.grids {
		last_key: Vector2i
		for s := f32(0); s <= ray.len + 0.0001; s += grid.grid_size {
			ray_pos := ray.pos + ray.dir * s
			center_key  := sparse_grid_get_key(&grid, ray_pos)

			for offset in SURROUNDING_OFFSETS {
				key := center_key + offset
				slot := sparse_grid_get_slot(&grid, key)

				// Don't process the same slot twice in a single ray
				if slot.last_ray_id == ray_id {continue}
				slot.last_ray_id = ray_id

				for &item in slot.items[:slot.count] {
					if item.type == ignore_type {continue}

					// NOTE: info is not being used here. So maybe could be faster if we didn't compute it?
					// Will only add this if we hit perf issues
					hit, info := collide_ray_with_box(ray, item.box)

					if hit {
						append(&p.query_result_buffer, &item)

						if len(p.query_result_buffer) >= limit {
							break outer_for
						}
					}
				}
			}
		}
	}

	return p.query_result_buffer[:]
}

log_sparse_pyramid :: proc(p: ^SparsePyramid) {
	debug_log_intentional("log_sparse_pyramid - %v levels", len(p.grids))

	for &grid, idx in p.grids {
		debug_log_intentional("grid %v --------", idx)
		for k, &slot in grid.items_map {
			if slot.count == 0 {continue}

			debug_log_intentional("slot %v -> %v items", k, slot.count)
			for item, idx in slot.items[:slot.count] {
				debug_log_intentional("    %v -> %v", idx, item.box)
			}
		}
		debug_log_intentional("--------")
	}
}

