package game

import "core:math"
import rl "vendor:raylib";

MAX_TRANSPARENT_DECOR :: 16

GameState :: struct {
	player: Player,
	input: GameInput,

	enemies: [dynamic; MAX_ENEMIES]Enemy,
	transparent_decor : [dynamic; MAX_TRANSPARENT_DECOR]int,

	chunks  : map[Vector2i]Chunk,
	physics_dt: f32,
	physics : SparsePyramid,

	// Static grid. size=2000
	// entity grid
	grids_backing_store : [2]SparseGrid,
	entity_grid, large_items_grid : ^SparseGrid,

	window_size : Vector2,
	camera_pos  : Vector2,
	camera_zoom : f32,

	time: f64,
	time_since_physics_update: f32,

	ui: struct {
		resurrect_or_quit: struct {
			idx: int,
			got_axis: bool,
		},
	},

	requested_quit : bool,
	view           : GameStateView,
	previous_view  : GameStateView,

	// currently unused -----

	stats: struct {
		deaths: int,
	},

	assets: GameAssets,
}


PlayerActionState :: enum {
	Nothing,
	Slashing,
	Walking,
	KnockedBack,
}

SlashPoint :: struct {
	pos: Vector2,
	slash_timer: f32,
}

Player :: struct {
	action : PlayerActionState, // Current state the player is in.

	pos, prev_position : Vector2,
	size               : f32,
	hitbox_size        : Vector2,
	health             : f32,
	velocity           : Vector2,

	camera_lock : bool,
	camera_lock_pos : Vector2,
	viewing_map : bool, // perhaps shouldn't be on the player?
	map_pos     : Vector2,
	map_target_pos     : Vector2,
	map_zoom    : f32,

	slash_points_idx: int,
	slash_points_len: int,

	slash_timer     : f32,
	block_slash     : bool,
	opacity         : f32,

	knockback    : Vector2,

	// Some redundancy here, but it's all useful imo.
	angle        : f32,  
	target_angle : f32,  
	target_pos   : Vector2,  

	sprite    : Spritesheet,
	animation : AnimationState,

	// Stores the slash path. It's a ringbuffer, so that its not infinite.
	slash_points    : [4096]SlashPoint,
}

AnimationPhase :: enum {
	Walking,
	Death,
	Slashing,
}

AnimationState :: struct {
	idx   : int,
	timer : f32,
	phase : AnimationPhase,
}

Enemy :: struct {
	pos                    : Vector2,
	prev_pos               : Vector2,
	target_pos             : Vector2,
	size                   : f32,
	move_speed             : f32,
	hitbox_size            : Vector2,
	hit_cooldown           : f32,
	damage_player_cooldown : f32,
	health                 : f32,
	dead_duration          : f32,

	animation  : AnimationState,
}


GameStateView :: enum {
	Start,
	Game,
}


GameInput :: struct {
	// The actual meanings could change at any time

	button1   : bool, // Slash input
	button2   : bool, // Walking input
	button3   : bool, // Camera lock/unlock, or interact (?)
	mapbutton : bool, // opens map. It should be far away from the other buttons, so we dont open it by accident
	direction : Vector2,
	submit    : bool,
	cancel    : bool,
	click     : bool,
	click_hold : bool,
	rclick    : bool,
	shift     : bool,

	screen_position      : Vector2,
	prev_screen_position : Vector2,
}

Spritesheet :: struct {
	texture     : Texture2D,
	sprite_size : int,
	padding     : int,
}

GameAssets :: struct {
	sprite1     : Spritesheet,
	environment : Spritesheet,
	decorations : Spritesheet,
}


EnvironmentType :: enum {
	None, Ground, Solid, Water,
}

ENVIRONMENT_TYPES := [EnvironmentType]Vector2i {
	.None   = {0, 0}, .Ground = {1, 0}, .Solid = {2, 0}, .Water = {3, 0}
}

DecorationType :: enum {
	DeadTree1, SeaUrchin, LiveTreeLeaves, LiveTree, 
}

DECORATION_TYPES := [DecorationType]DecorationInfo {
	.DeadTree1 = {{0, 0}, 13}, .SeaUrchin = {{1, 0}, 13}, .LiveTreeLeaves = {{2, 0}, 0}, .LiveTree = {{3, 0}, 13}, 
}

should_be_transparent_when_player_is_under :: proc(t: DecorationType) -> bool {
	return t == .DeadTree1 || 
	       t == .LiveTree ||
	       t == .LiveTreeLeaves
}

DecorationInfo :: struct {
	spritesheet_coord : Vector2i, 
	hitbox_size: f32,
}

EntityType :: enum u8 {
	Player,
	Enemy,
	Decoration,
}

LAYER_MASK_DAMAGE      :: LayerMask(u32(1 << 0))
LAYER_MASK_OBSTRUCTION :: LayerMask(u32(1 << 1))
LAYER_MASK_ENEMY       :: LayerMask(u32(1 << 2))
LAYER_MASK_PLAYER      :: LayerMask(u32(1 << 3))
LAYER_MASK_TRANSPARENT_COVER :: LayerMask(u32(1 << 4))

// Its a static object that doesn't move. Maybe 'Decoration' is not quite the right word.
Decoration :: struct {
	pos   : Vector2,
	size  : f32,
	type  : DecorationType,
	hitbox_size  : Vector2,
}

// COnsider; 'Chunk ground 1x1 square of enviornment terreign thinggy' -> 'Tile' ?
CHUNK_GROUND_ROW_COUNT   :: 16
CHUNK_GROUND_ARRAY_COUNT :: CHUNK_GROUND_ROW_COUNT * CHUNK_GROUND_ROW_COUNT
CHUNK_GROUND_SIZE        :: 250
CHUNK_WORLD_WIDTH        :: CHUNK_GROUND_SIZE * CHUNK_GROUND_ROW_COUNT
CHUNK_GROUND_HALF_OFFSET := Vector2{ CHUNK_GROUND_SIZE, CHUNK_GROUND_SIZE } / 2

ground_pos_to_chunk_coord :: proc(pos: Vector2i) -> Vector2i {
	round_side :: proc(x: int) -> int {
		if x >= 0 {
			return x / CHUNK_GROUND_ROW_COUNT
		}

		if x % CHUNK_GROUND_ROW_COUNT == 0 {
			return x / CHUNK_GROUND_ROW_COUNT
		}

		return (x / CHUNK_GROUND_ROW_COUNT) - 1
	}
	
	return Vector2i {
		round_side(pos.x),
		round_side(pos.y),
	}
}

ground_pos_to_world_pos :: proc(pos: Vector2i) -> Vector2 {
	return {
		f32(pos.x * CHUNK_GROUND_SIZE),
		f32(pos.y * CHUNK_GROUND_SIZE),
	}
}

world_pos_to_ground_pos :: proc(pos: Vector2) -> Vector2i {
	floor_side :: proc(x: f32) -> int {
		return int(math.floor(x / CHUNK_GROUND_SIZE))
	}

	return {
		floor_side(pos.x),
		floor_side(pos.y),
	}
}

pos_to_chunk_coord :: proc(pos: Vector2) -> Vector2i {
	chunk_v := pos / CHUNK_WORLD_WIDTH
	return Vector2i {
		int(math.floor(chunk_v.x)),
		int(math.floor(chunk_v.y)),
	}
}

chunk_coord_to_pos :: proc(coord: Vector2i) -> Vector2 {
	pos_vi := coord * CHUNK_WORLD_WIDTH
	return Vector2 {
		f32(pos_vi.x),
		f32(pos_vi.y),
	}
}

ground_at :: proc(chunk: ^Chunk, pos: Vector2i) -> ^GroundDetails {
	assert(pos.x < CHUNK_GROUND_ROW_COUNT)
	assert(pos.y < CHUNK_GROUND_ROW_COUNT)

	idx := pos.x + pos.y * CHUNK_GROUND_ROW_COUNT
	return &chunk.ground[idx]
}

ChunkIterator :: struct {
	state: ^GameState,
	low, hi, pos: Vector2i,
}

get_chunk_iter :: proc(state: ^GameState, bottom_left, top_right: Vector2) -> ChunkIterator {
	// Need to iterate surrounding chunks as well, so increment lo and hi by 1
	low := pos_to_chunk_coord(bottom_left) - {1, 1}
	return {
		state = state,
		low   = low,
		pos   = low,
		// need an exclusive bound, so iterate hi by 1 more
		hi    = pos_to_chunk_coord(top_right) + {2, 2},
	}
}

iter_chunks :: proc(it: ^ChunkIterator) -> (result: ^Chunk, pos: Vector2i, has_more: bool) {
	for {
		if it.pos.y == it.hi.y {
			has_more = false
			return
		}

		ok: bool
		pos = it.pos
		result, ok = &it.state.chunks[it.pos]

		if it.pos.x < it.hi.x {
			it.pos.x += 1
		} else {
			it.pos.x = it.low.x
			it.pos.y += 1
		}

		if ok {
			has_more = true
			return
		}
	}
}

CHUNK_NUM_DECORATIONS :: 256

Chunk :: struct {
	idx: int,
	initialized : bool,
	decorations : [dynamic; CHUNK_NUM_DECORATIONS]Decoration,
	ground      : [CHUNK_GROUND_ARRAY_COUNT]GroundDetails
}

get_chunk_decoration_id :: proc(chunk: ^Chunk, idx: int) -> int {
	return chunk.idx * CHUNK_NUM_DECORATIONS + idx
}

Direction :: enum u8 {
	NotSet,
	Up,
	Down,
}

GroundDetails :: struct{
	type : EnvironmentType,
	tint : Color,
	z    : int,
	edge_dir : Direction, // used for filling shapes
}


