package game

import "core:testing"

// odin test . -define:ODIN_TEST_NAMES=game.sparse_grid_ray_query

@(test)
sparse_grid_1_level_collision :: proc(t: ^testing.T) {
	pyramid := [?]SparseGrid{
		{grid_size = 4.0}
	}
	p := SparsePyramid {
		grids = pyramid[:]
	}

	s1_grid := &p.grids[0]

	sparse_pyramid_reset(&p)

	sparse_grid_add(s1_grid, hitbox_from_pos_size({0, 0},     {1, 1}), 0, 0)
	sparse_grid_add(s1_grid, hitbox_from_pos_size({0.5, 0.5}, {1, 1}), 0, 1)

	coll := collect_collisions(&p)

	testing.expect_value(t, len(coll.collisions), 1)
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

	s1_grid := &p.grids[0]
	s2_grid := &p.grids[1]
	s3_grid := &p.grids[2]

	sparse_pyramid_reset(&p)

	sparse_grid_add(s1_grid, hitbox_from_pos_size({0, 0}, {1, 1}), 0, 1)
	sparse_grid_add(s2_grid, hitbox_from_pos_size({0, 0}, {2, 1}), 0, 2)
	sparse_grid_add(s2_grid, hitbox_from_pos_size({0, 0}, {3, 1}), 0, 3)
	sparse_grid_add(s3_grid, hitbox_from_pos_size({0, 0}, {4, 1}), 0, 4)
	sparse_grid_add(s3_grid, hitbox_from_pos_size({0, 0}, {5, 1}), 0, 5)

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

	s1_grid := &p.grids[0]
	s2_grid := &p.grids[1]
	s3_grid := &p.grids[2]

	sparse_grid_add(s1_grid, {0,0,1,1}, 0, 0)
	sparse_grid_add(s2_grid, {0,0,3,3}, 0, 1)
	sparse_grid_add(s3_grid, {0,0,6,6}, 0, 2)

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

	origin := Vector2{ -200, 0,}


	s1_grid := &p.grids[0]

	sparse_pyramid_reset(&p)

	sparse_grid_add(s1_grid, hitbox_from_pos_size(origin, { 100, 100 }), 0, 0)

	testing.expect_value(t, p.grids[0].count, 1)

	// Should hit
	{


		set_logging_type(.Logger)
		log_sparse_pyramid(&p)
		
		hits := query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,-1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		set_logging_type(.None)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {0,-1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,-1} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,0} + origin,   { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,0} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {-1,1} + origin,   { 100, 100 }))
		testing.expect_value(t, len(hits), 1)
		
		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {0,1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 1)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(99 * {1,1} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 1)
	}

	// Should miss
	{
		hits := query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,-1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {0,-1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,-1} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,0} + origin,   { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,0} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {-1,1} + origin,   { 100, 100 }))
		testing.expect_value(t, len(hits), 0)
		
		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {0,1} + origin,  { 100, 100 }))
		testing.expect_value(t, len(hits), 0)

		hits = query_colliders_intersecting_hitbox(&p, hitbox_from_pos_size(101 * {1,1} + origin, { 100, 100 }))
		testing.expect_value(t, len(hits), 0)
	}
}

@(test)
test_collide_box_with_box :: proc(t: ^testing.T) {
	origin := Vector2{ -1000, 0 }

	a := hitbox_from_pos_size(origin, {100, 100})

	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[0] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[1] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[2] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[3] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[4] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[5] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[6] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[7] * 99 + origin, {100, 100})), true)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[8] * 99 + origin, {100, 100})), true)

	// will fail for [0, 0]
	// testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[0] * 101, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[1] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[2] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[3] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[4] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[5] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[6] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[7] * 101 + origin, {100, 100})), false)
	testing.expect_value(t, collide_box_with_box(a, hitbox_from_pos_size(SURROUNDING_OFFSETS_F32[8] * 101 + origin, {100, 100})), false)

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

	s1_grid := &p.grids[0]
	s2_grid := &p.grids[1]
	s3_grid := &p.grids[2]

	for _ in 0..<2 {
		sparse_pyramid_reset(&p)

		sparse_grid_add(s1_grid, {0,0,1,1}, 0, 0)
		sparse_grid_add(s2_grid, {0,0,3,3}, 0, 1)
		sparse_grid_add(s3_grid, {0,0,6,6}, 0, 2)

		log_sparse_pyramid(&p)

		hits := query_colliders_intersecting_ray(&p, ray_from_start_end({-0.5, 0.5}, {0.5, 0.5}))


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

	s1_grid := &p.grids[0]

	for _ in 0..<2 {
		sparse_pyramid_reset(&p)

		sparse_grid_add(s1_grid, {10, 10, 110, 110}, 0, 0)
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

	s1_grid := &p.grids[0]

	for _ in 0..<2 {
		sparse_pyramid_reset(&p)

		sparse_grid_add(s1_grid, {10, 10, 110, 110}, 0, 0)
		testing.expect_value(t, p.grids[0].count, 1)

		hits := query_colliders_intersecting_ray(&p, ray_from_start_end({12, 12}, {13, 13}))
		testing.expect_value(t, len(hits), 1)
	}
}
