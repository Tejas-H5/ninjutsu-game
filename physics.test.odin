package main

import "core:testing"

// odin test . -define:ODIN_TEST_NAMES=main.your_test_here

@(test)
sparse_grid_1_level_collision :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 4.0}
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	sparse_pyramid_reset(&p)

	{
		g := &p.grids[0]
		sparse_grid_add(g, { box = hitbox_from_pos_size({0, 0}, {1, 1}),     idx = 0 })
		sparse_grid_add(g, { box = hitbox_from_pos_size({0.5, 0.5}, {1, 1}), idx = 1 })
	}

	coll := collect_collisions(&p)

	testing.expect_value(t, len(coll.collisions), 1)
}

@(test)
sparse_grid_multiple_levels_insertion :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 2},
		{grid_size = 4},
		{grid_size = 8},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	sparse_pyramid_reset(&p)

	added: bool

	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 1}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {2, 1}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {3, 1}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {4, 1}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {5, 1}) })

	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 1}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 2}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 3}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 4}) })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 5}) })

	g1 := &p.grids[0]
	g2 := &p.grids[1]
	g3 := &p.grids[2]

	testing.expect_value(t, g1.count, 1 * 2)
	testing.expect_value(t, g2.count, 2 * 2)
	testing.expect_value(t, g3.count, 2 * 2)
}

@(test)
sparse_grid_multiple_levels_collision :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 2},
		{grid_size = 4},
		{grid_size = 8},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	sparse_pyramid_reset(&p)

	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 1}), idx = 1 })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {2, 1}), idx = 2 })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {3, 1}), idx = 3 })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {4, 1}), idx = 4 })
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {5, 1}), idx = 5 })

	coll := collect_collisions(&p)

	// Expect each item to collide with every other item.
	testing.expect_value(
		t,
		len(coll.collisions),
		4 + 3 + 2 + 1
	)
}

Collision :: struct { a, b: ^SparseGridItem }
Collisions :: struct { collisions: [dynamic]Collision }
collect_collisions :: proc(p: ^SparsePyramid) -> Collisions {
	data : Collisions
	sparse_pyramid_for_each_collision(p, &data, proc(a, b: ^SparseGridItem, dataptr: rawptr) {
		data := cast(^Collisions)dataptr;
		append(&data.collisions, Collision{a, b})
	})

	return data
}

@(test)
sparse_grid_intersection_query :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 2},
		{grid_size = 4},
		{grid_size = 8},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	sparse_pyramid_reset(&p)

	sparse_pyramid_add(&p, { box = {0,0,1,1}, idx=0})
	sparse_pyramid_add(&p, { box = {0,0,3,3}, idx=1})
	sparse_pyramid_add(&p, { box = {0,0,6,6}, idx=2})

	testing.expect_value(t, p.grids[0].count, 1)
	testing.expect_value(t, p.grids[1].count, 1)
	testing.expect_value(t, p.grids[2].count, 1)

	hits := query_colliders_intersecting_hitbox(&p, {-0.5, -0.5, 0.5, 0.5})
	// hits := query_colliders_intersecting_hitbox(&p, {0,0,1,1})

	testing.expect_value(t, len(hits), 3)
}


@(test)
sparse_grid_intersection_hitbox_query_ranges :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 101},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	sparse_pyramid_reset(&p)

	set_logging_type(.Logger)
	sparse_pyramid_add(&p, { box = hitbox_from_pos_size({ 0, 0 }, { 100, 100 }) })

	set_logging_type(.None)
	testing.expect_value(t, p.grids[0].count, 1)


	// Should hit
	{

		log_sparse_pyramid(&p)

		hits := query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,-1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {0,-1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,-1}, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,0},   { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,0}, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,1},   { 100, 100 }))
		testing.expect_value(t, len(hits), 1)
		
		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {0,1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,1}, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)
	}

	// Should miss
	{
		hits := query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,-1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {0,-1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,-1}, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,0},   { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,0}, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,1},   { 100, 100 }))
		testing.expect_value(t, len(hits), 0)
		
		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {0,1},  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,1}, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)
	}
}

@(test)
test_collide_box_with_box :: proc(t: ^testing.T) {
	a := hitbox_from_pos_size({0, 0}, {100, 100})

	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[0] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[1] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[2] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[3] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[4] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[5] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[6] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[7] * 99, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[8] * 99, {100, 100})), true)

	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[0] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[1] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[2] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[3] * 101, {100, 100})), false)
	// will fail for [0, 0]
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[5] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[6] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[7] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[8] * 101, {100, 100})), false)

	testing.expect_value(t, collide_box_with_box(
		Hitbox{left = -50, bottom = -50, right = 50, top = 50},
		Hitbox{left = -69, bottom = -170, right = 271, top = 170}
	), true)
}

@(test)
sparse_grid_ray_query :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 2},
		{grid_size = 4},
		{grid_size = 8},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	for i in 0..<2 {
		sparse_pyramid_reset(&p)

		x := f32(0)
		sparse_pyramid_add(&p, { box = {x,0,1,1}, idx=0})
		x += 2
		sparse_pyramid_add(&p, { box = {x,0,3,3}, idx=1})
		x += 4
		sparse_pyramid_add(&p, { box = {x,0,6,6}, idx=2})

		// Dont include this one yeah
		sparse_pyramid_add(&p, { box = {x + 6,0,6,6}, idx=2})

		testing.expect_value(t, p.grids[0].count, 1)
		testing.expect_value(t, p.grids[1].count, 1)
		testing.expect_value(t, p.grids[2].count, 2)

		hits := query_colliders_intersecting_ray(&p, ray_from_start_end({-0.5, 0.5}, {x + 0.5, 0.5}))

		testing.expect_value(t, len(hits), 3)
	}
}


@(test)
sparse_grid_ray_query_from_outside :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 120},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	for i in 0..<2 {
		sparse_pyramid_reset(&p)

		sparse_pyramid_add(&p, { box = {10, 10, 110, 110}, idx=0})
		testing.expect_value(t, p.grids[0].count, 1)

		hits := query_colliders_intersecting_ray(&p, ray_from_start_end({0, 0}, {12, 12}))

		testing.expect_value(t, len(hits), 1)
	}
}

@(test)
sparse_grid_ray_query_from_inside :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 120},
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	for i in 0..<2 {
		sparse_pyramid_reset(&p)

		sparse_pyramid_add(&p, { box = {10, 10, 110, 110}, idx=0})
		testing.expect_value(t, p.grids[0].count, 1)

		hits := query_colliders_intersecting_ray(&p, ray_from_start_end({12, 12}, {13, 13}))
		testing.expect_value(t, len(hits), 1)
	}
}
