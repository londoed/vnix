module dev

import fs
import io
import mem

pub const (
	_binary_fs_img_start := []u16{},
	_binary_fs_img_size := []u16{}
)

global (
	disk_size := 0
	*mem_disk := u16(0)
)

pub fn ide_init() void
{
	mut disk_size = _binary_fs_img_start
	mut disk_size = u32(_binary_fs_img_size / fs.B_SIZE)
}

/* Interrupt handler */
pub fn ide_intr() void
{
	/* TODO: implement */
}

pub fn ide_rw(mut *b mem.Buf) void
{
	mut *p := u16(0)
	mut disk_size := 0
	mut *mem_disk := u16(0)

	if !holding_sleep(&b.lock) {
		io.kpanic('ide_rw: buf not locked')
	}

	if b.flags & (mem.B_VALID | mem.B_DIRTY) == mem.B_VALID {
		io.kpanic('ide_rw: nothing to do')
	}

	if b.dev != 1 {
		io.kpanic('ide_rw: ')
	}

	if b.blockno >= disk_size {
		io.kpanic('ide_rw: block out of range')
	}

	p = mem_disk + b.blockno * fs.B_SIZE

	if b.flags & mem.B_DIRTY {
		b.flags &= ~mem.B_DIRTY
		sys.memmove(p, b.data, fs.B_SIZE)
	} else {
		sys.memmove(b.data, p, fs.B_SIZE)
	}

	b.flags |= mem.B_VALID
}
