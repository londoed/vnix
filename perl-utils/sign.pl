#!/usr/bin/perl

open(SIG, $ARGV[0]) or die "[!] ERROR: Can't open $ARGV[0]: $!";

my $n = sysread(SIG, my $buf, 1_000);

if ($n > 510) {
    print STDERR "[!] ERROR: Boot block too large -- $n bytes (max 510)\n";
    exit 1
}

print STDERR "[!] ERROR: Boot block is $n bytes. (max 510)\n";

$buf .= "\0" x (510 - $n);
$buf .= "\x55\xAA";

open(SIG, ">$ARGV[0]") or die "[!] ERROR: Failed to open $ARGV[0] -- $!\n";
print SIG $buf;
close SIG;
