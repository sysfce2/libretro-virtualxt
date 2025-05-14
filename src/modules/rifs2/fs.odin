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
import "core:mem"
import "core:strings"
import "core:log"
import "base:runtime"

import "vxt:machine/peripheral"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"

PAYLOAD_MAX_SIZE :: 0x10000

Response :: enum u16 {
	OK = 0x0,
	FILE_NOT_FOUND = 0x2,
	PATH_NOT_FOUND = 0x3,
	TOO_MANY_OPEN_FILES = 0x4,
	INVALID_HANDLE = 0x6,
	NO_MORE_FILES = 0xC,
	UNKNOWN = 0x16,
	SEEK_ERROR = 0x19,
	WRITE_ERROR = 0x1D,
	READ_ERROR = 0x1E,
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
	attrib: u16,
	pattern: [12]byte,
	path: string,
	dir: ^retro.vfs_dir_handle,
	files: [dynamic]^retro.vfs_file_handle,
}

FS :: struct {
	base_port:                 u16,
	registers:                 [8]byte,
	dlab:                      bool,
	root_path: 				   string,
	dos_processes:             [dynamic]Process,
	input_queue, output_queue: queue.Queue(byte),

	// Buffers for package assembly.
	input_buffer, output_buffer: [size_of(Packet) + PAYLOAD_MAX_SIZE]byte,
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
	return payload_as(packet_payload(pk), ty)
}

payload_as :: proc(payload: []byte, $ty: typeid) -> ^ty {
	assert(size_of(ty) <= len(payload))
	return (^ty)(&payload[0])
}

adjust_case_path :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		return path
	}

	ta := context.temp_allocator
	new_path := "."

	str := strings.clone(path, ta)
	for part in strings.split_iterator(&str, "/") {
		using retro_callbacks.vfs

		dir := opendir(strings.clone_to_cstring(new_path, ta), false)
		if dir == nil {		
			return path // Just return the original path.
		}
		defer closedir(dir)

		new_part := part
		for readdir(dir) {
			name := string(dirent_get_name(dir))
			upper_name := strings.to_upper(name, ta)

			if upper_name == part {
				new_part = name
				break
			}
		}

		new_path = strings.join({new_path, new_part}, "/", ta)
	}
	return new_path
}

transform_path :: proc(fs: ^FS, path: string) -> string {
	p := path
	if (len(p) > 1) && (p[1] == ':') {
		p = p[2:]
	}

	ta := context.temp_allocator
	p, _ = strings.replace(p, "\\", "/", -1, ta)
	p = adjust_case_path(strings.trim_prefix(p, "/"))
	p, _ = strings.concatenate({fs.root_path, p}, ta)
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
	
	idx := append(&fs.dos_processes, Process{active = true, process_id = id}) - 1
	return &fs.dos_processes[idx]
}

process_request :: proc(using fs: ^FS, pk: ^Packet, buffer: []byte) -> (resp := Response.OK, payload_size := 0) {
	switch pk.cmd {
	case .RMDIR:
		path := null_terminated_string(packet_payload(pk))
		resp = host_rmdir(transform_path(fs, path))
	case .MKDIR:
		path := null_terminated_string(packet_payload(pk))
		resp = host_mkdir(transform_path(fs, path))
	case .CHDIR:
		path := null_terminated_string(packet_payload(pk))
		resp = host_exists(transform_path(fs, path)) ? .OK : .PATH_NOT_FOUND
	case .GETSPACE:
		// TODO: We just fake this and say we always have 32Mb of free space. :D

		using data := payload_as(buffer, struct #packed {
			sectors_per_cluster, total_clusters, bytes_per_sector, available_clusters: u16,
		})

		sectors_per_cluster = 1024
		total_clusters = 64
		bytes_per_sector = 512
		available_clusters = 63

		payload_size = 8
	case .SETATTR:
		path := null_terminated_string(packet_payload(pk)[2:])
		resp = host_exists(transform_path(fs, path)) ? .OK : .FILE_NOT_FOUND
	case .GETATTR:
		path := transform_path(fs, null_terminated_string(packet_payload(pk)))
		if host_exists(path) {
			payload_as(buffer, u16)^ = host_is_dir(path) ? 0x10 : 0
			payload_size = 2
		} else {
			resp = .FILE_NOT_FOUND
		}
	case .RENAMEFILE:
		data := packet_payload(pk)
		old_name := transform_path(fs, null_terminated_string(data))
		new_name := transform_path(fs, null_terminated_string(data[len(old_name) + 1:]))
		
		resp = host_rename(transform_path(fs, old_name), transform_path(fs, new_name))
	case .DELETEFILE:
		path := null_terminated_string(packet_payload(pk))
		resp = host_delete(transform_path(fs, path))
	case .CLOSEFILE:
		idx := packet_payload_as(pk, u16)^
		p := get_process(fs, pk.process_id)
		
		if (int(idx) >= len(p.files)) || (p.files[idx] == nil) {
			resp = .INVALID_HANDLE
		} else {
			fp := &p.files[idx]
			retro_callbacks.vfs.close(fp^)
			fp^ = nil
		}
	case .CLOSEALL:
		p := get_process(fs, pk.process_id)
		p.active = false

		if p.dir != nil {
			retro_callbacks.vfs.closedir(p.dir)
			p.dir = nil
		}

		if p.path != "" {
			delete(p.path)
			p.path = ""
		}
		
		for fp in p.files {
			if fp != nil {
				retro_callbacks.vfs.close(fp)
			}
		}
		clear(&p.files)
	case .OPENFILE, .CREATEFILE:
		attrib := (pk.cmd == .OPENFILE) ? packet_payload_as(pk, u16)^ : 1
		path := null_terminated_string(packet_payload(pk)[2:])
		process := get_process(fs, pk.process_id)		
		
		resp = host_openfile(process, transform_path(fs, path), attrib, buffer)
		payload_size = (resp == .OK) ? 12 : 0
	case .READFILE, .WRITEFILE:
		using data := packet_payload_as(pk, struct #packed {
			handle: u16,
			pos: u32,
			size: u16,
		})^

		// Will be at least 2
		payload_size = 2
		result := payload_as(buffer, u16)
		result^ = 0

		process := get_process(fs, pk.process_id)
		if (int(handle) >= len(process.files)) || (process.files[handle] == nil) {
			log.warnf("READ/WRITEFILE: Invalid Handle (0x%X)", handle)
			resp = .INVALID_HANDLE
			return
		}

		fp := process.files[handle]
		if retro_callbacks.vfs.seek(fp, i64(pos), retro.VFS_SEEK_POSITION_START) < 0 {
			log.warn("READ/WRITEFILE: Seek Error")
			resp = .SEEK_ERROR
			return
		}

		num: int
		if pk.cmd == .READFILE {
			if num = int(retro_callbacks.vfs.read(fp, &buffer[2], u64(size))); num < 0 {
				log.warn("READFILE: Read Error")
				resp = .READ_ERROR
				return
			}
		} else {
			if num = int(retro_callbacks.vfs.write(fp, &packet_payload(pk)[8], u64(size))); num < 0 {
				log.warn("WRITEFILE: Write Error")
				resp = .WRITE_ERROR
				return
			}
		}

		payload_size += num
		result^ = u16(num)
	case .FINDFIRST:
		process := get_process(fs, pk.process_id)
		str := null_terminated_string(packet_payload(pk)[2:])		
		split := strings.last_index(str, "\\")
		path := str[0:split]

		process.attrib = packet_payload_as(pk, u16)^
		runtime.copy_from_string(process.pattern[:], "????????.???")

		parts: []string
		ta := context.temp_allocator

		// This is very likely OS dependant. (Tested on SvarDOS)
		if strings.contains(path, "?") || strings.contains(path, ".") {
			log.warnf("FINDFIRST: Strange double pattern: %s", str)
			
			split = strings.last_index(path, "\\")
			parts = strings.split(path[split + 1:], ".", ta)
			path = str[0:split]
		} else {
			parts = strings.split(str[split + 1:], ".", ta)
		}

		runtime.copy_from_string(process.pattern[:], parts[0])
		if len(parts) > 1 {
			runtime.copy_from_string(process.pattern[9:], parts[1])	
		}
		
		resp = host_findfirst(process, transform_path(fs, path), buffer)
		payload_size = (resp == .OK) ? 43 : 0
	case .FINDNEXT:
		process := get_process(fs, pk.process_id)
		resp = host_findnext(process, buffer)
		payload_size = (resp == .OK) ? 43 : 0
	case .COMMITFILE, .LOCKFILE, .UNLOCKFILE:
	case .EXTOPEN:
		// TODO
		fallthrough
	case:
		log.errorf("Unknown RIFS command: %v (payload size %d)", pk.cmd, pk.length)
		resp = .UNKNOWN // Unknown command
	}
	return
}

server_response :: proc(fs: ^FS, id: u16, resp: Response, buffer: []byte) {
	p := (^Packet)(&buffer[0])
	p.process_id = id
	p.packetID = {'L', 'Y'}
	p.resp = resp
	p.length = u16(len(buffer))
	p.notlength = ~p.length
	p.crc32 = 0
	
	p.crc32 = crc32(p, p.length)
	for b in buffer {
		queue.push(&fs.input_queue, b)
	}
}

destroy :: proc(fs: ^FS) {
	for i := 0; i < len(fs.dos_processes); i += 1 {
		p := &fs.dos_processes[i]
		if p.dir != nil {
			retro_callbacks.vfs.closedir(p.dir)
		}

		if p.path != "" {
			delete(p.path)
		}
		
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
		output_queue_len := queue.len(output_queue)
		
		if output_queue_len >= size_of(Packet) {
			// TODO: Perhaps cache this somehow?
			for i := 0; i < size_of(Packet); i += 1 {
				output_buffer[i] = queue.get(&output_queue, i)
			}
		
			// Is packet ready?
			if p := (^Packet)(&output_buffer[0]); output_queue_len >= int(p.length) {
				// Packet header is already copied.
				queue.consume_front(&output_queue, size_of(Packet))

				// Copy payload.
				for i := 0; i < (int(p.length) - size_of(Packet)); i += 1 {
					output_buffer[size_of(Packet) + i] = queue.pop_front(&output_queue)
				}
				
				if verify_packet(p) {
					mem.copy(&fs.input_buffer[0], p, size_of(Packet))
					resp, sz := process_request(fs, p, fs.input_buffer[size_of(Packet):])
					server_response(fs, p.process_id, resp, fs.input_buffer[:sz + size_of(Packet)])
				}
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
