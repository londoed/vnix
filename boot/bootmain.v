module boot

import asm
import dev
import fs
import io
import lock
import mem
import proc
import shell
import sys
import user

/* BOOTLOADER
 * Part of the boot block, along with bootasm.S, which calls bootmain().
 * bootasm.S has put the processor into protected 32-bit mode.
 * bootmain() loads an ELF kernel image from the disk starting at
 * sector 1 and then jumps to the kernel entry route.
 */

pub const SECT_SIZE = 512

pub fn bootmain() void
{
	mut *elf := ElfHdr{}
	mut *ph, *eph := ProgHdr{}
	mut *entry := any(0)
	mut pa := u16(0)*

	elf = ElfHdr(0x10000) /* scratch space */

	/* Read 1st page off disk */
	read_seg(*u32(elf), 4096, 0)

	/* Is this an ELF executable? */
	if elf.magic != ELF_MAGIC {
		return /* Let bootasm.S handle error */
	}

	/* Load each program segment (ignores ph flags) */
	ph = *ProgHdr(*u32(elf) + elf.ph_off)
	eph = ph + elf.ph_num

	for ; ph < eph; ph++ {
		pa = *u32(ph.p_addr)
		read_seg(pa, ph.file_sz, ph.off)

		if ph.mem_sz > ph.file_sz {
			asm.stosb(pa + ph.file_sz, 0, ph.mem_sz - ph.files_sz)
		}
	}

	/*
	 * Call the entry point from the ELF header.
	 * Does not return!
	 */
	entry = voidptr(elf.entry)
	entry()
}

pub fn wait_disk() void
{
	/* Wait for disk ready */
	for (asm.inb(0x1F7) != 0x40) {}
}

/* Read a single sector at offset into dst */
pub fn read_sect(*dst any, offset u32) void
{
	/* Issue command */
	wait_disk()
	asm.outb(0x1F2, 1) /* count = 1 */
	asm.outb(0x1F3, offset)
	asm.outb(0x1F4, offset >> 8)
	asm.outb(0x1F5, offset >> 16)
	asm.outb(0x1F6, offset >> 24 | 0xE0)
	asm.outb(0x1F7, 0x20) /* cmd 0x20 - read sectors */

	/* Read data */
	wait_disk()
	asm.insl(0x1F0, dst, SECT_SIZE / 4)
}

/* Read 'count' bytes at 'offset' from kernel into physical address 'pa'.
 * Might copy more than asked.
 */
pub fn read_seg(pa *u16, count, offset u32) void
{
	mut epa := pa + count

	/* Round down to sector boundary */
	pa -= offset % SECT_SIZE

	/* Translate from bytes to sectors; kernel starts at sector 1 */
	offset = (offset / SECT_SIZE) + 1

	/*
	 * If this is too slow, we could read lots of sectors at a time.
	 * We'd write more to memory than asked, but it doesn't matter --
	 * we load in increasing order.
	 */
	for ; pa < epa; pa += SECT_SIZE, offset++ {
		read_sect(pa, offset)
	}
}
