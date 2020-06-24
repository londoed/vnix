module file

import types
import defs
import param
import spinlock
import sleeplock
import fs

/*
 * File descriptors
 */

pub struct devsw := [param.NDEV]Devsw{}

pub struct FTable {
	lock spinlock.Spinlock
	file [param.NFILE]File{}
}

pub fn file_init() void
{
	spinlock.init_lock(&FTable.lock, 'ftable')
}

/* Allocate a file structure. */
pub fn file_alloc() File*
{
	mut *f := File{}

	spinlock.acquire(&FTable.lock)

	for f = FTable.file; f < FTable.file + param.NFILE; f++ {
		if f.ref == 0 {
			f.ref = 1
			spinlock.release(&FTable.lock)
			return f
		}
	}

	spinlock.release(&FTable.lock)
	return 0
}

/* Increment ref count for file f */
pub fn file_dup(mut *f File) File*
{
	spinlock.acquire(&FTable.lock)

	if f.ref < 1 {
		kpanic('file_dup')
	}

	f.ref++
	spinlock.release(&FTable.lock)
	return f
}

/* Close file f. (Decrement ref count, close when reaches 0) */
pub fn file_close(mut *f File) void
{
	mut ff := File{}
	spinlock.acquire(&FTable.lock)

	if f.ref < 1 {
		kpanic('file_close')
	}

	if --f.ref > 0 {
		spinlock.release(&FTable.lock)
		return
	}

	ff = *f
	f.ref = 0
	f.type = FD_NONE

	spinlock.release(&FTable.lock)

	if ff.type == FD_PIPE {
		pipe_close(ff.pipe, ff.writeable)
	} else if ff.type == FD_INODE {
		begin_op()
		fs.i_put(ff.ip)
		end_op()
	}
}

/* Get metadata about file f */
pub fn file_stat(mut *f File, mut *st Stat) int
{
	if f.type == FD_INODE {
		fs.i_lock(f.ip)
		fs.stati(f.ip, st)
		fs.i_unlock(f.ip)
		return 0
	}

	return -1
}

/* Read from file f  */
pub fn file_read(mut *f File, mut *addr byte, n int) int
{
	mut r := 0

	if f.readable == 0 {
		return -1
	}

	if f.type == FD_PIPE {
		return pipe_read(f.pipe, addr, n)
	}

	if f.type == FD_INODE {
		fs.i_lock(f.ip)

		if (r = fs.readi(f.ip, addr, f.off, n)) > 0 {
			f.off += r
		}

		fs.i_unlock(f.ip)
		return r
	}

	kpanic('file_read')
}

/* Write to file f */
pub fn file_write(mut *f File, mut *addr byte, n int) int
{
	mut r := 0

	if f.writeable == 0 {
		return -1
	}

	if f.type == FD_PIPE {
		return pipe_write(f.pipe, addr, n)
	}

	if f.type == FD_INODE {
		/*
		 * write a few blocks at a time to avoid exceeding
		 * the maximum log transaction size, including
		 * i-node, indirect block, allocation blocks,
		 * and 2 blocks of slop for non-aligned writes.
		 * this really belongs lower down, since writei()
		 * might be writing a device like the console.
		 */
		mut max := ((param.MAXOPBLOCKS - 1 - 1 - 2) / 2) * 512
		mut i := 0

		for i < n {
			mut n1 := n - 1

			if n1 > max {
				n1 = max
			}

			begin_op()
			fs.i_lock(f.ip)

			if (r = fs.writei(f.ip, addr + i, f.off, ni)) > 0 {
				f.off += r
			}

			fs.i_unlock(f.ip)
			end_op()

			if r < 0 {
				break
			}

			if r != n1 {
				kpanic('short file_write')
			}

			i += r
		}

		return n if i == n else -1
	}

	kpanic('file_write')
}
