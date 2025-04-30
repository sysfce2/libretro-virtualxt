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
import "core:slice"
import "core:strings"
import "core:log"

import "vxt:machine/peripheral"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"

Response :: enum u16 {
	OK = 0x0,
	FILE_NOT_FOUND = 0x2,
	PATH_NOT_FOUND = 0x3,
	TOO_MANY_OPEN_FILES = 0x4,
	INVALID_HANDLE = 0x6,
	NO_MORE_FILES = 0xC,
	UNKNOWN = 0x16,
}

Command :: enum u16 {
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
	using _: 	struct #raw_union { // Command to execute / result.
		cmd: Command,
		resp: Response,
	},
	_:          u16, // Machine ID of block sender. NOT USED!
	_:          u16, // Machine ID of intended reciever. NOT USED!
	process_id: u16, // ID of sending process. (for closeall)
	crc32:      u32, // CRC-32 of entire block. (calculated with crc32 set to zero)
	// Payload data.
}

Process :: struct {
	process_id: u16,
	active: bool,
	files: [dynamic]^retro.vfs_file_handle,
}

FS :: struct {
	base_port:                 u16,
	registers:                 [8]byte,
	dlab:                      bool,
	root_path: 				   string,
	input_queue, output_queue: queue.Queue(byte),
	dos_processes:             [dynamic]Process,
}

config :: proc(fs: ^FS, name, key: string, value: any) -> bool {
	return true
}

install :: proc(using fs: ^FS) -> bool {
	peripheral.register_io_address_range(fs, base_port, base_port + 7)
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

packet_payload :: proc(pk: ^Packet) -> []byte {
	return slice.bytes_from_ptr(rawptr(uintptr(pk) + size_of(Packet)), int(pk.length))
}

packet_payload_as :: proc(pk: ^Packet, $ty: typeid) -> ^ty {
	return (^ty)(&packet_payload(pk)[0])
}

transform_path :: proc(fs: ^FS, path: string) -> string {
	p := path
	if (len(p) > 1) && (p[1] == ':') {
		p = p[2:]
	}
	
	p, _ = strings.replace(p, "\\", "/", -1, context.temp_allocator)
	p = strings.trim_prefix(p, "/")
	p, _ = strings.concatenate({fs.root_path, p}, context.temp_allocator)
	return p
}

null_terminated_string :: proc(data: []byte) -> string {
	return string(strings.unsafe_string_to_cstring(string(data)))
}

get_process :: proc(fs: ^FS, id: u16) -> ^Process {
	inactive: ^Process
	for i := 0; i < len(fs.dos_processes); i += 1 {
		if p := &fs.dos_processes[i]; !p.active {
			inactive = p
		} else if p.process_id == id {
			return p
		}
	}
	
	if inactive != nil {
		inactive.active = true
		inactive.process_id = id
		assert(len(inactive.files) == 0)
		return inactive
	}
	
	idx := append(&fs.dos_processes, Process{active = true, process_id = id})
	return &fs.dos_processes[idx]
}

process_request :: proc(using fs: ^FS, pk: ^Packet) {
	switch pk.cmd {
	case .RMDIR:
		path := null_terminated_string(packet_payload(pk))
		pk.resp = host_rmdir(transform_path(fs, path))
		server_response(fs, pk)
	case .MKDIR:
		path := null_terminated_string(packet_payload(pk))
		pk.resp = host_mkdir(transform_path(fs, path))
		server_response(fs, pk)
	case .CHDIR:
		path := null_terminated_string(packet_payload(pk))
		pk.resp = host_exists(transform_path(fs, path)) ? .OK : .PATH_NOT_FOUND
		server_response(fs, pk)
	case .GETSPACE:
		// TODO: We just fake this and say we always have 32Mb of free space. :D

		dest := packet_payload_as(pk, struct #packed {
			sectors_per_cluster, total_clusters, bytes_per_sector, available_clusters: u16,
		})

		dest.sectors_per_cluster = 1024
		dest.total_clusters = 64
		dest.bytes_per_sector = 512
		dest.available_clusters = 63

		pk.resp = .OK
		server_response(fs, pk, 8)
	case .SETATTR:
		path := null_terminated_string(packet_payload(pk)[2:])
		pk.resp = host_exists(transform_path(fs, path)) ? .OK : .FILE_NOT_FOUND
		server_response(fs, pk)
	case .GETATTR:
		data := packet_payload(pk)
		path := transform_path(fs, null_terminated_string(data))

		if host_exists(path) {
			pk.resp = .OK
			(^u16)(&data[0])^ = host_is_dir(path) ? 0x10 : 0
			server_response(fs, pk, 2)
		} else {
			pk.resp = .FILE_NOT_FOUND
			server_response(fs, pk)
		}
	case .RENAMEFILE:
		data := packet_payload(pk)
		old_name := transform_path(fs, null_terminated_string(data))
		new_name := transform_path(fs, null_terminated_string(data[len(old_name) + 1:]))

		pk.resp = host_rename(transform_path(fs, old_name), transform_path(fs, new_name))
		server_response(fs, pk)
	case .DELETEFILE:
		path := null_terminated_string(packet_payload(pk))
		pk.resp = host_delete(transform_path(fs, path))
		server_response(fs, pk)
	case .CLOSEFILE:
		idx := packet_payload_as(pk, u16)^
		p := get_process(fs, pk.process_id)
		
		if (int(idx) >= len(p.files)) || (p.files[idx] == nil) {
			pk.resp = .INVALID_HANDLE
		} else {
			fp := &p.files[idx]
			retro_callbacks.vfs.close(fp^)
			fp = nil
			pk.resp = .OK
		}
		server_response(fs, pk)
	case .CLOSEALL:
		p := get_process(fs, pk.process_id)
		p.active = false
		
		for &fp in p.files {
			if fp != nil {
				retro_callbacks.vfs.close(fp)
			}
		}
		clear(&p.files)
	case .READFILE, .WRITEFILE, .OPENFILE, .CREATEFILE, .FINDFIRST, .FINDNEXT:
		log.errorf("NOT IMPLEMENTED", pk.cmd)
		pk.resp = .UNKNOWN // Unknown command
		server_response(fs, pk)
	case .COMMITFILE, .LOCKFILE, .UNLOCKFILE:
		pk.resp = .OK
		server_response(fs, pk)
	case .EXTOPEN:
		// TODO
		fallthrough
	case:
		log.errorf("Unknown RIFS command: %v (payload size %d)", pk.cmd, pk.length)
		pk.resp = .UNKNOWN // Unknown command
		server_response(fs, pk)
	}
}

// Expects the 'cmd' and 'process_id' to be set by caller.
server_response :: proc(fs: ^FS, pk: ^Packet, payload_size := 0) {
	size := size_of(Packet) + payload_size
	
	queue.clear(&fs.input_queue)
	for data in slice.bytes_from_ptr(pk, size) {
		queue.push(&fs.input_queue, data)
	}
	
	dest := (^Packet)(queue.front_ptr(&fs.input_queue))
	
	dest.length = u16(size)
	dest.notlength = ~dest.length

	dest.packetID[0] = 'L'
	dest.packetID[1] = 'Y'

	dest.crc32 = 0
	dest.crc32 = crc32(dest, dest.length)	
}

destroy :: proc(fs: ^FS) {
	for i := 0; i < len(fs.dos_processes); i += 1 {
		p := &fs.dos_processes[i]
		for &fp in p.files {
			if fp != nil {
				retro_callbacks.vfs.close(fp)
			}
		}
		delete(p.files)
	}	
	delete(fs.dos_processes)

	queue.destroy(&fs.input_queue)
	queue.destroy(&fs.output_queue)
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
			if p := (^Packet)(queue.front_ptr(&output_queue)); int(p.length) == queue.len(output_queue) {
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
		cb.destroy = destroy
		cb.io_in = io_in
		cb.io_out = io_out

		cb.name = proc(_: ^FS) -> string {
			return "Host Filesystem"
		}
	})
}
