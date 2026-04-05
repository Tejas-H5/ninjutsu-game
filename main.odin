package game

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(0, 0, "Ninja")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	set_logging_type(.Fmt)

	defer rl.CloseWindow()

	state := new_game_state()

	for !rl.WindowShouldClose() && !state.requested_quit {
		run_game(state)
	}
}
