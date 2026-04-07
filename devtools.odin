package game

import "core:c"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib";

DevtoolsMode :: enum {
	EditingOutline,
	PlacingDecorations,
}

PLACEMENT_CHOICES :: []DecorationType {
	.DeadTree1, .SeaUrchin, .LiveTree, .LiveTreeLeaves,
}

Devtools :: struct {
	dragging : bool,
	island_outline: [dynamic]Vector2i,
	shoreline_end_outline: [dynamic]Vector2i,

	has_dir_input : bool,

	outline : ^[dynamic]Vector2i,

	mode    : DevtoolsMode,
	curr_placing_idx : int,
	curr_placing_size : f32,
	placed : [dynamic]Decoration,
}

init_outline :: proc(points: []Vector2i) -> [dynamic]Vector2i {
	outline := make([dynamic]Vector2i)
	for point in points {
		append(&outline, point)
	}
	return outline
}

init_devtools :: proc(devtools : ^Devtools) {
	devtools.island_outline        = init_outline(ISLAND_POINTS)
	devtools.shoreline_end_outline = init_outline(SHORELINE_END_POINTS)

	// Current outline
	devtools.outline = &devtools.shoreline_end_outline

	devtools.mode = .PlacingDecorations
}

run_devtools :: proc(state: ^GameState, devtools: ^Devtools, phase: RenderPhase) {
	placement_choices := PLACEMENT_CHOICES
	currently_placing := placement_choices[devtools.curr_placing_idx]

	dir := state.input.direction
	dir_pressed := false
	if state.input.direction != 0 {
		if !devtools.has_dir_input {
			devtools.has_dir_input = true
			dir_pressed = true
		}
	} else {
		devtools.has_dir_input = false
	}

	{
		DebugText :: struct {
			pos: Vector2Ui,
			gap: UiSize,
			size: UiSize,
		}

		text : DebugText
		text.pos = { UiSize(state.window_size.x - 700), 10 }
		text.gap = 10
		text.size = 30

		draw_text_row :: proc(text: ^DebugText, format: UiString, args: ..any, color : Color = COL_FG) {
			rl.DrawText(rl.TextFormat(format, ..args), text.pos.x, text.pos.y, text.size, {0, 0,0, 255})
			text.pos.y += text.size + text.gap
		}

		draw_text_row(&text, "[Devtools]: %v", devtools.mode)
		switch devtools.mode {
		case .EditingOutline:
			draw_text_row(&text, "points: %v", len(devtools.outline))
		case .PlacingDecorations:
			draw_text_row(&text, "Currently placing: %v", currently_placing)
			draw_text_row(&text, "size: %v", devtools.curr_placing_size)
		}
	}

	if phase == .Render {
		if state.player.viewing_map {
			mouse_pos := to_game_pos(state, state.input.screen_position)
			ground_pos := world_pos_to_ground_pos(mouse_pos)
			ground_pos_world := ground_pos_to_world_pos(ground_pos)
			draw_rect(state, ground_pos_world + CHUNK_GROUND_HALF_OFFSET, CHUNK_GROUND_SIZE, COL_DEBUG, .Outline)
		}

		if rl.IsKeyPressed(.P) {
			log_mouse_position(state)
		}
		if rl.IsKeyPressed(.G) {
			log_ground_position(state)
		}
	}


	switch devtools.mode {
	case .EditingOutline:
		if phase == .Render {
			if len(devtools.outline) > 0 {

				if state.input.click && state.input.shift {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a, ok := get_closest_edge_point_idx(mouse_pos, devtools.outline[:])
					if ok {
						ground_pos := world_pos_to_ground_pos(mouse_pos)
						inject_at(devtools.outline, a + 1, ground_pos)

						log_outline(devtools)
					}
				} else if state.input.rclick {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a := get_closest_outline_point_idx(mouse_pos, devtools.outline[:])
					ordered_remove(devtools.outline, a)
				} else if state.input.click_hold {
					mouse_pos := to_game_pos(state, state.input.screen_position)
					a := get_closest_outline_point_idx(mouse_pos, devtools.outline[:])
					devtools.outline[a] = world_pos_to_ground_pos(mouse_pos)
					devtools.dragging = true
				} else {
					if devtools.dragging {
						devtools.dragging = false
						log_outline(devtools)
					}
				}

				for i in 1..<len(devtools.outline) {
					prev := ground_pos_to_world_pos(devtools.outline[i-1])
					curr := ground_pos_to_world_pos(devtools.outline[i])
					draw_line(state, prev, curr, 3 / state.camera.zoom, COL_DEBUG)
				}

				for point in devtools.outline {
					pos := ground_pos_to_world_pos(point)
					draw_rect(state, pos, 10 / state.camera.zoom, COL_DEBUG, .Solid)
				}
			}
		}
	case .PlacingDecorations:
		if phase == .Render {
			wheel := rl.GetMouseWheelMove()
			if wheel != 0 {
				if state.input.shift {
					wheel *= 100
				}
				devtools.curr_placing_size += wheel
				devtools.curr_placing_size = math.clamp(devtools.curr_placing_size, 20, state.large_items_grid.grid_size)
			}

			if dir_pressed {
				if dir.x > 0 {
					devtools.curr_placing_idx += 1
					if devtools.curr_placing_idx >= len(PLACEMENT_CHOICES) {
						devtools.curr_placing_idx = 0
					}
				} else if dir.x < 0 {
					devtools.curr_placing_idx -= 1
					if devtools.curr_placing_idx < 0 {
						devtools.curr_placing_idx = len(PLACEMENT_CHOICES) - 1
					}
				}
			}

			pos := to_game_pos(state, state.input.screen_position)
			col := COL_WHITE
			col.a = 125
			draw_decoration(state, currently_placing, pos, devtools.curr_placing_size, col)
			for decoration in devtools.placed {
				draw_decoration(state, decoration.type, decoration.pos, decoration.size, col)
			}

			if state.input.click {
				append(&devtools.placed, Decoration{ type=currently_placing, size=devtools.curr_placing_size, pos=pos })
				log_decorations(devtools)
			}
		}
	}
}


get_closest_outline_point_idx :: proc(mouse_pos: Vector2, points: []Vector2i) -> int {
	a := 0
	distance := math.INF_F32
	for point, i in points {
		this_distance := linalg.length(mouse_pos - ground_pos_to_world_pos(point))
		if this_distance < distance {
			distance = this_distance
			a = i
		}
	}

	return a
}

get_closest_edge_point_idx :: proc(mouse_pos: Vector2, points: []Vector2i) -> (int, bool) {
	a, b := 0, 0
	distance := math.INF_F32
	for i in 0..<len(points) {
		prev := ground_pos_to_world_pos(points[i])
		next := ground_pos_to_world_pos(points[(i + 1) % len(points)])

		mid := prev + (next - prev) / 2
		this_distance := linalg.length(mouse_pos - mid)
		if this_distance < distance {
			distance = this_distance
			a, b = i, i + 1
		}
	}	

	return a, a != b
}

// Braces were screwing up navigation, so I've just moved this templating code to the bottom
log_outline :: proc(devtools: ^Devtools) {
	debug_log_intentional("Outline so far:")
	for point in devtools.outline {
		debug_log_intentional("Vector2i {{ %v, %v },", point.x, point.y)
	}
	debug_log_intentional("Vector2i {{ %v, %v },", devtools.outline[0].x, devtools.outline[0].y)
}

log_decorations :: proc(devtools: ^Devtools) {
	debug_log_intentional("Decorations placed: ")
	for decoration in devtools.placed {
		// DecorationPlacement
		debug_log_intentional("{{ .%v, %v, {{ %v, %v }, your_colour_here },", decoration.type, decoration.size, decoration.pos.x, decoration.pos.y)
	}
}

log_mouse_position :: proc(state: ^GameState) {
	pos := to_game_pos(state, state.input.screen_position)
	debug_log_intentional("Vector2{{ %v, %v }", pos.x, pos.y)
}

log_ground_position :: proc(state: ^GameState) {
	pos := to_game_pos(state, state.input.screen_position)
	ground := world_pos_to_ground_pos(pos)
	debug_log_intentional("Vector2i{{ %v, %v }", ground.x, ground.y)
}
