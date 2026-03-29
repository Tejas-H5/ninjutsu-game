package main

import "core:testing"

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

	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 1}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {2, 1}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {3, 1}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {4, 1}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {5, 1}) })
	testing.expect(t, added)

	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 1}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 2}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 3}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 4}) })
	testing.expect(t, added)
	added = sparse_pyramid_add(&p, { box = hitbox_from_pos_size({0, 0}, {1, 5}) })
	testing.expect(t, added)

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

	log_sparse_pyramid(&p)

	hits := query_colliders_intersecting_hitbox(&p, {-0.5, -0.5, 0.5, 0.5})
	// hits := query_colliders_intersecting_hitbox(&p, {0,0,1,1})

	testing.expect_value(t, len(hits), 3)
}

