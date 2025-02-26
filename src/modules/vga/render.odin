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

package vga

FONT_OFFSETS := [?]int{ 0x0000, 0x4000, 0x8000, 0xC000, 0x2000, 0x6000, 0xA000, 0xE000 }

color_lookup :: proc(using vga: ^VGA, index: byte) -> u32 {
	color_select := regs.attr_reg[0x14]
	idx := (regs.attr_reg[index] & 0x3F) | ((color_select & 0xC) << 4)

	mode_ctrl := regs.attr_reg[0x10]
	if bool(mode_ctrl & 0x80) {
		idx = (idx & 0xCF) | ((color_select & 3) << 4)
	}
	return palette[idx]
}

blit_char :: proc(vga: ^VGA, ch: int, attr: byte, x, y: int) {
	using vga.regs

	bg_color_index := (attr & 0x70) >> 4
	fg_color_index := attr & 0xF

	if bool(attr & 0x80) {
		mode_ctrl := attr_reg[0x10]
		if bool(mode_ctrl & 8) {
			fg_color_index = vga.cursor_blink ? bg_color_index : fg_color_index
		} else {
			// High intensity!
			bg_color_index += 8
		}
	}

	bg_color := color_lookup(vga, bg_color_index)
	fg_color := color_lookup(vga, fg_color_index)

	char_map_reg := seq_reg[0x3]
	font_a := ((char_map_reg >> 3) & 4) | ((char_map_reg >> 2) & 3)
	font_b := ((char_map_reg >> 2) & 4) | (char_map_reg & 3)
	font := bool(attr & 8) ? FONT_OFFSETS[font_b] : FONT_OFFSETS[font_a]

	ch_idx := ch
	start := 0
	end := 15

	if ch < 0 {
		ch_idx = 0xDB
		start = int(vga.cursor_start)
		end = int(vga.cursor_end)
	}

	for {
		n := start % 16
		glyph_line := vga.mem[font + ch_idx * 32 + n]

		for j := 0; j < 8; j += 1 {
			mask := byte(0x80) >> uint(j)
			color := bool(glyph_line & mask) ? fg_color : bg_color
			offset := int(vga.width) * (y + n) + x + j
			vga.frame_buffer[offset] = color
		}

		if n == end {
			break
		}
		start += 1
	}
}

render_textmode :: proc(vga: ^VGA) {
	using vga, vga.regs

	if !is_dirty || !textmode {
		return
	}
	
	is_dirty = false
	video_page := (int(crt_reg[0xC]) << 8) + int(crt_reg[0xD])
	num_col := (width > 320) ? 80 : 40
	num_char := num_col * 25
	
	for i := 0; i < num_char; i += 1 {
		cell_offset := CGA_BASE + video_page + i * 2
		ch := mem[sanitaze_address(cell_offset)]
		attr := mem[sanitaze_address(cell_offset + 1)]
		
		blit_char(vga, int(ch), attr, (i % num_col) * 8, (i / num_col) * 16)
	}

	if cursor_blink && cursor_visible {
		x := int(cursor_offset) % num_col
		y := int(cursor_offset) / num_col
		
		if (x < num_col && y < 25) {
			offset := sanitaze_address(video_page + (num_col * 2 * y + x * 2 + 1))
			attr := (mem[sanitaze_address(offset)] & 0x70) | 0xF
			
			blit_char(vga, -1, attr, x * 8, y * 16)
		}
	}
}

render_scanline :: proc(using vga: ^VGA, y: uint) {
	if (y >= height) || textmode {
		return
	}
	
	is_dirty = true
	plane_mode := !bool(regs.seq_reg[0x4] & 8)
	pixel_shift := uint(regs.attr_reg[0x13] & 0xF)
	video_page := (uint(regs.crt_reg[0xC]) << 8) | uint(regs.crt_reg[0xD])

	for x: uint; x < width; x += 1 {
		color: u32
		
		switch bpp {
			case 1:
				addr := (y >> 1) * 80 + (y & 1) * 8192 + (x >> 3)
				index := (mem[sanitaze_address(CGA_BASE + addr)] >> (7 - (x & 7))) & 1
				color = color_lookup(vga, index)
			case 2:
				addr := (y >> 1) * 80 + (y & 1) * 8192 + (x >> 2)
				index := (mem[sanitaze_address(CGA_BASE + addr)] >> (6 - (x & 3) * 2)) & 3
				color = color_lookup(vga, index)
			case 4:
				addr := y * (width >> 3) + (x >> 3) + video_page
				shift := 7 - (x & 7)

				index := (mem[sanitaze_address(addr)] >> shift) & 1
				index |= ((mem[sanitaze_address(addr + PLANE_SIZE)] >> shift) & 1) << 1
				index |= ((mem[sanitaze_address(addr + PLANE_SIZE * 2)] >> shift) & 1) << 2
				index |= ((mem[sanitaze_address(addr + PLANE_SIZE * 3)] >> shift) & 1) << 3

				color = color_lookup(vga, index)
			case 8:
				addr: uint
				if plane_mode {
					addr = (y * width + x) / 4 + (x & 3) * PLANE_SIZE
					addr = (addr + video_page) - pixel_shift
				} else {
					addr = y * width + x + video_page
				}
				color = palette[mem[sanitaze_address(addr)]]
		}

		frame_buffer[y * width + x] = color
	}
}
