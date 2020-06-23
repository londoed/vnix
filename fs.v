module fs

pub const (
	ROOTING = 1, // root i-number
	B_SIZE = 512 // block size
)

/*
Disk layout:
[ boot block | super block | log | inode blocks |
                                       free bit map | data blocks]

mkfs computes the super block and builds an initial file system. The
super block describes the disk layout:
*/

pub struct SuperBlock {
	size byte // Size of file system images (blocks)
	n_blocks byte // Number of data blocks
	n_inodes byte // Number of inodes
	n_log byte // Number of log blocks
	log_start byte // Block number of first log block
	inode_start byte // Block number of first inode block
	bmap_start byte // Block number of first free map block
}

pub const (
	N_DIRECT = 12,
	N_INDIRECT = B_SIZE / sizeof(byte),
	MAX_FILE = N_DIRECT + N_INDIRECT,
)

// On-disk inode structure
pub struct DInode {
	ftype i16 // File type
	major i16 // Major device number (T_DEV only)
	minor i16 // Minor device numbre (T_DEV only)
	n_link i16 // Number of links to inode in file system
	size byte // Size of file (bytes)
	addrs [N_DIRECT + 1]byte{} // Data block addresses
}

// Inodes per block
pub const IPB = B_SIZE / sizeof(DInode)

// Block containing inode i
pub const I_BLOCK = fn(i, sb) { i / IPB + sb.inode_start }

// Bitmap bites per block
pub const BPB = B_SIZE * 8

// Block of free map containing bit for block b
pub const B_BLOCK = fn(b, sb) { b / BPB + sb.bmap_start }

// Directory is a file containing a sequence of dirent structures.
pub const DIR_SIZ = 14

pub struct Dirent {
	inum u16
	name [DIR_SIZ]byte{}
}
