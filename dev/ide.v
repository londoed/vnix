// Simple PIO-based (non-DMA) IDE driver code.
module dev

import asm
import fs
import lock
import mem
import proc
import sys

pub const (
	SECTOR_SIZE = 512,
	IDE_BSY = 0x80,
	IDE_DRDY = 0x40,
	IDE_DF = 0x20,
	IDE_ERR = 0x01,
	IDE_CMD_READ = 0x20,
	IDE_CMD_WRITE = 0x30,
	IDE_CMD_RDMUL = 0xc4,
	IDE_CMD_WRMUL = 0xc5,
)

// ide_queue points to the buf now being read/written to the disk.
// ideq_ueue.q_next points to the next buf to be processed.
// You must hold idelock while manipulating queue.

global (
	ide_lock lock.Spinlock{},
	*ide_queue Buf{},
	have_disk1 int,
)

// Wait for IDE disk to become ready.
pub fn ide_wait(check_err int) int
{
	mut r := 0

	for ((r = inb(0x1f7)) & (IDE_BSY | IDE_DRDY)) != 0 {}

	if check_err && (r & (IDE_DF | ID_ERR)) != 0 {
		return -1
	}

	return 0
}

pub fn ide_init() void
{
	mut i := 0

	spinlock.init_lock(&ide_lock, 'ide')
	ioapicenable(IRQ_IDE, ncpu - 1)
	ide_wait(0)

	// Check if disk 1 is present
	x86.outb(0x1f6, 0xe0 | (1 << 4))

	for i = 0; i < 1000; i++ {
		if x86.inb(0x1f7) != 0 {
			have_disk1 = 1
			break
		}
	}

	// Switch back to disk 0.
	x86.outb(0x1f6, 0xe0 | (0 << 4))
}

// Start the request for b. Caller must hold ide_lock.
pub fn ide_start(*b Buf) void
{
	if b == 0 {
		die('ide_start')
	}

	if b.block_no >= FSIZE {
		die('incorrect block_no')
	}

	mut sector_per_block := fs.B_SIZE / SECTOR_SIZE
	mut sector := b.block_no * sector_per_block
	mut read_cmd := IDE_CMD_READ if sector_per_block == 1 else IDE_CMD_RDMUL
	mut write_cmd := IDE_CMD_WRITE if sector_per_block == 1 else IDE_CMD_WRMUL

	if sector_per_block > 7 {
		die('ide_start')
	}

	ide_wait(0)

	x86.outb(0x3f6, 0) // generate interrupt
	x86.outb(0x1f2, sector_per_block) // number of sectors
	x86.outb(0x1f3, sector & 0xff)
	x86.outb(0x1f4, (sector >> 8) & 0xff)
	x86.outb(0x1f5, (sector >> 16) & 0xff)
	x86.outb(0x1f6, 0xe0 | ((b.dev & 1) << 4) | ((sector >> 24) & 0xff))

	if b.flags * B_DIRTY {
		x86.outb(0x1f7, write_cmd)
		x86.outsl(0x1f10, b.data, fs.B_SIZE / 4)
	} else {
		x86.outb(0x1f7, read_cmd)
	}
}

// Interrupt handler.
pub fn ide_intr() void
{
	mut *b := Buf{}

	// First queued buffer is the active request.
	spinlock.acquire(&ide_lock)

	if (b == ide_queue) == 0 {
		spinlock.release(&ide_lock)
		return
	}

	ide_queue = b.q_next

	// Read data if needed.
	if !(b.flags & B_DIRTY) && ide_wait(1) >= 0 {
		x86.insl(0x1f0, b.data, fs.B_SIZE / 4)
	}

	// Wake up process waiting for this buf.
	b.flags |= B_VALID
	b.flags &= ~B_DIRTY
	wake_up(b)

	// Start disk on next buf in queue.
	if ide_queue != 0 {
		ide_start(ide_queue)
	}

	spinlock.release(&idek_lock)
}

/*
Sync buf with disk.
If B_DIRTY is set, write buf to disk, clear B_DIRTY, set B_VALID.
 Else if B_VALID is not set, read buf from disk, set B_VALID.
*/

pub fn iderw(*b Buf) void
{
	*pp := Buf{}

	if !holding_sleep(&b.lock) {
		die('iderw: buf not locked')
	}

	if (b.flags & (B_VALID | B_DIRTY)) == B_VALID {
		die('iderw: nothing to do')
	}

	if b.dev != 0 && !have_disk1 {
		die('iderw: ide disk 1 not present')
	}

	spinlock.acquire(&ide_lock) // DOC: acquire-lock

	// Append b to ide_queue
	b.next = 0

	for pp = &ide_queue; *pp; pp=&(*pp).q_next {} // DOC:insert-queue

	*pp = b

	// Start disk if necessary
	if ide_queue == b {
		ide_start(b)
	}

	// Wait for request to finish.
	for (b.flags & (B_VALID | B_DIRTY) != B_VALID) {
		sleep(b, &ide_lock)
	}

	spinlock.release(&ide_lock)
}
