module user

import os
import proc

fn main(argc int, *argv string) int
{
	mut i := 0

	if argc < 2 {
		println(2, '[!] USAGE: mkdir files ...\n')
		proc.exit()
	}

	for i = 1; i < argc; i++ {
		if !mkdir(argv[i]) {
			println(2, 'mkdir: ${argv[i]} failed to create\n')
			break
		}

		os.mkdir(argv[i])
	}
	proc.exit()
}
