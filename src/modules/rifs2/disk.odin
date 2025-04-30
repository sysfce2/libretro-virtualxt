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

package rifs2

import "core:strings"
//import "core:log"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"

host_rmdir :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.remove(cpath) == 0 {
		return .OK
	}
	return .PATH_NOT_FOUND
}

host_mkdir :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.mkdir(cpath) == 0 {
		return .OK
	}
	return .PATH_NOT_FOUND
}

host_exists :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return (retro_callbacks.vfs.stat(cpath, nil) & retro.VFS_STAT_IS_VALID) != 0
}

host_is_dir :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return (retro_callbacks.vfs.stat(cpath, nil) & retro.VFS_STAT_IS_DIRECTORY) != 0
}

host_rename :: proc(from, to: string) -> Response {
	cfrom := strings.clone_to_cstring(from, context.temp_allocator)
	cto := strings.clone_to_cstring(to, context.temp_allocator)
	if retro_callbacks.vfs.rename(cfrom, cto) == 0 {
		return .OK
	}
	return .PATH_NOT_FOUND
}

host_delete :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.remove(cpath) == 0 {
		return .OK
	}
	return .PATH_NOT_FOUND
}
