#!/usr/bin/perl

use warnings;
use strict;

while (<STDIN>) {
	if ($] < 5.006) {
		s/^(\s*)(use bytes;).*/$1#$2 # perl version $] at install/;
	}
	else {
		s/^(\s*)#\s*(use bytes;).*/$1$2/;
	}
	print;
}
