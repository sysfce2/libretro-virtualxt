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
import "core:c"
import "core:log"
import "core:strings"
import "core:time"

@(require) import "vxt:modules"

import retro "vxt:frontend/libretro"
import retro_callbacks "vxt:frontend/libretro/callbacks"
import "vxt:machine"
import rt "vxt:xruntime"

VXT_VERSION :: "1.3.0"
MAX_DISK_IMAGES :: 256
LOG_BUFFER_SIZE :: 1024
AUDIO_FREQUENCY :: 44100
DEFAULT_DISK_IMAGE :: "boot:svardos_hd.img"

@(thread_local)
log_buffer: [LOG_BUFFER_SIZE]byte

delta_time: retro.usec_t
current_time: time.Duration

disk_images: [dynamic]string
disk_image_index: uint

frame_buffer: struct {
	memory:        [dynamic]u32,
	width, height: uint,
}

write_default_disk_image :: proc(reset := false) -> string {
	using retro_callbacks.vfs

	save_dir: cstring
	if !retro_callbacks.environment(retro.ENVIRONMENT_GET_SAVE_DIRECTORY, &save_dir) {
		log.error("Could not get save directory!")
		return ""
	}

	str := [?]string{string(save_dir), "virtualxt_default.img"}
	img_path := strings.join(str[:], "/", context.temp_allocator)
	cimg_path := strings.clone_to_cstring(img_path, context.temp_allocator)

	data: []byte
	when !#config(VXT_EXTERNAL_HEAP, false) {
		data = #load(DEFAULT_DISK_IMAGE, []byte)
	}

	fp := open(cimg_path, retro.VFS_FILE_ACCESS_READ, 0)
	defer close(fp)

	if ((fp == nil) || reset) && (len(data) > 0) {
		if fp = open(cimg_path, retro.VFS_FILE_ACCESS_WRITE, 0); fp == nil {
			log.error("Could not open default disk image for write!")
			return ""
		}

		if write(fp, &data[0], u64(len(data))) != i64(len(data)) {
			log.error("Could not open default disk image for write!")
			return ""
		}
		log.info("Default disk image copied!")
	}
	return img_path
}

set_eject_state :: proc "c" (ejected: c.bool) -> c.bool {
	context = rt.default_context

	mounted: byte // 0 == First floppy drive
	machine.configure("disk", "mounted", &mounted)

	if bool(mounted) != ejected {
		return true
	}

	if ejected {
		return machine.configure("disk", "umount", byte(0))
	} else {
		assert(disk_images[disk_image_index] != "")
		return machine.configure("disk", "A", disk_images[disk_image_index])
	}
}

get_eject_state :: proc "c" () -> c.bool {
	context = rt.default_context

	mounted: byte
	machine.configure("disk", "mounted", &mounted)
	return mounted == 0
}

get_image_index :: proc "c" () -> c.uint {
	return c.uint(disk_image_index)
}

set_image_index :: proc "c" (index: c.uint) -> c.bool {
	if int(index) >= len(disk_images) {
		return false
	}
	disk_image_index = uint(index)
	return true
}

get_num_images :: proc "c" () -> c.uint {
	return c.uint(len(disk_images))
}

replace_image_index :: proc "c" (index: c.uint, #by_ptr info: retro.game_info) -> c.bool {
	context = rt.default_context

	assert(int(index) < len(disk_images))
	if info.path == nil {
		return false
	}

	delete(disk_images[index])
	disk_images[index] = strings.clone(string(info.path))
	log.infof("Disk index %d: %s", index, info.path)
	return true
}

add_image_index :: proc "c" () -> c.bool {
	context = rt.default_context
	append(&disk_images, strings.clone(""))
	return true
}

@(export)
retro_init :: proc "c" () {
	when #config(VXT_STARTUP_RUNTIME, false) {
		rt.odin_startup_runtime(nil, 0)
	}
}

@(export)
retro_set_environment :: proc "c" (cb: retro.environment_t) {
	using retro, runtime.Logger_Level
	context = rt.default_context

	retro_callbacks.environment = cb

	logging: log_callback
	if cb(ENVIRONMENT_GET_LOG_INTERFACE, &logging) {
		logger_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
			lv: log_level
			switch (level) {
			case .Debug:
				lv = .LOG_DEBUG
			case .Info:
				lv = .LOG_INFO
			case .Warning:
				lv = .LOG_WARN
			case .Error, .Fatal:
				lv = .LOG_ERROR
			}

			builder := strings.builder_from_bytes(log_buffer[:])
			strings.write_string(&builder, text)
			log_buffer[LOG_BUFFER_SIZE - 1] = 0 // Ensure we always are terminated.
			log_printf_t(data)(lv, "%s\n", strings.to_cstring(&builder))
		}

		rt.default_context.logger = runtime.Logger{logger_proc, rawptr(logging.log), .Debug, nil}
	}

	cb(ENVIRONMENT_SET_VARIABLES, &options)

	no_game: c.bool = true
	cb(ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_game)
}

@(export)
retro_reset :: proc "c" () {
	context = rt.default_context
	check_variables()
	machine.reset()
}

setup_machine_config :: proc(config_path: string) -> bool {
	using machine

	cpath := strings.clone_to_cstring(config_path)
	defer delete(cpath)

	fp := retro_callbacks.vfs.open(cpath, retro.VFS_FILE_ACCESS_READ, retro.VFS_FILE_ACCESS_HINT_NONE)
	if fp == nil {
		log.errorf("Could not load ROM file: %s", config_path)
		return false
	}
	defer retro_callbacks.vfs.close(fp)

	file_size := retro_callbacks.vfs.size(fp)
	if file_size <= 0 {
		log.errorf("Invalid file size (%vB): %s", file_size, config_path)
		return false
	}

	ini_data := make([]byte, file_size)
	defer delete(ini_data)

	if retro_callbacks.vfs.read(fp, &ini_data[0], u64(file_size)) != file_size {
		log.errorf("Could not read %vB from: %s", file_size, config_path)
		return false
	}

	config := load_ini(string(ini_data)) or_return
	version := config["virtualxt"]["version"] or_return
	if version != VXT_VERSION {
		return false
	}

	for section_name, section_data in config {
		if section_name == "virtualxt" {
			continue
		}

		if mod_name, ok := section_data["module"]; ok {
			instantiate(mod_name, section_name)
		}

		for k, v in section_data {
			if k == "module" {
				continue
			} else if !configure(section_name, k, v) {
				log.errorf("Configuration failed: [%s] %s=%s", section_name, k, v)
				return false
			}
		}
	}

	set_framebuffer_size :: proc(w, h: uint) {
		frame_buffer.width = w
		frame_buffer.height = h
	}

	configure("cga", "framebuffer", frame_buffer.memory[:])
	configure("vga", "framebuffer", frame_buffer.memory[:])
	configure("cga", "modeset_callback", set_framebuffer_size)
	configure("vga", "modeset_callback", set_framebuffer_size)

	configure("chipset", "set_audio_frequency", uint(AUDIO_FREQUENCY))

	return true
}

setup_default_machine :: proc(info: ^retro.game_info) {
	using machine

	instantiate("rom", "bios")
	configure("bios", "name", "BIOS")
	configure("bios", "base", "0xFE000")
	if glabios {
		configure("bios", "mem", #load("bios:GLABIOS.ROM", []byte))
	} else {
		configure("bios", "mem", #load("bios:pcxtbios.bin", []byte))
	}

	instantiate("rom", "vxtx")
	configure("vxtx", "name", "Disk Extension")
	configure("vxtx", "mem", #load("bios:vxtx.bin", []byte))
	configure("vxtx", "base", "0xFD800")

	instantiate("rifs2")

	{
		instantiate("disk")
		if info != nil {
			configure("disk", "auto", string(info.path))
		} else if path := write_default_disk_image(reset_default_disk); path != "" {
			configure("disk", "auto", path)
		}

		// Check if floppy drive 0 was mounted.
		mounted: byte
		configure("disk", "mounted", &mounted)

		configure("disk", "boot", byte((bool(mounted) && floppy_boot_prio) ? 0 : 0x80))
		if bool(mounted) {
			append(&disk_images, strings.clone(string(info.path)))
		}
	}

	set_framebuffer_size :: proc(w, h: uint) {
		frame_buffer.width = w
		frame_buffer.height = h
	}

	if enable_vga {
		instantiate("rom", "vgabios")
		configure("vgabios", "name", "VGA BIOS")
		configure("vgabios", "base", "0xC0000")
		configure("vgabios", "mem", #load("bios:vgabios.bin", []byte))

		instantiate("vga")
		configure("vga", "framebuffer", frame_buffer.memory[:])
		configure("vga", "modeset_callback", set_framebuffer_size)
	} else {
		instantiate("cga")
		configure("cga", "framebuffer", frame_buffer.memory[:])
		configure("cga", "modeset_callback", set_framebuffer_size)
	}

	instantiate("mouse")

	instantiate("chipset")
	configure("chipset", "set_audio_frequency", uint(AUDIO_FREQUENCY))

	if enable_ems {
		instantiate("ems")
	}

	if gdb_server {
		instantiate("gdb")
		configure("gdb", "halt", gdb_halt)
	}
}

@(export)
retro_load_game :: proc "c" (info: ^retro.game_info) -> c.bool {
	context = rt.default_context

	fmt := retro.pixel_format.PIXEL_FORMAT_XRGB8888
	if !retro_callbacks.environment(retro.ENVIRONMENT_SET_PIXEL_FORMAT, &fmt) {
		log.error("XRGB8888 is not supported!")
		return false
	}

	disk_control := retro.disk_control_callback {
		set_eject_state,
		get_eject_state,
		get_image_index,
		set_image_index,
		get_num_images,
		replace_image_index,
		add_image_index,
	}
	retro_callbacks.environment(retro.ENVIRONMENT_SET_DISK_CONTROL_INTERFACE, &disk_control)

	frame_time := retro.frame_time_callback{frame_time_callback, 1000000 / 60}
	if !retro_callbacks.environment(retro.ENVIRONMENT_SET_FRAME_TIME_CALLBACK, &frame_time) {
		log.error("Require the frame time interface!")
		return false
	}

	vfs_info: retro.vfs_interface_info
	if retro_callbacks.environment(retro.ENVIRONMENT_GET_VFS_INTERFACE, &vfs_info) && (vfs_info.iface != nil) {
		retro_callbacks.vfs = vfs_info.iface
	} else {
		log.error("Require the VFS interface!")
		return false
	}

	{
		using machine
		create()
		check_variables()

		if len(frame_buffer.memory) == 0 {
			frame_buffer.memory = make([dynamic]u32, 720 * 480)
		}

		if (info != nil) && strings.has_suffix(string(info.path), ".ini") {
			if !setup_machine_config(string(info.path)) {
				show_message("Invalid machine configuration!")
				return false
			}
		} else {
			setup_default_machine(info)
		}

		check_variables()
		initialize(flag_286)
		print_status()
	}

	show_message("Ensure you have 'Game Focus' mode set to 'Detect' under Setting > Input, or press the 'Scroll Lock' key", 6 * time.Second)
	return true
}

frame_time_callback :: proc "c" (usec: retro.usec_t) {
	delta_time = usec
	current_time += time.Duration(usec) * time.Microsecond
}

@(export)
retro_run :: proc "c" () {
	context = rt.default_context
	defer free_all(context.temp_allocator)

	updated := false
	if retro_callbacks.environment(retro.ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) && updated {
		check_variables()
	}

	retro_callbacks.input_poll()

	cpu_freq := i64(machine.frequency())
	cycles := i64(delta_time) * (cpu_freq / 1000000)

	// Cap the number of cycles to what would be executed during a 30hz refresh rate.
	// So if we drop below 30fps the emulated clock would slow down.
	if n := cpu_freq / 30; cycles > n {
		log.warnf("Can't keep up! Dropping cycles: %d (%dms)", cycles - n, uint((f64(cycles - n) / f64(cpu_freq)) * 1000))
		cycles = n
	}

	if _, ok := machine.step(uint(cycles), enable_186); !ok {
		@(static) msg_timer: time.Duration
		if (current_time - msg_timer) > (5 * time.Second) {
			msg_timer = current_time
			show_message("Invalid opcodes! You might be running incompatible software")
		}
	}

	using frame_buffer
	retro_callbacks.video(&memory[0], u32(width), u32(height), width * 4)
}

@(export)
retro_unload_game :: proc "c" () {
	context = rt.default_context
	machine.destroy()
	delete(frame_buffer.memory)
}

@(export)
retro_get_system_info :: proc "c" (info: ^retro.system_info) {
	info^ = retro.system_info {
		library_name     = "VirtualXT",
		library_version  = VXT_VERSION,
		block_extract    = true,
		need_fullpath    = true,
		valid_extensions = "img|ini",
	}
}

@(export)
retro_get_system_av_info :: proc "c" (info: ^retro.system_av_info) {
	info^ = retro.system_av_info {
		geometry = retro.game_geometry{base_width = 640, base_height = 200, max_width = 720, max_height = 480, aspect_ratio = 4.0 / 3.0},
		timing = retro.system_timing{sample_rate = AUDIO_FREQUENCY, fps = 60},
	}
}

@(export)
retro_set_audio_sample :: proc "c" (cb: retro.audio_sample_t) {
	retro_callbacks.audio = cb
}

@(export)
retro_set_input_poll :: proc "c" (cb: retro.input_poll_t) {
	retro_callbacks.input_poll = cb
}

@(export)
retro_set_input_state :: proc "c" (cb: retro.input_state_t) {
	retro_callbacks.input_state = cb
}

@(export)
retro_set_video_refresh :: proc "c" (cb: retro.video_refresh_t) {
	retro_callbacks.video = cb
}

show_message :: proc(message: string, duration := time.Second * 3) {
	msg := retro.message{strings.clone_to_cstring(message), c.uint(time.duration_seconds(duration) * 60)}
	retro_callbacks.environment(retro.ENVIRONMENT_SET_MESSAGE, &msg)
	delete(msg.msg)
}
