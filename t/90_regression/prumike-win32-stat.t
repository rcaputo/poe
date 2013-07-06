#!/usr/bin/env perl

# stat() on Windows reports different device IDs for a file depending
# whether it was stat()ed via name or opened handle.  If used
# inconsistently, stat() will always report differences.  Discovered by
# "pru-mike" at blogs.perl.org/users/pru-mike/2013/06/creepy-perl-stat-functions-on-windows.html

use strict;
use warnings;
use POE qw/Wheel::FollowTail/;
use Time::HiRes qw(time);
use Test::More;
$| = 1;

BEGIN {
  if ($^O ne "MSWin32") {
    plan skip_all => "This test examines Strawberry/ActiveState Perl behavior.";
  }

  eval 'use Win32::Console';
  if ($@) {
    plan skip_all => "Win32::Console is required on $^O - try ActivePerl";
  }
}

plan tests => 1;

my $filename = 'poe-stat-test.tmp';
die "File $filename exists!\n" if -f $filename;

POE::Session->create(
  inline_states => {
    _start => \&start,
    got_line => sub { $_[HEAP]->{lines}++ },
    got_error => sub { warn "$_[ARG0]\n" },
	tick => \&check_file,
  },
);

$poe_kernel->run();
unlink $filename or die "$!";
exit(0);

sub start {
	$_[HEAP]->{wheel} = POE::Wheel::FollowTail->new(
        Filename   => $filename,
        InputEvent => 'got_line',
        ErrorEvent => 'got_error',
        SeekBack   => 0,
		PollInterval => 1,
	);
    $_[KERNEL]->delay(tick => 1);
}

sub check_file {
	if ( ! $_[HEAP]->{lines} ){
		#recreate test file
		open my $fh, '>', $filename or die "$!";
		print $fh "There is more than one way to skin a cat.\n";
		close $fh;
	}else {
		ok($_[HEAP]->{lines} == 1,"Check number of lines" ) or diag ("Oops! Got $_[HEAP]->{lines} lines, possibly we have infinity loop\n");
		$poe_kernel->stop();
	}
	$_[KERNEL]->delay(tick => 1);
}

