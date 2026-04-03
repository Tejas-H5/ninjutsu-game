package game

import rl "vendor:raylib";

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

// Its a static object that doesn't move. Maybe 'Decoration' is not quite the right word.
Decoration :: struct {
	pos  : Vector2,
	size : f32,
	hitbox_size  : Vector2,
	type : DecorationType,
}

GameStateView :: enum {
	Start,
	Game,
}

GameState :: struct {
	player: Player,
	input: GameInput,

	enemies: [MAX_ENEMIES]Enemy,
	allocated_enemies: []Enemy,

	// Consider - we will need to do this in a more dynamic way somehow?
	decorations: [dynamic]Decoration,

	window_size : Vector2,
	camera_pos  : Vector2,
	camera_zoom : f32,

	physics_dt: f32,
	physics: SparsePyramid,
	grids: [2]SparseGrid,

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

GameInput :: struct {
	// The actual meanings could change at any time

	button1   : bool, // Slash input
	button2   : bool, // Walking input
	direction : Vector2,
	submit    : bool,
	cancel    : bool,

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
	Ground,
}

ENVIRONMENT_TYPES := [EnvironmentType]Vector2i {
	.Ground = {0, 0}
}

DecorationType :: enum {
	DeadTree1,
	DeadTree2,
}

DECORATION_TYPES := [DecorationType]Vector2i {
	.DeadTree1 = {0, 0},
	.DeadTree2 = {1, 0},
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

