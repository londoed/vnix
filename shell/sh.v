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

pub fn exec_cmd() Cmd*
{
	mut *cmd := ExecCmd{}
	cmd = malloc(sizeof(*cmd))
	sys.memset(cmd, 0, sizeof(*cmd))
	cmd.type = EXEC

	return *Cmd(cmd)
}

pub fn redir_cmd(*sub_cmd Cmd, *file byte, *efile, byte, mode, fd int) Cmd*
{
	mut *cmd = *RedirCmd{}
	cmd = malloc(sizeof(*cmd))
	sys.memset(cmd, 0, sizeof(*cmd))

	cmd.type = REDIR
	cmd.cmd = sub_cmd
	cmd.file = file
	cmd.efile = efile
	cmd.mode = mode
	cmd.fd = fd

	return *Cmd(cmd)
}

pub fn pipe_cmd(*left, *right Cmd) Cmd*
{
	mut *cmd := PipeCmd{}
	cmd = malloc(sizeof(*cmd))
	sys.memset(cmd, 0, sizeof(*cmd))

	cmd.type = PIPE
	cmd.left = left
	cmd.right = right

	return *Cmd(cmd)
}

pub fn list_cmd(*left, *right Cmd) Cmd*
{
	mut *cmd = ListCmd{}
	sys.memset(cmd, 0, sizeof(*cmd))

	cmd.type = LIST
	cmd.left = left
	cmd.right = right

	return *Cmd(cmd)
}

pub fn back_cmd(*sub_cmd Cmd) Cmd*
{
	mut *cmd := BackCmd{}

	cmd = malloc(sizeof(*cmd))
	sys.memset(cmd, 0, sizeof(*cmd))

	cmd.type = BACK
	cmd.cmd = sub_cmd

	return *Cmd(cmd)
}

global (
	whitespace = ' \t\r\n\v'
	symbols = '<|>&;()'
)

pub fn get_token(**ps, *es, **q, **eq byte) int
{
	mut *s := byte(0)
	mut ret := 0

	s = *ps

	for s < es && strchr(whitespace, *s) {
		s++
	}

	if q {
		*q = s
	}

	ret = s

	match *s {
		0 {
			break
		}

		'|' || '(' || ')' || ';' || '&' || '<' {
			s++
		}

		'>' {
			s++

			if *s == '>' {
				ret = '+'
				s++
			}
		}

		else {
			ret = 'a'

			for s < es && !strchr(whitespace, *s) && !strchr(symbols, *s) {
				s++
			}
		}
	}

	if eq {
		*eq = s
	}

	for s < es && strchr(whitespace, *s) {
		s++
	}

	*ps = s

	return ret
}

pub fn peek(**ps, *es, *toks byte) int
{
	mut *s := *ps

	for s < es && strchr(whitespace, *s) {
		s++
	}

	*ps = s

	return *s && strchr(toks, *s)
}

global (
	*parse_line Cmd{}
	*parse_pipe Cmd{}
	*parse_exec Cmd{}
	*nul_temninate Cmd{}
)

pub fn parse_cmd(*s byte) Cmd*
{
	mut *es := byte(0)
	mut *cmd := Cmd{}

	es = s + sys.strlen(s)
	cmd = parse_line(&s, es)
	peek(&s, es, '')

	if s != es {
		println(2, 'leftovers: $s')
		kpanic('syntax')
	}

	nul_terminate(cmd)
	return cmd
}

pub fn parse_line(**ps, *es byte) Cmd*
{
	mut *cmd := Cmd{}

	cmd = parse_pipe(ps, es)

	for peek(ps, es, '&') {
		get_token(ps, es, 0, 0)
		cmd = back_cmd(cmd)
	}

	if peek(ps, es, ';') {
		get_token(ps, es, 0, 0)
		cmd = list_cmd(cmd, parse_line(ps, es))
	}

	return cmd
}

pub fn parse_pipe(**ps, *es byte) Cmd*
{
	mut *cmd := Cmd{}

	cmd = parse_exec(ps, es)

	if peek(ps, es, '|') {
		get_token(ps, es, 0, 0)
		cmd = pipe_cmd(cmd, parse_pipe(ps, es))
	}

	return cmd
}

pub fn parse_redirs(*cmd Cmd, **ps, *es byte) Cmd*
{
	mut tok := 0
	mut *q, *eq := byte(0)

	for peek(ps, es, '<>') {
		tok = get_token(ps, es, 0, 0)

		if get_token(ps, es, &q, &eq) != 'a' {
			kpanic('missing file or redirection')
		}

		match tok {
			'<' {
				cmd = redir_cmd(cmd, q, eq, mem.O_RDONLY)
			}

			'>' {
				cmd = redir_cmd(cmd, q, eq, mem.O_WRONLY | O_CREATE, 1)
			}

			'+' { /* >> */
				cmd = redir_cmd(cmd, q, eq, mem.O_WRONLY | mem.O_CREATE, 1)
			}
		}
	}

	return cmd
}

pub fn parse_block(**ps, *es byte) Cmd*
{
	mut *cmd := Cmd{}

	if !peek(ps, es, '(') {
		kpanic('parse_block')
	}

	get_token(ps, es, 0, 0)
	cmd = parse_line(ps, es)

	if !peek(ps, es, ')') {
		kpanic('syntax - missing )')
	}

	get_token(ps, es, 0, 0)
	cmd = parse_redirs(cmd, ps, es)

	return cmd
}

pub fn parse_exec(**ps, *es byte) Cmd*
{
	mut *q, *eq := byte(0)
	mut tok, argc := 0
	mut *cmd := ExecCmd{}
	mut *ret := Cmd{}

	if peek(ps, es, '(') {
		return parse_block(ps, es)
	}

	ret = exec_cmd()
	cmd = ExecCmd(ret)
	argc = 0
	ret = parse_redirs(ret, ps, es)

	for !peek(ps, es, '|}&;') {
		if (tok = get_token(ps, es, &q, &eq)) == 0 {
			break
		}

		if tok != 'a' {
			kpanic('too many args')
		}

		ret = parse_redirs(ret, ps, es)
	}

	cmd.argv[argc] = 0
	cmd.eargv[argc] = 0

	return ret
}

/* NUL-terminate all the counted strings */
pub fn nul_terminate(*cmd Cmd) Cmd*
{
	mut i := 0
	mut *bcmd := BackCmd{}
	mut *ecmd := ExecCmd{}
	mut *lcmd := ListCmd{}
	mut *pcmd := Pipe{}
	mut *rcmd := RedirCmd{}

	if cmd == 0 {
		return 0
	}

	match cmd.type {
		EXEC {
			ecmd = *ExecCmd(cmd)

			for i = 0; ecmd.argv[i]; i++ {
				*ecmd.eargv[i] = 0
			}
		}

		REDIR {
			rcmd = *RedirCmd(cmd)
			nul_temninate(rcmd.cmd)
			*rcmd.efile = 0
		}

		PIPE {
			pcmd = *PipeCmd(cmd)
			nul_temninate(pcmd.left)
			nul_temninate(pcmd.right)
		}

		LIST {
			lcmd = *ListCmd(cmd)
			nul_temninate(pcmd.left)
			nul_temninate(pcmd.right)
		}

		BACK {
			bcmd = *BackCmd(cmd)
			nul_temninate(bcmd.cmd)
		}
	}

	return cmd
}
