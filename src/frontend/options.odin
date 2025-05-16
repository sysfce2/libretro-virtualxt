#+private

// Copyright (c) 2019-2025 Andreas T Jonsson <mail@andreasjonsson.se>
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software
//    in a product, an acknowledgment in the product documentation would be
//    appreciated but is not required.
//
// 2. Altered source versions must be plainly marked as such, and must not be
//    misrepresented as being the original software.
//
// 3. This notice may not be removed or altered from any source
//    distribution.

package frontend

import "core:log"
import "core:strconv"
import "core:strings"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine"

glabios := true
glatick := true
enable_vga := false
enable_ems := true
enable_rifs := true
enable_186 := true
flag_286 := false

reset_default_disk, floppy_boot_prio: bool
gdb_server, gdb_halt: bool

options := [?]retro.variable {
	{"virtualxt_reset_default_disk", "Reset default disk; false|true"},
	{"virtualxt_boot_priority", "Boot priority; FD|HD"},
	{"virtualxt_video", "Video standard; CGA|VGA"},
	{"virtualxt_cpu_frequency", "CPU frequency; 4.77MHz|7.15MHz|14.3MHz"},
	{"virtualxt_186", "186 instructions; true|false"},
	{"virtualxt_flag_286", "286 flag register; false|true"},
	{"virtualxt_ems", "EMS memory; true|false"},
	{"virtualxt_bios", "BIOS; GLaBIOS 0.2.6|TurboXT 3.1"},
	{"virtualxt_rtc", "RTC type; " + ("GLaTICK 0.8.4|none" when ODIN_OS != .Freestanding else "unavailable")},
	{"virtualxt_rifs", "Host RIFS2; " + ("true|false" when ODIN_OS != .Freestanding else "unavailable")},
	{"virtualxt_gdb", "GDB server; " + ("false|true" when #config(VXT_GDBSTUB, false) else "unavailable")},
	{"virtualxt_gdb_halt", "Wait for debugger; " + ("false|true" when #config(VXT_GDBSTUB, false) else "unavailable")},
	{},
}

check_variables :: proc() {
	var := retro.variable {
		key = "virtualxt_cpu_frequency",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		log.infof("Configure CPU frequency: %s", var.value)
		n, _, ok := strconv.parse_f64_prefix(string(var.value))
		assert(ok)
		machine.configure("machine", "cpu_frequency", uint(n * 1000000))
	}

	var = retro.variable {
		key = "virtualxt_186",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		enable_186, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_flag_286",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		flag_286, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_reset_default_disk",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		reset_default_disk, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_boot_priority",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		floppy_boot_prio = var.value == "FD"
	}

	var = retro.variable {
		key = "virtualxt_video",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		enable_vga = var.value == "VGA"
	}

	var = retro.variable {
		key = "virtualxt_bios",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		glabios = strings.has_prefix(string(var.value), "GLaBIOS")
	}

	var = retro.variable {
		key = "virtualxt_rtc",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		glatick = strings.has_prefix(string(var.value), "GLaTICK")
	}

	var = retro.variable {
		key = "virtualxt_ems",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		enable_ems, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_rifs",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		enable_rifs, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_gdb",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		gdb_server, _ = strconv.parse_bool(string(var.value))
	}

	var = retro.variable {
		key = "virtualxt_gdb_halt",
	}
	if (retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE, &var) && (var.value != nil)) {
		gdb_halt, _ = strconv.parse_bool(string(var.value))
	}
}
