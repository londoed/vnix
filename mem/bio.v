module mem

import asm
import dev
import fs
import lock
import proc
import sys

/*
Buffer cache.

The buffer cache is a linked list of buf structures holding
cached copies of disk block contents.  Caching disk blocks
in memory reduces the number of disk reads and also provides
a synchronization point for disk blocks used by multiple processes.

Interface:
* To get a buffer for a particular disk block, call bread.
* After changing buffer data, call bwrite to write it to disk.
* When done with the buffer, call brelse.
* Do not use the buffer after calling brelse.
* Only one process at a time can use a buffer,
 	so do not keep them longer than necessary.

The implementation uses two state flags internally:
* B_VALID: the buffer data has been read from the disk.
* B_DIRTY: the buffer data has been modified
    and needs to be written to disk.
*/


pub struct BCache {
	lock spinlock.Spinlock
	buf [param.NBUF]buf.Buf{}

	// Linked list of all buffers, through prev/next.
	// head.next is most recently used
	head buf.Buf
}

pub fn b_init() void
{
	mut *b := buf.Buf{}

	spinlock.init_lock(&BCache.lock, 'bcache')

	// Create linked list of buffers.
	BCache.head.prev = &BCache.head
	BCache.head.next = &BCache.head

	for b = BCache.buf; b < BCache.buf + param.NBUF; b++ {
		b.next = BCache.head.next
		b.prev = BCache.head

		sleeplock.init_sleeplock(&b.lock, 'buffer')
		BCache.head.next.prev = b
		BCache.head.next = 0
	}
}

/*
Look through buffer cache for block on device dev.
If not found, allocate a buffer.
In either case, return locked buffer.
*/

pub fn b_get(dev, block_no u32) buf.Buf*
{
	mut *b := buf.Buf{}

	spinlock.acquire(&BCache.lock)

	// Is the block already cached?
	for b = BCache.head.next; b != &BCache.head; b = b.next {
		if b.dev == dev && b.block_no == block_no {
			b.ref_cnt++
			spinlock.release(&BCache.lock)
			sleeplock.acquire_sleep(&b.lock)
			return b
		}
	}

	// Not cached; recycle an unused buffer.
	// Even if ref_cnt==0, B_DIRTY indicates a buffer is in use
	// because log.v has modified it but not yet committed it.
	for b = BCache.head.prev; b != &BCache.head; b = b.prev {
		if b.ref_cnt == 0 && (b.flags & buf.B_DIRTY) == 0 {
			b.dev = dev
			b.block_no = block_no
			b.flags = 0
			b.ref_cnt = 1

			spinlock.release(&BCache.lock)
			acquire_sleep(&b.lock)
			return b
		}
	}

	die('b_get: no buffers')
}

// Return a lock buf with the contents of the indicated block.
pub fn b_read(dev, block_no u32) buf.Buf*
{
	mut *b := buf.Buf{}

	b = b_get(dev, block_no)

	if b.flags & buf.B_VALID == 0 {
		ide.iderw(b)
	}

	return b
}

// Write b's contents to disk. Must be locked.
pub fn b_write(*b buf.Buf) void
{
	if !holding_sleep(&b.lock) {
		die('b_write')
	}

	b.flags |= buf.B_DIRTY
	ide.iderw(b)
}

// Release a locked buffer.
// Move to head of the MRU list.
pub fn b_relse(*b buf.Buf) void
{
	if !holding_sleep(&b.lock) {
		die('b_relse')
	}

	sleeplock.release_sleep(&b.lock)
	spinlock.acquire(&BCache.lock)
	b.ref_cnt--

	if b.ref_cnt == 0 {
		// No one is waiting for it.
		b.next.prev = b.prev
		b.prev.next = b.next
		b.next = BCache.head.next
		b.prev = BCache.head

		BCache.head.next.prev = b
		BCache.head.next = b
	}

	spinlock.release(&BCache.lock)
}
