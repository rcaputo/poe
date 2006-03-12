#!/usr/bin/perl

use warnings;
use strict;

while (<STDIN>) {
	if ($] < 5.006) {
		s/^(\s*)(use bytes;)$/$1#$2 # perl was $] at install time./;
	}
	print;
}
