module mem

import asm
import dev
import fs
import lock
import proc
import sys

pub const (
	O_RDONLY = 0x000,
	O_WRONLY = 0x001,
	O_RDWR = 0x002,
	O_CREATE = 0x200,
)
