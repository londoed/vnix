module user

import proc

fn main(argc int, *argv string) int
{
	mut i := 0

	if argc < 2 {
		println(2, "[!] USAGE: rm files ...\n")
		proc.exit()
	}

	for i = 1; i < argc; i++ {
		if proc.unlink(argv[i]) < 0 {
			println(2, "$argv[i] failed to delete\n");
			break;
		}

		os.rm(argv[i])
	}

	proc.exit()
}
