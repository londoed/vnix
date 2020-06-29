module io

import asm
import dev
import fs
import lock
import mem
import proc
import sys

/* PC keyboard interface constants */

pub const (
	KBSTATP = 0x64, /* kbd controller status print(I) */
	KBS_DIB = 0x01, /* kbd data in buffer */
	KBDATAP = 0x60, /* kbd data port(I) */

	NO = 0,
	SHIFT = (1 << 0),
	CTL = (1 << 1),
	ALT = (1 << 2),

	CAPSLOCK = (1 << 3),
	NUMLOCK = (1 << 4),
	SCROLLLOCK = (1 << 5),
	E0ESC = (1 << 6),

	/* Special keybodes */
	KEY_HOME = 0xE0,
	KEY_END = 0xE1,
	KEY_UP = 0xE2,
	KEY_DN = 0xE3,
	KEY_LF = 0xE4,
	KEY_RT = 0xE5,
	KEY_PGUP = 0xE6,
	KEY_PGDN = 0xE7,
	KEY_INS = 0xE8,
	KEY_DEL = 0xE9,

	C = fn(x) { return x - '@' }
)

/* TODO:
 * shift_code array
 * toggle_code array
 * normal_map array
 * shiftmap arrau
 * ctlmap array
 */

pub fn kbd_getc() int
{
	mut shift := u32(0)
	mut *char_code := [4]string{
		normal_map, shift_map, ctl_map, ctl_map,
	}
	mut st, data, c := u32(0)

	st = asm.inb(KBSTATP)

	if (st & KBS_DIB) == 0 {
		return -1
	}

	data = asm.inb(KBDATAP)

	if data == 0XE0 {
		/* Key released */
		data = data if shift & E0ESC else data & 0x7F
		shift &= ~(shift_code[data] | E0ESC)
		return 0
	} else if shift & E0ESC {
		/* Last character was an E0 escape; or with 0x80 */
		data |= 0x80
		shift &= ~E0ESC
	}

	shift |= shift_code[data]
	shift ^= toggle_code[data]
	c = char_code[shift & (CTL | SHIFT)][data]

	if shift & CAPSLOCK {
		if 'a' <= c && c <= 'z' {
			c += 'A' - 'a'
		} else if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
	}

	return c
}

pub fn kbd_intr() void
{
	console_intr(kbd_getc)
}
