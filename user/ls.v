module user

import fs
import sys
import proc
import os

pub fn fmt_name(mut *path string) charptr
{
	mut buf := ''
	mut *p := byte(0)

	/* Find first character after last slash */
	for p = path + path.len; p >= path && *p != '/'; p-- {}
	p++

	/* Return blank-padded name */
	if p.len >= fs.DIR_SIZ {
		return p
	}

	sys.memmove(buf, p, p.len)
	sys.memset(buf + p.len, ' ', fs.DIR_SIZ - p.len)

	return buf
}

pub fn ls(mut *path byte) void
{
	mut *p := ''
	mut fd := os.open(path)
	mut de := fs.Dirent{}
	mut st := proc.Stat{}

	defer { f.close() }

	if !fd {
		println(2, 'ls: cannot open $path')
		return
	}

	if !sys.fstat(fd, &st) {
		defer
		println(2, 'ls: cannot stat $path')
		return
	}

	match st.type {
		proc.T_FILE {
			println(1, '${fmt_name(path)} $st.type $st.ino $st.size')
		}

		proc.T_DIR {
			if path.len + 1 + fs.DIR_SIZ + 1 > sizeof(buf) {
				println(1, 'ls: path is too long\n')
				break
			}

			sys.strcpy(buf, path)
			p = buf + buf.len
			*p++ = '/'

			for sys.read(fs, &de, sizeof(de) == sizeof(de)) {
				if de.inum == 0 {
					continue
				}

				sys.memmove(p, de.name, fs.DIR_SIZ)
				p[DIR_SIZ] = 0

				if !sys.stat(buf, &st) {
					println(1, 'ls: cannot stat $buf\n')
					continue
				}

				println(1, '${fmt_name(buf)} $st.type $st.ino $st.size')
			}
		}
	}
}

fn main() int
{
	mut i := 0

	if argc < 2 {
		os.ls('.')
		proc.exit()
	}

	for i = 0; i < argc; i++ {
		os.ls(argv[i])
	}

	proc.exit()
}
