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

import "base:runtime"
import "core:mem"
import "core:c"
import "core:slice"

@(require) import "core:log"

core_heap: []byte	
core_allocator: mem.Buddy_Allocator
core_temp_allocator: mem.Arena

default_context: runtime.Context

@(export)
odin_startup_runtime :: proc "c" (heap: rawptr, size: c.int) {
	context = runtime.default_context()
	if size > 0 {
		core_heap = slice.bytes_from_ptr(heap, int(size))
	}
	#force_no_inline runtime._startup_runtime()
}

@(init)
_ :: proc() {
	when !#config(VXT_EXTERNAL_HEAP, false) {
		@(static) heap_memory: [1024 * 1024 * #config(VXT_MAX_MEMORY_MB, 16)]byte // 16MB ought be enough for everyone?
		core_heap = heap_memory[:]
	}

	mem.buddy_allocator_init(&core_allocator, core_heap, mem.DEFAULT_ALIGNMENT)
	context.allocator = mem.buddy_allocator(&core_allocator)
	context.allocator.procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location: runtime.Source_Code_Location = #caller_location) -> ([]byte, runtime.Allocator_Error) {	
		ptr, err := mem.buddy_allocator_proc(allocator_data, mode, size, alignment, old_memory, old_size, location)
		if err == .Out_Of_Memory {
			log.panicf("%v: Buddy allocator out of memory!", location)
		}
		return ptr, err
	}

	mem.arena_init(&core_temp_allocator, make([]byte, 1024 * 1024 * 1)) // 1MB
	context.temp_allocator = mem.arena_allocator(&core_temp_allocator)
	context.temp_allocator.procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location: runtime.Source_Code_Location = #caller_location) -> ([]byte, runtime.Allocator_Error) {	
		ptr, err := mem.arena_allocator_proc(allocator_data, mode, size, alignment, old_memory, old_size, location)
		if err == .Out_Of_Memory {
			log.panicf("%v: Arena allocator out of memory!", location)
		}
		return ptr, err
	}

	default_context = context
	
	when ODIN_OS == .Freestanding {
		default_context.random_generator = runtime.Random_Generator{ procedure = random_generator_proc }
		default_context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! { log.panicf("%v %s: %s", loc, prefix, message) }
	}
}

random_generator_proc :: proc(data: rawptr, mode: runtime.Random_Generator_Mode, p: []byte) {
	@(static) seed: int = 1
	M :: 2147483647
	
	#partial switch mode {
	case .Read:
		for &v in p {
			seed = (16807 * seed) % M
			r := f64(seed) / M
			v = byte(255 * r)
		}
	case .Query_Info:
		if len(p) != size_of(runtime.Random_Generator_Query_Info) {
			return
		}
		(^runtime.Random_Generator_Query_Info)(raw_data(p))^ = {}
	}
}
