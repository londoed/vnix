module sys

import proc
import fs
import dev
import asm
import io
import mem
import shell
import user
import util
import os

pub const (
	N = 1000
)

pub fn printk(mut fd int, *s byte, ...) void
{
	os.write(fd, s, s.len)
}

pub fn forktest() void
{
	mut n, pid := 0

	printk(1, 'fork test\n')

	for n = 0; n < N; n++ {
		pid = fork()

		if pid < 0 {
			break
		}

		if pid == 0 {
			proc.exit()
		}
	}

	if n == N {
		printk(1, 'fork clained to work N times!\n')
		proc.exit()
	}

	for ; n > 0; n-- {
		if proc.wait() < 0 {
			printk(1, 'wait got too many\n')
			proc.exit()
		}
	}

	if proc.wait() != -1 {
		printk(1, 'wait got too many\n')
		proc.exit()
	}

	printk(1, 'fork test OK\n')
}

fn main() int
{
	forktest()
	proc.exit()
}
