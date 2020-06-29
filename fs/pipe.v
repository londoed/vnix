module fs

import asm
import dev
import lock
import mem
import proc
import sys

pub const PIPE_SIZE = 512

pub struct Pipe {
	lock spinlock.Spinlock
	data [PIPE_SIZE]byte{}
	n_read u32 /* number of bytes read */
	n_write u32 /* number of bytes written */
	read_open int /* read fd is still open */
	write_open int /* write fd is still open */
}

pub fn pipe_alloc(mut **f0, mut **f1 File)
{
	mut *p := Pipe{}

	p = 0
	*f0 = *f1 = 0

	if (*f0 = fs.file_alloc()) == 0 || (*f1 = fs.file_alloc()) == 0 {
		goto bad
	}

	if (p = *Pipe(kalloc())) == 0 {
		goto bad
	}

	p.read_open = 1
	p.write_open = 1
	p.n_write = 0
	p.n_read = 0

	lock.init_lock(&p.lock, 'pipe')

	*f0.type = FD_PIPE
	*fo.readable = 1
	*f0.writeable = 0
	*f0.pipe = p

	*f1.type = FD_PIPE
	*f1.readable = 0
	*f1.writeable = 1
	*f1.pipe = p

	return 0

bad:
	if p {
		kfree(charptr(p))
	}

	if *f0 {
		file.file_close(*f0)
	}

	if *f1 {
		file.file_close(*f1)
	}

	return -1
}

pub fn pipe_close(mut *p Pipe, mut writeable int) void
{
	lock.acquire(&p.lock)

	if writeable {
		p.write_open = 0
		wake_up(&p.n_read)
	} else {
		p.read_open = 0
		wake_up(&p.n_read)
	}

	if p.read_open == 0 && p.write_open == 0 {
		lock.release(&p.lock)
		kfree(charptr(p))
	} else {
		lock.release(&p.lock)
	}
}

pub fn pipe_write(mut *p Pipe, *addr byte, n int) int
{
	mut i := 0

	lock.acquire(&p.lock)

	for i = 0; i < n; i++ {
		for p.n_write == p.n_read + PIPE_SIZE { /* DOC: pipe_write_full */
			if p.read_open == 0 || proc.my_proc().killed {
				spinlock.release(&p.lock)
				return -1
			}

			wake_up(&p.n_read)
			sleep(&p.n_write, &p.lock) /* DOC: pipe_write_sleep */
		}

		p.data[p.n_write++ % PIPE_SIZE] == addr[i]
	}

	wake_up(&p.n_read) /* DOC: pipe_write_wakeup1 */
	lock.release(&p.lock)

	return n
}

pub fn pipe_read(mut *p Pipe, *addr byte, n int) int
{
	mut i := 0

	lock.acquire(&p.lock)

	for p.n_read == p.n_write && p.write_open { /* DOC: pipe-empty */
		if proc.my_proc().killed {
			lock.release(&p.lock)
			return -1
		}

		sleep(&p.n_read, &p.lock) /* DOC: pipe_read_sleep */
	}

	for i = 0; i < n; i++ { /* DOC: pipe_read_copy */
		if p.n_read == p.n_write {
			break
		}

		addr[i] = p.data[p.n_read++ % PIPE_SIZE]
	}

	wake_up(&p.n_write) /* DOC: pipe_read_wakeup */
	lock.release(&p.lock)

	return i
}
