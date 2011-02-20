#!/usr/bin/perl -w

use strict;

#use lib qw(/opt/local/lib/perl5/site_perl/5.12.2/POE/Test/Loops);
use Test::More tests => 4;
use POSIX qw(_exit);
use Term::Size;
use POE qw/Wheel::Run Filter::Line  Filter::Stream Wheel::ReadWrite /;

sub skip_tests {
  return "IO::Poll is not 100% compatible with $^O" if (
    $^O eq "MSWin32" and not $ENV{POE_DANTIC}
  );
  return "IO::Poll tests require the IO::Poll module" if (
    do { eval "use IO::Poll"; $@ }
  );
}


BEGIN {
  if (my $why = skip_tests('wheel_run')) {
    plan skip_all => $why
  }
}

my $winsize = [85, 29, 100, 200];

### Handle the _start event.  This sets things in motion.
sub handle_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Set a signal handler.
  $kernel->sig(CHLD => "got_sigchld");

  # Start the terminal reader/writer.
  $heap->{stdio} = POE::Wheel::ReadWrite->new(
    InputHandle  => \*STDIN,
    OutputHandle => \*STDOUT,
    InputEvent   => "got_terminal_stdin",
    Filter       => POE::Filter::Line->new(),
  );

  # Start the asynchronous child process.
  $heap->{program} = POE::Wheel::Run->new(
    Program     => 't/30_loops/io_poll/termsize.pl',
    Conduit     => "pty",
    Winsize     => $winsize,
    StdoutEvent => "got_child_stdout",
    StdioFilter => POE::Filter::Line->new(),
  );

}

sub handle_terminal_stdin {
  my ($heap, $input) = @_[HEAP, ARG0];
  $heap->{program}->put($input);
}


sub handle_child_stdout {
  my ($heap, $input) = @_[HEAP, ARG0];
  if ($input =~ m/^rows: (\d+), cols: (\d+), xpix: (\d+), ypix: (\d+)$/) {
      is ($winsize->[0], $1, 'rows set correctly');
      is ($winsize->[1], $2, 'cols set correctly');
      is ($winsize->[2], $3, 'xpix set correctly');
      is ($winsize->[3], $4, 'ypix set correctly');
  }
  #diag( "OUTPUT: " . $input . "\n");
}

sub handle_sigchld {
  my ($heap, $child_pid) = @_[HEAP, ARG1];
  if ($child_pid == $heap->{program}->PID) {
    delete $heap->{program};
    delete $heap->{stdio};
  }
  return 0;
}

### Start a session to encapsulate the previous features.
POE::Session->create(
  inline_states => {
    _start             => \&handle_start,
    got_terminal_stdin => \&handle_terminal_stdin,
    got_child_stdout   => \&handle_child_stdout,
    got_sigchld        => \&handle_sigchld,
  },
);

$poe_kernel->run();

