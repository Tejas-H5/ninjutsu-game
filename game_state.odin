package game

import "core:math"
import rl "vendor:raylib";
import hm "core:container/handle_map"

MAX_TRANSPARENT_DECOR :: 16

// Most likely too large. Let's tighten this later
MAX_CHUNKS_LOADED :: 100

ChunkCoordPair :: struct{ chunk: ^Chunk, coord: Vector2i }

Handle :: hm.Handle32

EntityId :: distinct int
ENTITY_ID_INVALID :: EntityId(0)
ENTITY_ID_PLAYER  :: EntityId(1)

GameState :: struct {
	player : Player,
	input  : GameInput,

	dt : f32,
	unscaled_dt : f32,

	// Only the proximity triggers will be loaded/unloaded this way for now.
	chunks_loaded     : [dynamic; MAX_CHUNKS_LOADED]ChunkCoordPair,
	// If a player is underneath a tree for instance, we should make that tree transparent. this helps with that
	transparent_decor : [dynamic; MAX_TRANSPARENT_DECOR]i32, 
	entities          : hm.Static_Handle_Map(MAX_ENTITIES, Entity, Handle),
	last_entity_id    : EntityId,

	chunks     : map[Vector2i]Chunk,
	physics_dt : f32,
	physics    : SparsePyramid,

	grids_backing_store : [2]SparseGrid,
	entity_grid, large_items_grid : ^SparseGrid,

	window_size : Vector2,
	camera : Camera2D,

	time: f64,
	time_since_physics_update: f32,

	ui: struct {
		resurrect_or_quit : struct {
			idx: int,
			got_axis: bool,
		},
		npc_dialog : struct {
			entity    : Handle,
			text      : string,
			text_idxf : f32,
		}
	},

	requested_quit : bool,
	view           : GameStateView,
	previous_view  : GameStateView,

	// currently unused -----

	stats: struct {
		deaths: int,
	},

	assets: GameAssets,

	// World creation state
	offset : Vector2i,
}

EntityActionState :: enum {
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
	entity : ^Entity,

	interaction : ^SparseGridItem,

	camera_lock       : bool,
	camera_lock_pos   : Vector2,
	viewing_map       : bool, // perhaps shouldn't be on the player?
	map_camera        : Camera2D,
	map_camera_target : Camera2D,

	slash_points_idx: int,
	slash_points_len: int,

	slash_timer     : f32,
	block_slash     : bool,

	last_entity_collision_handle : Handle,

	// Stores the slash path. It's a ringbuffer, so that its not infinite.
	slash_points : [4096]SlashPoint,
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


// Anything that can move. Perhaps not the right name?
Entity :: struct {
	action : EntityActionState,
	knockback    : Vector2,

	handle : Handle,

	id : EntityId,

	// TODO: clean this up
	pos         : Vector2,
	prev_pos    : Vector2,
	target_pos  : Vector2,
	move_speed  : f32,
	size        : f32,
	hitbox_size : Vector2,
	last_entity_collision_handle : Handle,

	// Some redundancy here, but it's all useful imo.
	angle        : f32,  
	target_angle : f32,  
	velocity : Vector2,
	// target_pos   : Vector2,  

	type        : CharacterType,
	color       : Color,
	usual_color : Color,
	animation   : AnimationState,

	can_interact           : bool,
	can_damage_player      : bool, // TODO: remove

	update_fn : EntityUpdateFn,

	// A tiny amount of data, but in theory, I can store all kinds of state here using state machine pattern.
	// This will be consumed by the update_fn, and drive simple behaviours like talking a list of points, or
	// more complicated sequences of events a character might take. 
	// The fields are used differently by different entities. 
	memory : struct {
		dialog      : ^DialogNode,
		last_dialog : ^DialogNode,
		state       : MemoryStates,
		// timer : f32,
	},

	health        : f32,
	hit_cooldown  : f32,
	dead_duration : f32,

	reorient_timer : f32,
	reorient_time_to_next : f32,
}

MemoryStates :: enum u8 {
	Default,
	Attacking,
	AttackFailed,
}

MemoryTurn :: enum u8 {
	Mine, 
	Theirs,
}

EntityUpdateFn :: #type proc(entity: ^Entity, state: ^GameState, event: EntityUpdateEventType)

// Nothing here should be called every frame.
// These updates must be 'game logic', not physics simulation or animation logic.
EntityUpdateEventType :: enum {
	Loaded,           // This entity was just loaded in
	PlayerInteracted, // Player pressed X on this entity
	DialogComplete,   // This entity's current dialog just completed
	Death,			  // This instant this entity just died. The death animation has only just started
	UnloadedMovedTooFarAway,  // The player moved too far away from this entity, so the game has decided to unload it
	UnloadedDeath,		// This entity has been dead for a while, so the game has decided to unload it('s corpse)
	CollidedWithPlayer, // The player just bumped into this entity
	ReOrient,			// A semi-frequent signal sent to every entity to decide what they want to do next
}

GameStateView :: enum {
	Start,
	Game,
}

GameInput :: struct {
	// The actual meanings could change at any time

	button1   : bool, // Slash input, interacting
	button1_press  : bool, 

	button2   : bool, // Walking input
	button2_press  : bool, // Walking input

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
	chacracters : Spritesheet,
	environment : Spritesheet,
	decorations : Spritesheet,
}


EnvironmentType :: enum {
	None, Ground, Solid, Water,
}

@(rodata)
ENVIRONMENT_TYPES := [EnvironmentType]Vector2i {
	.None   = {0, 0}, .Ground = {1, 0}, .Solid = {2, 0}, .Water = {3, 0}
}

DecorationType :: enum {
	DeadTree1, SeaUrchin, LiveTreeLeaves, LiveTree, 
}

DecorationInfo :: struct {
	spritesheet_coord : Vector2i, 
	hitbox_size: f32,
}

@(rodata)
DECORATION_TYPES := [DecorationType]DecorationInfo {
	.DeadTree1 = {{0, 0}, 13}, .SeaUrchin = {{1, 0}, 13}, .LiveTreeLeaves = {{2, 0}, 0}, .LiveTree = {{3, 0}, 13}, 
}

CharacterType :: enum {
	Stickman,
	Blob, 
}

CharacterInfo :: struct {
	row_idx: int,
	hitbox_size: f32,
}

@(rodata)
CHARACTER_TYPES := [CharacterType]CharacterInfo{
	.Stickman = {0, 13},
	.Blob     = {1, 25},
}

should_be_transparent_when_player_is_under :: proc(t: DecorationType) -> bool {
	return t == .DeadTree1 || 
	       t == .LiveTree ||
	       t == .LiveTreeLeaves
}


EntityType :: enum int {
	Entity,
	Decoration,
}

LAYER_MASK_DAMAGE            :: LayerMask(u32(1 << 0))
LAYER_MASK_OBSTRUCTION       :: LayerMask(u32(1 << 1))
LAYER_MASK_ENEMY             :: LayerMask(u32(1 << 2))
LAYER_MASK_PLAYER            :: LayerMask(u32(1 << 3))
LAYER_MASK_TRANSPARENT_COVER :: LayerMask(u32(1 << 4))
LAYER_MASK_INTERACTION       :: LayerMask(u32(1 << 5))

LoadEventFn :: #type proc(state: ^GameState, event: LoadEvent)

LoadEvent :: struct {
	// When this chunk is loaded and in the viewport, we may want to do something.
	// Spawn entities, start an encounter, etc. etc. etc.
	// Rather than a trigger at a specific location, a proximity trigger
	// should tell the game to then place a more specific trigger at the right position.
	pos    : Vector2,
	load   : LoadEventFn,
	data   : LoadEventData,
}

LoadEventData :: struct {
	// Unique NPCs get their own load event, but sometimes we might want to batch spawn stuff in which case this wont apply ...
	dialog: ^DialogNode,
}

// Its a static object that doesn't move. Maybe 'Decoration' is not quite the right word.
Decoration :: struct {
	pos         : Vector2,
	size        : f32,
	type        : DecorationType,
	hitbox_size : Vector2,
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

get_chunk_iter_excluding_surroundings :: proc(state: ^GameState, bottom_left, top_right: Vector2) -> ChunkIterator {
	low := pos_to_chunk_coord(bottom_left)
	return {
		state = state,
		low   = low,
		pos   = low,
		hi    = pos_to_chunk_coord(top_right) + {1, 1},
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
		} 

		if it.pos.x == it.hi.x {
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
CHUNK_NUM_PROXIMITY_TRIGGERS :: 4

Chunk :: struct {
	idx    : int,
	loaded : bool,

	decorations : [dynamic; CHUNK_NUM_DECORATIONS]Decoration,
	ground      : [CHUNK_GROUND_ARRAY_COUNT]GroundDetails,
	loadevents  : [dynamic; CHUNK_NUM_PROXIMITY_TRIGGERS]LoadEvent,
}

get_chunk_decoration_id :: proc(chunk: ^Chunk, idx: int) -> i32 {
	// i32 because I want it to be the same size as Handle, so we can do transmute(Handle)id
	return i32(chunk.idx * CHUNK_NUM_DECORATIONS + idx)
}

EdgeDirection :: enum u8 {
	NotSet,
	Up,
	Down,
}

GroundDetails :: struct{
	type : EnvironmentType,
	tint : Color,
	z    : int,
	edge_dir : EdgeDirection, // used for filling shapes
}


