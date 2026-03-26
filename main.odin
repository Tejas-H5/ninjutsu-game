package main

import rl "vendor:raylib";

main :: proc() {
	rl.InitWindow(0, 0, "Ninja")
	rl.SetWindowState({.WINDOW_MAXIMIZED, .WINDOW_RESIZABLE})

	defer rl.CloseWindow();

	state: GameState

	for !rl.WindowShouldClose() {
		run_game(&state)

		if state.requested_quit {
			break;
		}
	}
}
