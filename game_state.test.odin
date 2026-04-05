package game

import "core:testing"

@(test)
test_ground_pos_to_chunk_coord :: proc(t: ^testing.T) {
	testing.expect_value(t, ground_pos_to_chunk_coord({ 0, 0 }), Vector2i{0, 0})
	testing.expect_value(t, ground_pos_to_chunk_coord({ CHUNK_GROUND_ROW_COUNT-1, CHUNK_GROUND_ROW_COUNT-1 }), Vector2i{0, 0})
	testing.expect_value(t, ground_pos_to_chunk_coord({ CHUNK_GROUND_ROW_COUNT, CHUNK_GROUND_ROW_COUNT }), Vector2i{1, 1})
	testing.expect_value(t, ground_pos_to_chunk_coord({ -1,-1 }), Vector2i{-1, -1})
	testing.expect_value(t, ground_pos_to_chunk_coord({ -CHUNK_GROUND_ROW_COUNT+1, -CHUNK_GROUND_ROW_COUNT+1 }), Vector2i{-1, -1})
	testing.expect_value(t, ground_pos_to_chunk_coord({ -CHUNK_GROUND_ROW_COUNT, -CHUNK_GROUND_ROW_COUNT }), Vector2i{-2, -2})
}
