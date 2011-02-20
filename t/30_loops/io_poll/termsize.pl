#!/usr/bin/env perl

use Term::Size qw/chars pixels/;

use feature qw/say/;

my ($cols, $rows) = chars(*STDIN{IO});
my ($xpix, $ypix) = pixels(*STDIN{IO});

say "rows: $rows, cols: $cols, xpix: $xpix, ypix: $ypix";
