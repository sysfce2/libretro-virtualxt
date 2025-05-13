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
import "core:slice"
import "core:log"
import "base:runtime"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"

host_rmdir :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.remove(cpath) == 0 {
		return .OK
	}
	log.warnf("RMDIR: %s (PATH_NOT_FOUND)", path)
	return .PATH_NOT_FOUND
}

host_mkdir :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.mkdir(cpath) == 0 {
		return .OK
	}
	log.warnf("MKDIR: %s (PATH_NOT_FOUND)", path)
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
	log.warnf("RENAME: %s -> %s (PATH_NOT_FOUND)", from, to)
	return .PATH_NOT_FOUND
}

host_delete :: proc(path: string) -> Response {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if retro_callbacks.vfs.remove(cpath) == 0 {
		return .OK
	}
	log.warnf("DELETE: %s (PATH_NOT_FOUND)", path)
	return .PATH_NOT_FOUND
}

host_openfile :: proc(process: ^Process, path: string, attrib: u16, payload: []byte) -> Response {
	data := payload_as(payload, struct #packed {
		handle, attrib, time, date: u16,
		size: u32,
	})
	runtime.mem_zero(data, size_of(data^))

	new_handle: u16
	new_fp: ^^retro.vfs_file_handle
	
	for fp, handle in process.files {
		if fp == nil {
			new_handle = u16(handle)
			new_fp = &process.files[handle]
			break
		}
	}

	if new_fp == nil {
		new_handle = u16(append(&process.files, nil) - 1)
		new_fp = &process.files[new_handle]
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	mode: u32 = retro.VFS_FILE_ACCESS_READ_WRITE | retro.VFS_FILE_ACCESS_UPDATE_EXISTING
	
	if attrib == 0 {
		mode = retro.VFS_FILE_ACCESS_READ
	} else if attrib == 1 {
		mode = retro.VFS_FILE_ACCESS_WRITE
	}
	
	fp := retro_callbacks.vfs.open(cpath, mode, 0)
	if fp == nil {
		log.warnf("OPENFILE: %s (FILE_NOT_FOUND)", path)
		return .FILE_NOT_FOUND
	}

	if file_size := retro_callbacks.vfs.size(fp); (file_size < 0) || (file_size > 0x7FFFFFFF) {
		log.warnf("OPENFILE: %s (VFS size)", path)
		retro_callbacks.vfs.close(fp)
		return .FILE_NOT_FOUND
	} else {
		data.size = u32(file_size)
	}

	// TODO: Fix time and date!
	
	data.attrib = attrib
	data.handle = new_handle
	new_fp^ = fp
	return .OK
}

host_findnext :: proc(process: ^Process, payload: []byte) -> Response {
	// Reference: https://www.stanislavs.org/helppc/int_21-4e.html
	//            https://jeffpar.github.io/kbarchive/kb/043/Q43144

	Offset :: enum {
		ATTRIBUTE = 0x15,
		FILESIZE = 0x1A,
		FILENAME = 0x1E,
	}

	slice.zero(payload[0:43])
	runtime.memset(&payload[Offset.FILENAME], 0x20, 12)
	
	// Are we looking for the disk lable?
	if bool(process.attrib & 0x8) {
		payload[Offset.ATTRIBUTE] = 0x8
		runtime.copy_from_string(payload[Offset.FILENAME:], "HOST")
		return .OK
	}

	if process.dir == nil {
		log.warn("FINDNEXT: Called before FINDFIRST")
		return .NO_MORE_FILES
	}

	ta := context.temp_allocator
	using retro_callbacks.vfs
	
	for readdir(process.dir) {
		is_dir := dirent_is_dir(process.dir)
		cname := dirent_get_name(process.dir)
		
		if is_dir && !bool(process.attrib & 0x10) {
			continue
		}

		name := strings.to_upper(string(cname), ta)
		parts := strings.split(name, ".", ta)

		if parts[0] == "" {
			parts = parts[1:]
		}

		if strings.has_prefix(name, ".") {			
			// Is this RIFS root?
			if process.path == "." {
				continue
			}
			if (name != ".") && (name != "..") { 
				continue
			}
			parts = {name} // Allow '.' in name.
		}

		if proc(parts: []string) -> bool {
			switch len(parts) {
				case 2:
					if len(parts[1]) > 3 {
						return true
					}
					fallthrough
				case 1:
					if len(parts[0]) > 8 {
						return true
					}
				case:
					return true
			}
			return false
		} (parts) { 
			log.warnf("FINDNEXT: Invalid DOS filename: %s", cname)
			continue
		}

		// TODO: Fix time and date!

		if is_dir {
			payload[Offset.ATTRIBUTE] = 0x10
		} else {
			str := strings.clone_to_cstring(strings.join({process.path, string(cname)}, "/", ta), ta)
			if size: i32; bool(stat(str, &size) & retro.VFS_STAT_IS_VALID) {
				payload_as(payload[Offset.FILESIZE:], i32)^ = size
			}
		}

		runtime.copy_from_string(payload[Offset.FILENAME:], parts[0])
		if len(parts) > 1 {
			runtime.copy_from_string(payload[Offset.FILENAME + Offset(8):], parts[1])
		}
		return .OK
	}

	retro_callbacks.vfs.closedir(process.dir)
	process.dir = nil
	return .NO_MORE_FILES
}

host_findfirst :: proc(process: ^Process, path: string, payload: []byte) -> Response {
	if process.dir != nil {
		retro_callbacks.vfs.closedir(process.dir)
	}

	if process.path != "" {
		delete(process.path)
		process.path = ""
	}
	
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if process.dir = retro_callbacks.vfs.opendir(cpath, false); process.dir != nil {
		process.path = strings.clone(path)
		return host_findnext(process, payload)
	}

	slice.zero(payload[0:43])
	return .PATH_NOT_FOUND
}
