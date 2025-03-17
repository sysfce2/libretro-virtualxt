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

package rom

import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine/peripheral"

ROM :: struct {
	id, name: string,
	base:     u32,
	mem:      []byte,
}

load_from_file :: proc(filename: string) -> (mem: []byte, ok: bool) {
	cfilename := strings.clone_to_cstring(filename)
	defer delete(cfilename)

	fp := retro_callbacks.vfs.open(cfilename, retro.VFS_FILE_ACCESS_READ, retro.VFS_FILE_ACCESS_HINT_NONE)
	if fp == nil {
		log.errorf("Could not load ROM file: %s", filename)
		return
	}
	defer retro_callbacks.vfs.close(fp)

	file_size := retro_callbacks.vfs.size(fp)
	if file_size <= 0 {
		log.errorf("Invalid file size (%vB): %s", file_size, filename)
		return
	}

	mem = make([]byte, file_size)
	if retro_callbacks.vfs.read(fp, &mem[0], u64(file_size)) != file_size {
		log.errorf("Could not read %vB from: %s", file_size, filename)
		delete(mem)
		return
	}

	ok = true
	return
}

config :: proc(rom: ^ROM, name, key: string, value: any) -> bool {
	if name != rom.id {
		return true
	}

	switch key {
	case "name":
		rom.name = value.(string)
	case "mem":
		switch v in value {
		case []byte:
			rom.mem = slice.clone(v)
		case string:
			rom.mem = load_from_file(v) or_return
		case:
			return false
		}
	case "base":
		switch v in value {
		case u32:
			rom.base = v
		case string:
			n, ok := strconv.parse_uint(v)
			assert(ok)
			rom.base = u32(n)
		case:
			return false
		}
		assert(rom.base & 0x7FF == 0, "ROM must be 2K aligned")
	case:
		return false
	}
	return true
}

install :: proc(using rom: ^ROM) -> bool {
	peripheral.register_memory_address_range(rom, base, base + u32(len(mem)) - 1)
	return true
}

name :: proc(rom: ^ROM) -> string {
	return rom.name
}

read :: proc(using rom: ^ROM, addr: u32) -> byte {
	return mem[addr - base]
}

write :: proc(rom: ^ROM, _: u32, _: byte) {
	log.warnf("ROM (%s) is not writable!", rom.name)
}

destroy :: proc(rom: ^ROM) {
	delete(rom.mem)
}

@(init)
rom :: proc() {
	peripheral.register_constructor(proc(id: string) {
		rom, cb := peripheral.allocate(ROM)
		rom.id = id
		rom.name = "ROM"

		cb.install = install
		cb.config = config
		cb.read = read
		cb.write = write
		cb.name = name
		cb.destroy = destroy
	})
}
