#!/usr/bin/perl
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;
use warnings;

use POE qw(Wheel::FollowTail);
use POSIX qw(mkfifo);
use Test::More;


if ($^O eq 'MSWin32') {
  plan skip_all => 'Windows does not support mkfifo';
} else {
  plan tests => 3;
}


my $PIPENAME = 'testpipe';
my @EXPECTED = qw(foo bar);

POE::Session->create(
  inline_states => {
    _start      => \&_start_handler,
    done        => \&done,
    input_event => \&input_handler,
  }
);

POE::Kernel->run();
exit;

#------------------------------------------------------------------------------

sub _start_handler {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  mkfifo($PIPENAME, 0600) unless -p $PIPENAME;

  $heap->{wheel} = POE::Wheel::FollowTail->new(
    InputEvent => 'input_event',
    Filename   => $PIPENAME,
  );

  open my $fh, '>', $PIPENAME or die "open failed: $!";
  $fh->autoflush(1);

  print $fh "foo\nbar\n";

  # rt.cpan.org 96039: Save the filehandle so it remains open.
  $heap->{write_fh} = $fh;

  $kernel->delay('done', 3);
  return;
}


sub input_handler {
  my ($kernel, $line) = @_[KERNEL, ARG0];
  my $next = shift @EXPECTED;
  is($line, $next);
  $kernel->delay('done', 1);
  return;
}


sub done {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Cleanup the test pipe file.
  # Must be closed for the unlink() to work on Windows.
  my $write_fh = delete $heap->{write_fh};
  close $write_fh or die "close failed: $!";
  unlink $PIPENAME or die "unlink failed: $!";

  # delete the wheel so the POE session can end
  delete $heap->{wheel};

  # @expected should be empty
  is_deeply(\@EXPECTED, []);

  return;
}


1;
