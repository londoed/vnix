module stat

pub const (
	T_DIR = 1, // Directory
	T_FILE = 2, // File
	T_DEV = 3 // Device
)

pub struct Stat {
	type i8 // Type of file
	dev int // File system's disk device
	ino byte // Inode number
	n_link i8 // Number of links to file
	size byte // Size of file in bytes
}
