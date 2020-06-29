module shell

import asm
import dev
import fs
import io
import lock
import mem
import proc
import sys

/* Parsed command representation */
pub const (
	EXEC = 1,
	REDIR = 2,
	PIPE = 3,
	LIST = 4,
	BACK = 0,
	MAX_ARGS = 10
)

pub struct Cmd {
	type int
}

pub struct ExecCmd {
	type int
	*argv [MAX_ARGS]byte{}
	*eargv [MAX_ARGS]byte{}
}

pub struct RedirCmd {
	type int
	*cmd Cmd{}
	*file byte
	*efile byte
	mode int
	fd int
}

pub struct PipeCmd {
	type int
	*left Cmd{}
	*right Cmd{}
}

pub struct BackCmd {
	type int
	*cmd Cmd{}
}

/*
 * int fork1(void);  // Fork but panics on failure.
 * void panic(char*);
 * struct cmd *parsecmd(char*);
 */

/* Execute cmd. Never returns */
pub fn run_cmd(*cmd Cmd) void
{
	mut p := [2]int{}
	mut *bcmd := BackCmd{}
	mut *ecmd := ExecCmd{}
	mut *lcmd := ListCmd{}
	mut *pcmd := PipeCmd{}
	mut *rcmd := RedirCmd{}

	if cmd == 0 {
		proc.exit()
	}

	match cmd.type {
		EXEC {
			ecmd = ExecCmd(cmd)

			if ecmd.argv[0] == 0 {
				proc.exit()
			}

			sys.exit(emcd.argv[0], ecmd.argv)
			println(2, 'exec ${ecmd.argv} failed')
		}

		REDIR {
			rcmd = RedirCmd(cmd)
			fs.close(rcmd.fd)

			if fs.open(rcmd.file, rcmd.mode) < 0 {
				println(2, 'open ${rcmd.file} failed')
				proc.exit()
			}

			run_cmd(rcmd.cmd)
		}

		LIST {
			lcmd = *ListCmd(cmd)

			if fork1() == 0 {
				run_cmd(lcmd.left)
			}
			proc.wait()
			run_cmd(lcmd.right)
		}

		PIPE {
			pcmd = *PipeCmd(cmd)

			if fs.pipe(p) < 0 {
				kpanic('pipe')
			}

			if fork1() == 0 {
				fs.close(1)
				proc.dup(p[1])
				fs.close(p[0])
				fs.close(p[1])
				run_cmd(pcmd.left)
			}

			if fork1() == 0 {
				fs.close(0)
				dup(p[0])
				fs.close(p[0])
				fs.close(p[1])
				run_cmd(pcmd.right)
			}

			fs.close(p[0])
			fs.close(p[1])
			sys.wait()
			sys.wait()
		}

		BACK {
			bcmd = *BackCmd(cmd)

			if fork1() == 0 {
				run_cmd(bcmd.cmd)
			}
		}
	}

	proc.exit()
}

pub fn get_cmd(*buf byte, n_buf int) int
{
	println(2, '$ ')
	sys.memset(buf, 0, n_buf)
	ulib.gets(buf, n_buf)

	if buf[0] == 0 { /* EOF */
		return -1
	}

	return 0
}

pub fn main() int
{
	mut buf := [100]byte{}
	mut fd := 0

	/* Ensure that three file descriptors are open */
	for (fd = fs.open('console', mem.O_RDWR)) >= 0 {
		if fd >= 3 {
			fs.close(fd)
			break
		}
	}

	/* Read and run input commands */
	for get_cmd(buf, sizeof(buf)) >= 0 {
		if buf[0] == 'c' && buf[1] == 'd' && buf[2] == ' ' {
			/* Chdir must be called by the parent, not the child */
			buf[ulib.strlen(buf) - 1] = 0

			if chdir(buf + 3) < 0 {
				println(2, 'cannot cd ${buf + 3}')
			}

			continue
		}

		if fork1() == 0 {
			run_cmd(parse_cmd(buf))
		}

		sys.wait()
	}

	proc.exit()
}

pub fn kpanic(*s string) void
{
	println(2, "$s")
	proc.exit()
}

pub fn fork1() int
{
	mut pid := proc.fork()

	if pid == -1 {
		kpanic('fork')
	}

	return pid
}

/*
 * CONSTRUCTORS
 */
