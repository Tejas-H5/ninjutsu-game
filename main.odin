package main

import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(0, 0, "Ninja")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})
	set_logging_type(.Fmt)

	defer rl.CloseWindow()

	state := new(GameState)
	load_all_assets(state)

	for !rl.WindowShouldClose() {
		run_game(state)

		if state.requested_quit {
			break
		}
	}
}
