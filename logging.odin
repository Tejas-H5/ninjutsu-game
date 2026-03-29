package main

import "core:log"

debug_log :: proc(fmt: string, args: ..any, location := #caller_location) {
	log.infof(fmt, ..args, location=location)
}
