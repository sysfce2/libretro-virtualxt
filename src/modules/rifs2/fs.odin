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

import "core:container/queue"
import "core:log"

//import retro "vxt:frontend/libretro"
//import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine/peripheral"

Commands :: enum {
	RMDIR,
	MKDIR,
	CHDIR,
	CLOSEFILE,
	COMMITFILE,
	READFILE,
	WRITEFILE,
	LOCKFILE,
	UNLOCKFILE,
	GETSPACE,
	SETATTR,
	GETATTR,
	RENAMEFILE,
	DELETEFILE,
	OPENFILE,
	CREATEFILE,
	FINDFIRST,
	FINDNEXT,
	CLOSEALL,
	EXTOPEN,
}

Packet :: struct #packed {
	packetID:   [2]byte, // 'K', 'Y': Request from server.
	// 'L', 'Y': Reply from server.
	// 'R', 'P': Resent last packet, either direction.
	length:     u16, // Total number of bytes in this block, incl header.
	notlength:  u16, // ~Length (used for checking).
	cmd:        u16, // Command to execute / result.
	_:          u16, // Machine ID of block sender. NOT USED!
	_:          u16, // Machine ID of intended reciever. NOT USED!
	process_id: u16, // ID of sending process. (for closeall)
	crc32:      u32, // CRC-32 of entire block. (calculated with crc32 set to zero)
	// Payload data.
}

FS :: struct {
	base_port:                 u16,
	registers:                 [8]byte,
	dlab:                      bool,
	input_queue, output_queue: queue.Queue(byte),
}

config :: proc(fs: ^FS, name, key: string, value: any) -> bool {
	return true
}

install :: proc(using fs: ^FS) -> bool {
	peripheral.register_io_address_at(fs, base_port)
	queue.init(&input_queue)
	queue.init(&output_queue)
	return true
}

verify_packet :: proc(pk: ^Packet) -> bool {
	ln := ~pk.notlength
	if pk.length != ln {
		log.error("Packet of invalid size!")
		return false
	}

	crc := pk.crc32
	pk.crc32 = 0

	if crc != crc32(rawptr(pk), ln) {
		log.error("Packet CRC failed!")
		return false
	}

	pk.crc32 = crc // Restore the CRC if needed later.
	return true
}

process_request :: proc(using fs: ^FS, pk: ^Packet) {
}

io_in :: proc(using fs: ^FS, port: u16) -> byte {
	reg := port & 7
	switch reg {
	case 0:
		// Serial Data Register
		if dlab {
			return registers[reg]
		}
		data, ok := queue.pop_front_safe(&input_queue)
		return ok ? data : 0
	case 5:
		// Line Status Register
		res: byte = 0x60 // Always assume transmition buffer is empty.
		if queue.len(input_queue) > 0 {
			res |= 1
		}
		return res
	}
	return registers[reg]
}

io_out :: proc(using fs: ^FS, port: u16, data: byte) {
	reg := port & 7
	registers[reg] = data

	switch reg {
	case 0:
		// Serial Data Register
		if dlab {
			return
		}

		queue.push_back(&output_queue, data)
		if queue.len(output_queue) >= size_of(Packet) {
			// Is packet ready?
			if p := transmute(^Packet)queue.front_ptr(&output_queue); int(p.length) == queue.len(output_queue) {
				if verify_packet(p) {
					process_request(fs, p)
				}
				queue.clear(&output_queue)
			}
		}
	case 3:
		// Line Control Register
		dlab_in := bool(data & 0x80)
		if dlab != dlab_in {
			dlab = dlab_in
			queue.clear(&output_queue)
			queue.clear(&input_queue)
			log.info("DLAB change! Assume RIFS state reset.")
		}
	}
}

@(init)
rifs2 :: proc() {
	peripheral.register_constructor(proc(_: string) {
		fs, cb := peripheral.allocate(FS)
		fs.base_port = 0x178

		cb.install = install
		cb.config = config
		cb.io_in = io_in
		cb.io_out = io_out

		cb.name = proc(_: ^FS) -> string {
			return "Host Filesystem"
		}
	})
}
