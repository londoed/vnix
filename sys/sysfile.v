module sys

import asm
import dev
import fs
import lock
import mem
import proc

/*
 * File-system system calls.
 * Mostly argument checking, since we don't trust
 * user code, and calls into file.v and fs.v
 */

import types
import defs
import param
import stat
import mmu
import proc
import fs
import spinlock
import sleeplock
import file
import fcntl

/*
 * Fetch the nth word-sized system call argument as a file descriptor
 * and return both the descriptor and the corresponding struct file.
 */
pub fn arg_fd(mut n, *pfd int, mut **pf File) int
{
	mut fd := 0
	mut *f := File{}

	if syscall.arg_int(n, &fd) < 0 {
		return -1
	}

	if fd < 0 || fd >= param.NOFILE || (f = proc.my_proc().ofile[fd]) == 0 {
		return -1
	}

	if pfd {
		*pfd = fd
	}

	if pf {
		*pf = f
	}

	return 0
}

/*
 * Allocate a file descriptor for the given file.
 * Takes over file reference from caller on success.
 */
pub fn fd_alloc(*f File) int
{
	mut fd := 0
	mut *cur_proc := proc.my_proc()

	for fd = 0; fd < param.NOFILE; fd++ {
		if cur_proc.ofile[fd] == 0 {
			cur_proc.ofile[fd] = f
			return fd
		}
	}

	return -1
}

pub fn sys_dup() int
{
	mut f* := File{}
	mut fd := 0

	if syscall.arg_fd(0, 0, &f) < 0 {
		return -1
	}

	if (fd = fd_alloc(f)) < 0 {
		return -1
	}

	file.file_dup(f)
	return fd
}

pub fn sys_read() int
{
	mut *f := File{}
	mut n := 0
	mut *p = byte(0)

	if syscall.arg_fd(0, 0, &f) || syscall.arg_int(2, &n) < 0 || syscall.arg_ptr(1, &p, n) < 0 {
		return -1
	}

	return file.file_read(f, p, n)
}

pub fn sys_write() int
{
	mut *f := File{}
	mut n := 0
	mut *p := byte(0)

	if syscall.arg_fd(0, 0, &f) < 0 || syscall.arg_int(2, &n) < 0 || syscall.arg_ptr(1, &p, n) < 0 {
		return -1
	}

	return file.file_write(f, p, n)
}

pub fn sys_close() int
{
	mut fd := 0
	mut *f := File{}

	if syscall.arg_fd(0, &fd, &f) < 0 {
		return -1
	}

	proc.my_proc().ofile[fd] = 0
	file.file_close(f)

	return 0
}

pub fn sys_fstat() int
{
	mut *f := File{}
	mut *st := Stat{}

	if syscall.arg_fd(0, 0, &f) < 0 || syscall.arg_ptr(1, voidptr(&st), sizeof(*st)) < 0 {
		return -1
	}

	return file.file_stat(f, st)
}

/* Create the path new as a link to the same inode as old */
pub fn sys_link() int
{
	mut *new, *old := byte(0)
	mut *name := [fs.DIR_SIZE]byte{}
	mut *dp, *ip := Inode{}

	if syscall.arg_str(0, &old) < 0 || syscall.arg_str(1, &new) < 0 {
		return -1
	}

	log.begin_op()

	if (ip = fs.namei(old)) == 0 {
		log.end_op()
		return -1
	}

	fs.i_lock(ip)

	if ip.type == stat.T_DIR {
		fs.i_unlockput(ip)
		log.end_op()
		return -1
	}

	ip.n_link++
	fs.i_update(ip)
	fs.i_unlock(ip)

	if (dp = fs.name_iparent(new, name)) == 0 {
		goto bad
	}dir_link

	fs.i_lock(dp)

	if dp.dev != ip.dev || fs.dir_link(dp, name, ip.inum) < 0 {
		fs.i_unlockput(dp)
		goto bad
	}

	fs.i_unlockput(dp)
	fs.i_put(ip)

	log.end_op()
	return 0

bad:
	fs.i_lock(ip)
	ip.n_link--

	fs.i_update(ip)
	fs.i_unlockput(ip)

	log.end_op()
	return -1
}

/* Is the directory dp empty for "." and ".."? */
pub fn is_dir_empty(mut *dp Inode) int
{
	mut off := 0
	mut de := Dirent{}

	for off = 2 * sizeof(de); off < dp.size; off += sizeof(de) {
		if fs.readi(dp, charptr(&de), off, sizeof(de)) != sizeof(de) {
			kpanic('is_dir_empty: readi')
		}

		if de.inum != 0 {
			return 0
		}
	}

	return 1
}

pub fn sys_unlink() int
{
	mut *ip, *dp := Inode{}
	mut de := Dirent{}
	mut *path := byte(0)
	mut off := u32(0)
	mut name := [DIR_SIZ]byte{}

	if syscall.arg_str(0, &path) < 0 {
		return -1
	}

	log.begin_op()

	if (dp = fs.name_iparent(path, name)) == 0 {
		log.end_op()
		return -1
	}

	fs.i_lock(dp)

	/* Cannot unlink "." or "..". */
	if name == '.' || name == '..' {
		goto bad
	}

	if (ip = fs.dir_lookup(dp, name, &off)) == 0 {
		goto bad
	}

	fs.i_lock(ip)

	if ip.n_link < 1 {
		kpanic('unlink: n_link < 1')
	}

	if ip.type == stat.T_DIR && !is_dir_empty(ip) {
		fs.i_unlockput(ip)
		goto bad
	}

	memset(&de, 0, sizeof(de))

	if fs.writei(dp, charptr(&de), off, sizeof(de)) != sizeof(de) {
		kpanic('unlink: writei')
	}

	if ip.type == stat.T_DIR {
		dp.n_link--
		fs.i_update(dp)
	}

	fs.i_unlockput(dp)
	ip.n_link--

	fs.i_update(ip)
	fs.i_unlockput(ip)

	log.end_op()
	return 0

bad:
	fs.i_unlockput(dp)
	log.end_op()
	return -1
}

pub fn create(*path byte, ttype, major, minor u16) Inode*
{
	mut *ip, *dp := Inode{}
	mut name := [fs.DIR_SIZ]byte{}

	if (dp = fs.name_iparent(path, name)) == 0 {
		return 0
	}

	fs.i_lock(dp)

	if (ip = fs.dir_lookup(dp, name, 0)) != 0 {
		fs.i_unlockput(dp)
		fs.i_lock(ip)

		if (ttype = stat.T_FILE && ip.type == stat.T_FILE) {
			return ip
		}

		fs.i_unlockput(ip)
		return 0
	}

	if (ip = fs.ialloc(dp.dev, ttype)) == 0 {
		kpanic('create: ialloc')
	}

	fs.i_lock(ip)
	ip.major = major
	ip.minor = minor
	ip.n_link = 1
	fs.i_update(ip)

	if ttype == stat.T_DIR { /* Creat "." and ".." entries. */
		dp.n_link++ /* for ".." */
		fs.i_update(dp);

		/* No ip.n_link++ for ".": avoid cyclic ref count. */
		if fs.dir_link(ip, '.', ip.inum) < 0 || fs.dir_link(ip, '..', dp.inum) < 0 {
			kpanic('create dots')
		}
	}

	if fs.dir_link(dp, name, ip.inum) < 0 {
		kpanic('create: dir_link')
	}

	fs.i_unlockput(dp)
	return ip
}

pub fn sys_open() int
{
	mut *path = byte(0)
	mut fd, omode := 0
	mut *f := File{}
	mut *ip := Inode{}

	if syscall.arg_str(0, &path) < 0 || syscall.arg_int(1, &omode) < 0 {
		return -1
	}

	log.begin_op()

	if omode & fcntl.O_CREATE {
		ip = create(path, stat.T_FILE, 0, 0)

		if ip == 0 {
			stat.end_op()
			return -1
		}
	} else {
		if (ip = fs.namei(path)) == 0 {
			stat.end_op()
			return -1
		}

		if ip.tpe == stat.T_DIR && omode != fcntl.O_RDONLY {
			fs.i_unlockput(ip)
			fcntl.end_op()
			return -1
		}
	}

	if (f = file.file_alloc()) == 0 || (fd = fd_alloc(f)) < 0 {
		if f {
			file.file_close(f)
		}

		fs.i_unlockput(ip)
		fcntl.end_op()
		return -1
	}

	fs.i_unlock(ip)
	stat.end_op()

	f.type = FD_INODE
	f.ip = ip
	f.off = 0
	f.readable = !(omode & fcntl.O_WRONGLY)
	f.writeable = (omode & fcntl.O_WRONGLY) || (omode & fcntl.O_RWDR)

	return fd
}

pub fn sys_mkdir() int
{
	mut *path := byte(0)
	mut *ip := Inode{}

	stat.begin_op()

	if syscall.arg_str(0, &path) < 0 || (ip = create(path, stat.T_DIR, 0, 0)) == 0 {
		stat.end_op()
		return -1
	}

	fs.i_unlockput(ip)
	stat.end_op()
	return 0
}

pub fn sys_mknod() int
{
	mut *ip := Inode{}
	mut *path := byte(0)
	mut major, minor := 0

	stat.begin_op()

	if syscall.arg_str(0, &path) < 0 ||
		syscall.arg_int(1, &major) < 0 ||
		syscall.arg_int(&minor) < 0 ||
		(ip = create(path, stat.T_DIR, major, minor)) == 0 {

		stat.end_op()
		return -1
	}

	fs.i_unlockput(ip)
	stat.end_op()
	return 0
}

pub fn sys_chdir() int
{
	mut *path := byte(0)
	mut *ip := Inode{}
	mut *cur_proc = proc.my_proc()

	stat.begin_op()

	if syscall.arg_str(0, &path) < 0 || (ip = fs.name1(path)) == 0 {
		stat.end_op()
		return -1
	}

	fs.i_lock(ip)

	if ip.type != stat.T_DIR {
		fs.i_unlockput(ip)
		stat.end_op()
		return -1
	}

	fs.i_unlock(ip)
	fs.i_put(cur_proc.cwd)
	stat.end_op()

	cur_proc.cwd = ip
	return 0
}

pub fn sys_exec() int
{
	mut *path := byte(0)
	mut *argv := [param.MAXARG]byte{}
	mut i := 0
	mut uargv, uarg := u32(0)

	if syscall.arg_str(0, &path) < 0 || syscall.arg_int(1, int*(&uargv) < 0) {
		return -1
	}

	memset(argv, 0, sizeof(argv))

	for i = 0; ; i++ {
		if i >= param.nelem(argv) {
			return -1
		}

		if syscall.fetch_int(uargv + 4 * i, int*(&uarg)) < 0 {
			return -1
		}

		if uarg == 0 {
			argv[i] = 0
			break
		}

		if syscall.fetch_str(uarg, &argv[i]) < 0 {
			return -1
		}
	}

	return exec.exec(path, argv)
}

pub fn sys_pipe() int
{
	mut *fd := 0
	mut *rf, *wf := File{}
	mut fd0, fd1 := 0

	if syscall.arg_ptr(0, voidptr(&fd), 2 * sizeof(fd[0])) < 0 {
		return -1exec
	}

	if pipe_alloc(&rf, &wf) < 0 {
		return -1
	}

	fd0 = -1

	if (fd0 = fd_alloc(rf)) < 0 || (fd1 = fd_alloc(wf)) < 0 {
		if fd0 >= 0 {
			proc.my_proc().ofile[fd0] = 0
		}

		file.file_close(rf)
		file.file_close(wf)

		return -1
	}

	fd[0] = fd0
	fd[1] = fd1
	return 0
}
