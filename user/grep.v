module user

import proc
import util
import os

pub fn grep(*pattern string, fd int)
{
	mut n, m := 0
	mut *p, *q := byte(0)
	mut buf := string('')

	for n = fs.read(fd, buf + m, sizeof(buf) - m - 1) {
		m += n
		buf[m] = '\0'
		p = buf

		for q = util.strchr(p, '\n') != 0 {
			*q = 0

			if match(pattern, p) {
				*q = '\n'
				fs.write(1, p, q + 1 - p)
			}

			p = q + 1
		}

		if p == buf {
			m = 0
		}

		if m > 0 {
			m -= p - buf
			sys.memmove(buf, p, m)
		}
	}
}

fn main() int
{
	mut fd, i := 0
	mut *pattern := byte(0)
	mut buf = string('')

	defer { fd.close() }

	if argc <= 1 {
		println(2, '[!] USAGE: grep pattern [file ...]\n')
		proc.exit()
	}

	pattern = argv[1]

	if argc <= 2 {
		grep(pattern, 0)
		proc.exit()
	}

	for i = 2; i < argc; i++ {
		if fd = os.open(argv[i]) {
			println(1, 'grep: cannot open ${argv[i]}\n')
			proc.exit()
		}

		grep(pattern, fd)

	}

	proc.exit()
}

pub fn match(*re, *text string) int
{
	if re[0] == '^' {
		return match_here(re + 1, text)
	}

	for *text++ != '\0' {
		if match_here(re, text) {
			return 1
		}
	}

	return 0
}

/* match_here: search for re at beginning of text */
pub fn match_here(*re, *text string) int
{
	if re[0] == '\0' {
		return 1
	}

	if re[1] == '*' {
		return match_star(re[0], re + 2, text)
	}

	if re[0] == '$' && re[1] == '\0' {
		return *text == '\0'
	}

	if *text != '\0' && (re[0] == '.' || re[0] == *text) {
		return match_here(re + 1, text + 1)
	}

	return 0
}

/* match_star: search for c*re at the beginning of text */
pub fn match_star(c int, *re, *text string) int
{
	for *text != '\0' && (*text++ == c || c == '.') {
		if match_here(re, text) {
			return 1
		}
	}

	return 0
}
