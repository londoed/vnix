module shell

import asm
import dev
import fs
import io
import lock
import mem
import proc
import sys

/* init: The initial user-level program */

global (
	*argv = []byte('sh', 0)
)

pub fn main() void
{
	mut pid, wpid := 0

	if fs.open('console', mem.O_RDWR) < 0 {
		sys.mknod('console', 1, 1)
		fs.open('console', mem.O_RDWR)
	}

	sys.dup(0) /* stdout */
	sys.dup(0) /* stderr */

	for {
		println(1, 'ninit: starting sh')
		mut pid := sys.fork()

		if pid < 0 {
			println(1, 'init: fork failed')
			proc.exit()
		}

		if pid == 0 {
			sys.exec('sh', argv)
			println(1, 'init: exec sh failed')
			proc.exit()
		}

		for (wpid = sys.wait()) >= 0 && wpid != pid {
			println(1, 'zombie!')
		}
	}
}
