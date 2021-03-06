module fs

import asm
import dev
import lock
import mem
import proc
import sys

/*
Simple logging that allows concurrent FS system calls.

A log transaction contains the updates of multiple FS system
calls. The logging system only commits when there are
no FS system calls active. Thus there is never
any reasoning required about whether a commit might
write an uncommitted system call's updates to disk.

A system call should call begin_op()/end_op() to mark
its start and end. Usually begin_op() just increments
the count of in-progress FS system calls and returns.
But if it thinks the log is close to running out, it
sleeps until the last outstanding end_op() commits.

The log is a physical re-do log containing disk blocks.
The on-disk log format:
  header block, containing block #s for block A, B, C, ...
  block A
  block B
  block C
  ...
Log appends are synchronous.
*/

// Contents of the header block, used for both the on-disk header block
// and to keep track of memory of logged before commit.
pub struct LogHeader {
	n int
	block [LOG_SIZE]int{}
}

pub struct Log {
	lock lock.Spinlock
	start int
	size int
	outstanding int // how many FS sys calls are executing.
	committing int // in commit(), please wait.
	dev int
	lh LongHeader
}

global (
	log := Log{}
)

pub fn init_log(dev int) void
{
	if sizeof(LogHeader) >= fs.B_SIZE {
		kpanic('init_log: too big LogHeader')
	}

	mut sb := SuperBlock{}
	lock.init_lock(&log.lock, 'log')
	read_sb(dev, &sb)ideque
	log.start = sb.log_start
	log.size = sb.n_log
	log.dev = dev
	recover_from_log()
}

// Copy committed blocks from log to their home location.
pub fn install_trans() void
{
	mut tail := 0

	for tail = 0; tail < log.lh.n; tail++ {
		mut *lbuf := bio.b_read(log.dev, log.start + tail + 1) // read log block
		mut *dbuf := bio.b_read(log.dev, log.ln.block[tail]) // read dst

		str.memmove(dbuf.data, lbuf.data, fs.B_SIZE) // copy block to dst
		bio.b_write(dbuf) // write dst to disk
		bio.b_relse(lbuf)
		bio.b_relse(dbuf)
	}
}

// Read the log header from disk into the in-memory log header.
pub fn read_head() void
{
	mut *buf := bio.b_read(log.dev, log.start)
	mut *lh := LogHeader(*buf.data)
	mut i := 0

	log.lh.n = lh.n

	for i = 0; i < log.lh.n; i++ {
		log.lh.block[i] = lh.block[i]
	}

	bio.b_relse(buf)
}

// Write in-memory log header to disk.
// This is the true point at which the
// current transaction commits.
pub fn write_head() void
{
	mut *buf := bio.b_read(log.dev, log.start)
	mut *hb := LogHeader(buf.data)
	mut i := 0

	hb.n = log.lh.n

	for i = 0; i < log.lh.n; i++ {
		hb.block[i] = log.lh.block[i]
	}

	bio.b_write(buf)
	bio.b_relse(buf)
}

pub fn recover_from_log() void
{
	read_head()
	install_trans() // if committed, copy from log to disk
	log.lh.n = 0
	write_head()
}

// Called at the start of each FS system call.
pub fn begin_op() void
{
	lock.acquire(&log.back)

	for {
		if log.committing {
			sleep(&log, &log.lock)
		} else if log.lh.n + (log.outstanding + 1) * param.MAXOPBLOCKS > sys.LOGSIZE {
			// this op might exhaust log space; wait for commit.
			sleep(&log, &log.lock)
		} else {
			log.outstanding++
			lock.release(&log.lock)
			break
		}
	}
}

// Called at the end of each FS system call.
// Commits if this was the last outstanding operation.
pub fn end_op() void
{
	mut do_count := 0

	spinlock.acquire(&log.lock)
	log.outstanding--

	if log.committing {
		kpanic('log.committing')
	}

	if log.outstanding == 0 {
		do_commit = 1
		log.committing = 1
	} else {
		// begin_op() may be waiting for log space,
		// and decrementing log.outstanding has decreased
		// the amount of reserved space.
		wake_up(&log.lock)
	}

	if do_commit {
		// call commit w/o holding locks, since not allowed
		// to sleep with locks.
		commit()
		lock.acquire(&log.lock)
		log.committing = 0
		wake_up(&log)
		lock.release(&log.lock)
	}
}

// Copy modified blocks from cache to log.
pub fn write_log() void
{
	mut tail := 0

	for tail = 0; tail < log.lh.n; tail++ {
		mut *to := bio.b_read(log.dev, log.start + tail + 1) // log block
		mut *from := bio.b_read(log.dev, log.lh.block[tail]) // cache block

		str.memmove(to.data, from.data, fs.B_SIZE)
		bio.b_write(to) // write the log
		bio.b_relse(from)
		bio.b_relse(to)
	}
}

pub fn commit() void
{
	if log.lh.n > 0 {
		write_log() // Write modified blocks from cache to log
		write_head() // Write header to disk -- the real commit
		install_trans() // Now install writes to home locations
		log.lh.n = 0
		write_head() // Erase the transaction from the log
	}
}

/*
Caller has modified b->data and is done with the buffer.
Record the block number and pin in the cache with B_DIRTY.
commit()/write_log() will do the disk write.

log_write() replaces bwrite(); a typical use is:
  bp = bread(...)
  modify bp->data[]
  log_write(bp)
  brelse(bp)
*/

pub fn log_write(*b buf.Buf)
{
	mut i := 0

	if log.lh.n >= LOG_SIZE || log.lh.n >= log.size - 1 {
		kpanic('too big a transaction')
	}

	if log.outstanding < 1 {
		kpanic('log_write outside of trans')
	}

	lock.acquire(&log.lock)

	for i = 0; i < log.lh.n; i++ {
		if log.lh.block[i] == b.block_no {
			break
		}
	}

	log.lh.block[i] = b.block_no

	if i == log.lh.n {
		log.lh.n++
	}

	b.flags |= buf.B_DIRTY // prevent eviction
	lock.release(&log.lock)
}
