module sys

import asm
import dev
import fs
import lock
import mem
import proc

const (
	SYS_FORK = 1,
	SYS_EXIT = 2,
	SYS_WAIT = 3,
	SYS_PIPE = 4,
	SYS_READ = 5,
	SYS_KILL = 6,
	SYS_EXEC = 7,
	SYS_FSTAT = 8,
	SYS_CHDIR = 9,
	SYS_DUP = 10,
	SYS_GETPID = 11,
	SYS_SBRK = 12,
	SYS_SLEEP = 13,
	SYS_UPTIME = 14,
	SYS_OPEN = 15,
	SYS_WRITE = 16,
	SYS_MKNOD = 17,
	SYS_UNLINK = 18,
	SYS_LINK = 19,
	SYS_MKDIR = 20,
	SYS_CLOSE = 21,
)

/*
User code makes a system call with INT T_SYSCALL.
System call number in %eax.
Arguments on the stack, from the user call to the C
library system call function. The saved user %esp points
to a saved program counter, and then the first argument.
*/

// Fetch the int at addr from the current process.
pub fn fetch_int(addr byte, *ip int) int
{
	mut *cur_proc := proc.my_proc()

	if add >= cur_proc.sz || addr + 4 > cur_proc.sz {
		return -1
	}

	mut *ip := *int(*addr)
	return 0
}

/*
Fetch the nul-terminated string at addr from the current process.
Doesn't actually copy the string - just sets *pp to point at it.
Returns length of string, not including nul.
*/

pub fn fetch_str(addr byte, **p byte) int
{
	mut *s, *ep := byte('')
	mut *cur_proc := proc.my_proc()

	if addr >= cur_proc.sz {
		return -1
	}

	*pp = charptr(addr)
	mut ep := charptr(cur_proc.sz)

	for s := *pp; s < ep; s++ {
		if *s == 0 {
			return s - *pp
		}
	}

	return -1
}

// Fetch the nth 32-bit system call argument.
pub fn arg_int(n, *ip int) int
{
	return fetch_int((proc.my_proc().tf.esp) + 4 + 4 * n, ip)
}

/*
Fetch the nth word-sized system call argument as a pointer
to a block of memory of size bytes.  Check that the pointer
lies within the process address space.
*/
pub fn arg_ptr(n int, *pp byte, size int) int
{
	mut i := 0
	mut *cur_proc := proc.my_proc()

	if arg_int(n, &i) < 0 {
		return -1
	}

	if size < 0 || u32(i) >= cur_proc.sz || u32(i) + size > cur_proc.sz {
		return -1
	}

	*pp = charptr(i)
	return 0
}

pub fn arg_str(n int, **pp string) int
{
	mut addr := 0

	if arg_int(n, &addr) < 0 {
		return -1
	}

	return fetch_str(addr, pp)
}

pub fn sys_call() void
{
	sys_calls := {
		SYS_FORK: sys.sys_fork(),
		SYS_EXIT: sys.sys_exit(),
		SYS_WAIT: sys.sys_wait(),
		SYS_PIPE: sys.sys_pipe(),
		SYS_READ: sys.sys_read(),
		SYS_KILL: sys.sys_kill(),
		SYS_EXEC: sys.sys_exec(),
		SYS_FSTAT: sys.sys_fstat(),
		SYS_CHDIR: sys.sys_chdir(),
		SYS_DUP: sys.sys_dup(),
		SYS_GETPID: sys.sys_getpid(),
		SYS_SBRK: sys.sys_sbrk(),
		SYS_SLEEP: sys.sys_sleep(),
		SYS_UPTIME: sys.sys_uptime(),
		SYS_OPEN: sys.sys_open(),
		SYS_WRITE: sys.sys_write(),
		SYS_MKNOD: sys.sys_mknod(),
		SYS_UNLINK: sys.sys_unlink(),
		SYS_LINK: sys.sys_unlink(),
		SYS_MKDIR: sys.sys_mkdir(),
		SYS_CLOSE: sys.sys_close(),
	}

	mut num := 0
	mut *cur_proc := proc.my_proc()

	num = cur_proc.tf.eax

	if num > 0 && num < param.nelem(sys_calls) && sys_calls[num.str()] {
		cur_proc.tf.eax = sys_calls[num.str()]
	} else {
		println('${cur_proc.pid} ${cur_proc.name}: unknown sys call $num')
		cur_proc.tf.eax = -1
	}
}
