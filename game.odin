package main

import "core:c"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib";

DASH_MULTIPLIER_MAX :: 5
DASH_DECAY :: 10
KNOCKBACK_MAGNITUDE :: 10000
INITIAL_PLAYER_HEALTH :: 100
PLAYER_DAMAGE :: 100

QUARTER_TURN :: math.PI / 2

PLAYER_WALKING_SEQUENCE := [?]int { 0, 1, 2, 1, 0, 3, 4, 3, }
PLAYER_DEATH_SEQUENCE   := [?]int { 5, 6, 7 }
SLASHING_SEQUENCE       := [?]int { 2 } // TODO: dedicated sprite?

ENEMIES :: true
DEBUG_LINES :: false

PlayerActionState :: enum {
	Nothing,
	Slashing,
	Dashing,
	KnockedBack,
}

Player :: struct {
	prev_position : Vector2,
	pos           :  Vector2,
	size          : f32,
	hitbox_size   : Vector2,
	health        : f32,
	velocity      : Vector2,

	slash_start_pos : Vector2,
	move_speed      : f32,
	dash_multiplier : f32,
	dash_ran_out    : bool,
	opacity         : f32,
	action          : PlayerActionState,

	knockback              : Vector2,
	direction_input        : Vector2,
	target_direction_input : Vector2,

	sprite: rl.Texture2D,
	animation: AnimationState,
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
	size                   : f32,
	hitbox_size            : Vector2,
	hit_cooldown           : f32,
	damage_player_cooldown : f32,
	velocity               : Vector2,
	health                 : f32,
	dead_duration          : f32,

	animation  : AnimationState,
}

GameState :: struct {
	player: Player,

	stats: struct {
		deaths: int,
	},

	enemies: [1000]Enemy,
	allocated_enemies: []Enemy,

	window_size: Vector2,
	camera_pos: Vector2,
	camera_zoom: f32,

	physics_dt: f32,
	time: f64,
	time_since_physics_update: f32,

	ui: struct {
		resurrect_or_quit: struct {
			idx: int,
			got_axis: bool,
		},
	},

	requested_quit: bool,
}

add_empty_enemy :: proc(state: ^GameState) -> ^Enemy {
	idx := len(state.allocated_enemies)
	if len(state.enemies) == idx {return nil}

	enemy := &state.enemies[idx]
	state.allocated_enemies = state.enemies[0: idx + 1]

	enemy^ = {}

	return enemy
}

get_direction_input :: proc() -> Vector2 {
	x: f32 = 0
	if rl.IsKeyDown(.LEFT) {
		x = -1
	} else if rl.IsKeyDown(.RIGHT) {
		x = +1
	}

	y: f32 = 0
	if rl.IsKeyDown(.DOWN) {
		y = -1
	} else if rl.IsKeyDown(.UP) {
		y = +1
	}

	return linalg.normalize0(Vector2{x, y})
}

init_game :: proc(state: ^GameState) {
	player := &state.player; {
		player.move_speed = 2000
		player.size = 100
		player_area := f32(13.0 / 32.0) * player.size
		player.hitbox_size = Vector2{player_area, player_area}
		player.health = INITIAL_PLAYER_HEALTH;
		player.sprite = rl.LoadTexture("./assets/sprite1.png")
	}

	for i in 0..<10 {
		enemy := add_empty_enemy(state)
		enemy.pos = {f32(i) * 200, 400}
		enemy.size = 100
		enemy_area := f32(13.0 / 32.0) * enemy.size
		enemy.hitbox_size = Vector2{enemy_area, enemy_area}
		enemy.health = 10
	}

	state.physics_dt = 1.0 / 120.0
	state.time = rl.GetTime()
}

estimate_decent_intercept_point :: proc(
	current_pos: Vector2, capable_speed: f32, 
	target_pos, target_vel: Vector2
) -> Vector2 {
	// Don't overthink it. for now
	return target_pos + 4 * target_vel
}

update_all_animations :: proc(state: ^GameState) {
	dt := state.physics_dt

	target_camera_pos  := state.camera_pos
	target_camera_zoom := state.camera_zoom

	player := &state.player;
	player_hitbox := hitbox_from_pos_size(player.pos, player.hitbox_size)
	input_vector := player.direction_input
	input_vector_len := linalg.length(input_vector);

	player_damage := f32(0)
	player_is_alive := is_player_alive(state)

	if ENEMIES {
		enemy_move_speed :: 1100

		for &enemy, enemy_idx in state.allocated_enemies {
			if enemy.hit_cooldown > 0    {enemy.hit_cooldown -= 5 * dt}

			enemy_is_alive := enemy.health > 0

			prev_pos := enemy.pos

			if player_is_alive && enemy_is_alive {
				// Move towards the player
				{
					target: Vector2

					to_player := linalg.normalize0(player.pos - enemy.pos)
					to_where_player_will_be := linalg.normalize0(
						estimate_decent_intercept_point(enemy.pos, enemy_move_speed, player.pos, player.velocity) - 
						enemy.pos
					)

					enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)

					target = to_where_player_will_be

					directions_to_try := [?]Vector2{
						Vector2{target.x, target.y},    // Towards target
						Vector2{-target.y, target.x},   // Perpendicular
						Vector2{target.y, -target.x},   // Other perpendicular
						-Vector2{target.x, target.y},   // Away from target
					}

					for dir in directions_to_try {
						prev_pos := enemy.pos
						enemy.pos += enemy_move_speed * dir * dt
						enemy_hitbox = hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)

						rolled_back := false

						// But they need to not bump into each other tho you know what im sayin
						for &other_enemy, i_other in state.allocated_enemies {
							if enemy_idx == i_other {continue}

							other_enemy_hitbox := hitbox_from_pos_size(other_enemy.pos, other_enemy.hitbox_size)
							hit := collide_box_with_box(enemy_hitbox, other_enemy_hitbox) 
							if hit {
								// Space is occupied. roll back the change, recompute hitbox
								enemy.pos = prev_pos
								enemy.pos -= to_player * dt
								rolled_back = true
								break;
							}
						}

						if !rolled_back {break}
					}
				}

				// Damage player
				{
					enemy_hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)

					if enemy.damage_player_cooldown > 0.0001 {
						enemy.damage_player_cooldown -= 10 * dt
					} else {
						// Player can phase through enemies when dashing. Some real ninja samurai type shit
						player_can_take_damage := player_is_alive && player.action == .Nothing

						if player_can_take_damage {
							hit := collide_box_with_box(player_hitbox, enemy_hitbox)
							if hit {
								// Damage the player
								enemy.damage_player_cooldown = 1
								player.knockback = KNOCKBACK_MAGNITUDE * linalg.normalize0(player.pos - enemy.pos)
								player.action    = .KnockedBack

								player_damage += 10;
							}
						}
					}
				}
			}

			// Enemy sprite animation
			enemy.velocity = enemy.pos - prev_pos
			step_person_animation(
				state,
				&enemy.animation,
				enemy.velocity,
				enemy.health > 0,
				false,
				&enemy.dead_duration
			)
		}
	}

	// Player
	{
		// Allows for aiming, _and_ turning/stopping on a dime.
		switch {
		case !player_is_alive:
			player.direction_input = {}
		case player.action == .Nothing:
			switch{
			case linalg.dot(player.direction_input, player.target_direction_input) < 0.5:
				player.direction_input = player.target_direction_input
			case:
				responsiveness := f32(20)
				player.direction_input = linalg.lerp(player.direction_input, player.target_direction_input, responsiveness * dt)
			}
		case:
			// player.direction_input to remain unchanged
		}

		target_opacity := f32(1.0)
		if player.action == .Dashing {
			target_opacity = 0.0
		}

		phase_speed :: 100
		player.opacity = lerp(player.opacity, target_opacity, dt * phase_speed)

		// Player Movement
		{
			if player.action == .KnockedBack {
				player.velocity = player.knockback
				knockback_decay :: 30.0
				if linalg.length(player.knockback) > 1 {
					player.knockback = linalg.lerp(player.knockback, Vector2{0, 0}, dt * knockback_decay)
				} else {
					player.action = .Nothing
				}
			} else {
				move_speed := player.move_speed * player.dash_multiplier
				player.velocity = input_vector * move_speed
			}

			player.prev_position = player.pos
			player.pos += player.velocity * dt

			if player.action == .Slashing {
				// Damage enemies
				damage_ray := ray_from_start_end(player.prev_position, player.pos)

				for &enemy in state.allocated_enemies {
					can_apply_damage := false

					if enemy.hit_cooldown <= 0 {
						hitbox := hitbox_from_pos_size(enemy.pos, enemy.hitbox_size)
						hit, info := collide_ray_with_box(damage_ray, hitbox)
						if hit {
							can_apply_damage = true
						}
					}

					if can_apply_damage {
						enemy.health -= PLAYER_DAMAGE
						enemy.hit_cooldown = 1
					}
				}
			}

			// Player sprite animation
			sink : f32 = 0
			step_person_animation(
				state,
				&player.animation,
				input_vector,
				player_is_alive,
				player.action == .Slashing,
				&sink,
			)
		}

		// Dash/Slash decay
		player.dash_multiplier = lerp(player.dash_multiplier, 1, dt * DASH_DECAY)
		if player.dash_multiplier < 1.1 {
			if player.action == .Dashing || player.action == .Slashing {
				player.action       = .Nothing
				player.dash_ran_out = true
			}
		}
	}

	if player_damage > 0 {
		player.health -= player_damage

		if player.health <= 0 {
			// Gotta do something. I don't know what yet
		}
	}

	// camera
	{
		target_camera_pos = player.pos;
		target_camera_zoom = lerp(f32(0.5), f32(0.45), input_vector_len)

		camera_pos_speed :: 20.0
		state.camera_pos = linalg.lerp(state.camera_pos, target_camera_pos, dt * camera_pos_speed)

		camera_zoom_speed :: 20.0
		state.camera_zoom = linalg.lerp(state.camera_zoom, target_camera_zoom, dt * camera_zoom_speed)
	}

	// Kill off any dead enemies
	{
		for i := 0; i < len(state.allocated_enemies); i += 1 {
			enemy := state.allocated_enemies[i]
			if enemy.dead_duration > 3 {
				unordered_remove_slice(&state.allocated_enemies, i)
				i -= 1;
			}
		}
	}
}

lerp :: proc(a, b, t: f32) -> f32 {
	if t < 0 {return a}
	if t > 1 {return b}
	return math.lerp(a, b, t)
}

is_player_alive :: proc(state: ^GameState) -> bool {
	return state.player.health > 0
}

render_frame :: proc(state: ^GameState) {
	player := state.player
	player_is_alive := is_player_alive(state)

	has_submit_input := rl.IsKeyPressed(.ENTER)

	if ENEMIES {
		for &enemy in state.allocated_enemies {
			normal_color := rl.Color{ 0, 0, 255, 255}
			hit_color    := rl.Color{ 255, 0, 0, 255}
			color        := rl.ColorLerp(normal_color, hit_color, enemy.hit_cooldown)
			render_person_sprite(
				state,
				enemy.pos, enemy.size, color,
				enemy.animation, enemy.velocity, player.sprite,
			)
		}
	}

	// player
	{
		color := rl.Color{0,0,0, u8(player.opacity * 255)}

		if DEBUG_LINES {
			draw_line(state, player.pos, player.pos + player.direction_input * 400, 2,  {255, 0, 0, 255});
		}

		if player.dash_multiplier > 1.1 {
			t := (player.dash_multiplier - 1) / (DASH_MULTIPLIER_MAX - 1)

			#partial switch player.action {
			case .Slashing:
				// Maybe the damage ray should also be extended like this ?
				dash_to_player := player.pos - player.slash_start_pos
				l := linalg.length(dash_to_player)
				follow_through := player.size
				end := player.slash_start_pos + (l + follow_through) * linalg.normalize0(dash_to_player)
				line_thickness := f32(10)
				draw_line(state, player.slash_start_pos, end, t * line_thickness,  color);
			case .Dashing:
				// Nothing, yet
			}
		}

		switch player.action {
			case .Nothing:  // Nothing. yet
			case .Slashing: // Nothing. yet
			case .Dashing:  // Nothing. yet
			case .KnockedBack:
				color.r = u8(lerp(255, 0, linalg.length(player.knockback) / KNOCKBACK_MAGNITUDE))
		}

		render_person_sprite(
			state,
			player.pos, player.size, color,
			player.animation, player.direction_input, player.sprite
		)

		if DEBUG_LINES {
			draw_rect(state, player.pos, player.hitbox_size, color, .Outline)
		}
	}

	// UI
	{
		switch {
		case !player_is_alive:
			input := get_direction_input()
			choices := 2
			switch {
			case input.x < -0.5:
				if !state.ui.resurrect_or_quit.got_axis {
					state.ui.resurrect_or_quit.got_axis = true
					state.ui.resurrect_or_quit.idx -= 1
					if state.ui.resurrect_or_quit.idx < 0 {
						// state.ui.resurrect_or_quit.idx = choices - 1
						state.ui.resurrect_or_quit.idx = 0
					}
				}
			case input.x > 0.5:
				if !state.ui.resurrect_or_quit.got_axis {
					state.ui.resurrect_or_quit.got_axis = true
					state.ui.resurrect_or_quit.idx += 1
					if state.ui.resurrect_or_quit.idx >= choices {
						// state.ui.resurrect_or_quit.idx = 0
						state.ui.resurrect_or_quit.idx = choices - 1
					}
				}
			case:
				state.ui.resurrect_or_quit.got_axis = false
			}

			center := Vector2{
				state.window_size.x / 2,
				2 * state.window_size.y / 3,
			}
			size : UiSize = 100

			resurrect_text := ui_text(fmt_tprintfcstr("Resurrect"), size)
			quit_text := ui_text(fmt_tprintfcstr("Quit"), size)

			height := size
			selector_size := height
			width := resurrect_text.width + quit_text.width + selector_size + selector_size

			x := c.int(center.x) - width / 2
			y := c.int(center.y) - size / 2

			// Draw background
			{
				color := rl.Color{ 0, 0, 0, 100 }
				y := c.int(center.y) - height / 2
				rl.DrawRectangle(x, y, width, height, color)
			}

			color: rl.Color
			is_chosen: bool

			current_choice := 0
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? rl.Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
			resurrect_choice := current_choice

			// Selector
			if is_chosen {
				selector_center := Vector2i{ x + selector_size / 2, y + selector_size / 2 }
				selector_inner_size := c.int(selector_size / 2)
				x := selector_center.x - selector_inner_size / 2
				y := selector_center.y - selector_inner_size / 2
				rl.DrawRectangle(x, y, selector_inner_size, selector_inner_size, color)
			}
			x += selector_size

			// Resurrect button
			{
				rl.DrawText(resurrect_text.text, x, y, size, color)
				x += resurrect_text.width
			}

			current_choice += 1
			is_chosen = current_choice == state.ui.resurrect_or_quit.idx
			color = is_chosen ? rl.Color{ 255, 0, 0, 255 } : rl.Color{ 0, 0, 0, 255 }
			quit_choice := current_choice
			
			// Selector
			if is_chosen {
				selector_center := Vector2i{ x + selector_size / 2, y + selector_size / 2 }
				selector_inner_size := c.int(selector_size / 2)
				x := selector_center.x - selector_inner_size / 2
				y := selector_center.y - selector_inner_size / 2
				rl.DrawRectangle(x, y, selector_inner_size, selector_inner_size, color)
			}
			x += selector_size

			// Quit button
			{
				rl.DrawText(quit_text.text, x, y, size, color)
				x += quit_text.width
			}

			// Dont want to accidentally choose when slashing
			if has_submit_input {
				switch {
				case state.ui.resurrect_or_quit.idx == resurrect_choice:
					state.stats.deaths += 1
					player := &state.player
					player.health = INITIAL_PLAYER_HEALTH
				case state.ui.resurrect_or_quit.idx == quit_choice:
					state.requested_quit = true
				}
			}
		case:
			state.ui.resurrect_or_quit.idx = 0
			state.ui.resurrect_or_quit.got_axis = false
		}

		// Debug text (TODO: rewrite)
		{
			y      : c.int = 10
			size   : c.int = 30
			offset : c.int = size + 10

			// TODO: proper health bar
			rl.DrawText(rl.TextFormat("health: %v", player.health), 10, y, size, {0, 0,0, 255})
			y += offset

			rl.DrawText(rl.TextFormat("action: %v", player.action), 10, y, size, {0, 0,0, 255})
			y += offset

			//
			// for e, i in state.enemies {
			// 	if i >= state.total_enemies {break}
			// 	rl.DrawText(rl.TextFormat("cooldown %v: %v", i, e.damage_player_cooldown), 10, y, size, {0, 0,0, 255})
			// 	y += offset
			// }
		}
	} 
}

render_person_sprite :: proc(
	state: ^GameState,
	pos: Vector2, size: f32, color: rl.Color,
	animation: AnimationState, direction: Vector2, spritesheet: rl.Texture2D
) {
	sprite_idx: int
	switch animation.phase {
	case .Walking:
		sprite_idx = PLAYER_WALKING_SEQUENCE[animation.idx]
	case .Death:
		sprite_idx = PLAYER_DEATH_SEQUENCE[animation.idx]
	case .Slashing:
		sprite_idx = SLASHING_SEQUENCE[animation.idx]
	}
	angle := math.atan2(-direction.y, direction.x)
	draw_rect_textured_spritesheet(state, pos, size, color, spritesheet, sprite_idx, angle + QUARTER_TURN)
}

run_game2 :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		state.camera_zoom = 1

		rl.ClearBackground({255, 255, 255, 255})
	} rl.EndDrawing();
}

step_spritesheet :: proc(sequence: []int, anim: ^AnimationState, interval: f32, dt: f32) -> int {
	anim.timer += dt
	if anim.timer > interval {
		anim.timer = 0
		anim.idx += 1
		if anim.idx >= len(sequence) {
			anim.idx = 0
		}
	}

	return sequence[anim.idx]
}

step_person_animation :: proc(
	state: ^GameState,
	anim: ^AnimationState,
	dir: Vector2,
	is_alive: bool,
	is_slashing: bool,
	dead_time: ^f32
) {
	input := linalg.length(dir)

	prev_phase := anim.phase

	switch {
	case !is_alive: 
		anim.phase = .Death
		// TODO: resurrecting as the reverse of the death animation
	case is_slashing:
		anim.phase = .Slashing
	case:
		anim.phase = .Walking
	}

	if prev_phase != anim.phase {
		anim.idx = 0
	}

	switch anim.phase {
	case .Walking:
		// If we stop walking, we should continue the animation till we reach idx 0, so that our arms
		// aren't stuck in a walking position.
		idx := PLAYER_WALKING_SEQUENCE[anim.idx]
		speed := 10 * state.physics_dt
		if input < 0.001 && idx == 0 {
			speed = 0
		}
		step_spritesheet(PLAYER_WALKING_SEQUENCE[:], anim, 1, speed)
	case .Death:
		speed := 4 * state.physics_dt
		if anim.idx < len(PLAYER_DEATH_SEQUENCE) - 1 {
			step_spritesheet(PLAYER_DEATH_SEQUENCE[:], anim, 1, speed)
		} else {
			dead_time^ += state.physics_dt
		}
	case .Slashing:
		if anim.idx < len(SLASHING_SEQUENCE) - 1 {
			speed := 4 * state.physics_dt
			step_spritesheet(SLASHING_SEQUENCE[:], anim, 1, speed)
		}
	}
}

run_game :: proc(state: ^GameState) {
	rl.BeginDrawing(); {
		state.window_size.x = f32(rl.GetScreenWidth())
		state.window_size.y = f32(rl.GetScreenHeight())
		rl.ClearBackground({255, 255, 255, 255})

		player := &state.player
		player_is_alive := is_player_alive(state)

		// handle game input
		if player_is_alive {
			player.target_direction_input = get_direction_input()
			has_direction_input := linalg.length(player.direction_input) > 0.5

			// No cooldowns. This is because:
			// - performing a dash/slash is already a bit tiring
			// - dashing makes the player invisible, which also makes it hard for you to know where you are
			// - dashing makes the player move much faster, which is not always ideal
			// So because they both have natural tradeoffs already, we dont need to make it feel any worse
			slash_input, dash_input := rl.IsKeyDown(.Z), rl.IsKeyDown(.X)

			if !slash_input && !dash_input {
				player.dash_ran_out = false
			} 

			if !has_direction_input || player.dash_ran_out {
				slash_input, dash_input = false, false
			}

			if player.action != .KnockedBack {
				prev_action := player.action

				// NOTE: as a result of this code, we can start dashing, and then 
				// promote to a slash mid-way. Keeping this in because why not

				if slash_input {
					player.action = .Slashing
					if prev_action != .Slashing {
						player.dash_multiplier = DASH_MULTIPLIER_MAX
						player.slash_start_pos = player.pos
					}
				} else if dash_input {
					player.action = .Dashing
					if prev_action != .Dashing {
						player.dash_multiplier = DASH_MULTIPLIER_MAX
					}
				} else {
					player.action          = .Nothing
					player.dash_multiplier = 1
				}
			}
		}

		time := rl.GetTime()
		dt := time - state.time
		state.time_since_physics_update += f32(dt)
		state.time = time
		for state.time_since_physics_update > state.physics_dt {
			state.time_since_physics_update -= state.physics_dt
			update_all_animations(state)
		}

		render_frame(state);
	} rl.EndDrawing();

	free_all(context.temp_allocator)
}
