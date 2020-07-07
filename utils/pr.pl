#!/usr/bin/perl

use strict;
use warnings;

use POSIX qw<strftime>;

if (@ARGV[0] eq '-h') {
    shift @ARGV;
    my $h = $ARGV[0];
    shift @ARGV;
} else {
    my $h = $ARGV[0];
}

my $page = 0;
my $now = strftime "%b %e %H:%M:%S", localtime;

my @lines = <>;

for (my $i = 0; $i < scalar @lines; $i += 50) {
    print "\n\n";
    ++$page;

    print "$now  $h  Page $page\n";
    print "\n\n";

    for (my $j = $i; $j < scalar @lines && $j < $i + 50; $j++) {
        $lines[$j] =~ s!//DOC.*!!;
        print $lines[$j];
    }

    for (; $j < $i + 50; $j++) {
        print "\n";
    }

    my $sheet = "";

    if ($lines[$i] =~ /^([0-9][0-9])[0-9][0-9]/) {
        $sheet = "Sheet $1";
    }

    print "\n\n";
    print "$sheet\n";
    print "\n\n";
}
