module sys

import asm
import dev
import fs
import lock
import mem
import proc

pub fn sys_fork() int
{
	return proc.fork()
}

pub fn sys_exit() int
{
	proc.exit()
	return 0
}

pub fn sys_wait() int
{
	return proc.wait()
}

pub fn sys_kill() int
{
	mut pid := 0

	if sys.arg_int(0, &pid) < 0 {
		return -1
	}

	return proc.kill(pid)
}

pub fn sys_getpid() int
{
	return proc.my_proc().pid
}

pub fn sys_sbrk() int
{
	mut addr, n := 0

	if sys.arg_int(0, &n) < 0 {
		return -1
	}

	addr = proc.my_proc().sz

	if proc.grow_proc(n) < 0 {
		return -1
	}

	return addr
}

pub fn sys_sleep() int
{
	mut n := 0
	mut ticks0 := u32(0)

	if sys.arg_int(0, &n) < 0 {
		return -1
	}

	lock.acquire(&ticks_lock)
	ticks0 = ticks

	for ticks - ticks0 < n {
		if proc.my_proc().killed {
			lock.release(&ticks_lock)
			return -1
		}

		proc.sleep(&ticks, &ticks_lock)
	}

	lock.release(&ticks_lock)
	return 0
}

/*
 * Return how many clock tick interrupts have occurred
 * since start.
 */
pub fn sys_uptime() int
{
	mut xticks := u32(0)

	lock.acquire(&ticks_lock)
	xticks = ticks
	lock.release(&ticks_lock)
	return xticks
}
