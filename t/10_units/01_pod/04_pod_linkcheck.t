#!/usr/bin/perl
use strict; use warnings;
use Test::More;

eval "use Test::Pod::LinkCheck";
if ( $@ ) {
	plan skip_all => 'Test::Pod::LinkCheck required for testing POD';
} else {
	Test::Pod::LinkCheck->new->all_pod_ok();
}
