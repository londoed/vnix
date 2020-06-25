module mem

import asm
import dev
import fs
import lock
import proc
import sys

pub struct Buf {
	flags int
	dev byte
	block_no byte
	lock Sleeplock{}
	ref_cnt byte
	*prev Buf{} // LRU cache list
	*next Buf{}
	*q_next Buf{} // disk queue
	data [B_SIZE]byte{}
}

pub const (
	B_VALID = 0x2, // buffer has been read from disk
	B_DIRTY = 0x4, // buffer needs to be written to disk
)
