#!/usr/bin/perl -w
# $Id: /branches/poe-tests/tests/30_loops/00_base/wheel_tail.pm 10644 2006-05-29T17:02:47.597324Z bsmith  $

# Exercises Wheel::Curses

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
#sub POE::Kernel::TRACE_DEFAULT  () { 1 }
#sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;
use Symbol qw(gensym);

BEGIN {
  if ($^O eq "MSWin32") {
    plan skip_all => "Can't multiplex consoles in $^O";
  }

  eval "use IO::Pty";
  plan skip_all => 'IO::Pty not available' if $@;

  eval { require Curses };
  plan skip_all => 'Curses not available' if $@;
}

my ($saved_stdin, $saved_stdout, $pty_master, $pty_slave);
BEGIN {
  # Redirect STDIN and STDOUT to temporary handles for the duration of
  # this test.

  $saved_stdin = gensym();
  open($saved_stdin, "<&STDIN") or die "can't save stdin: $!";
  $saved_stdout = gensym();
  open($saved_stdout, ">&STDOUT") or die "can't save stdout: $!";

  # Create a couple one-way pipes for our new stdin and stdout.

  $pty_master = IO::Pty->new() or die "pty: $!";
  select $pty_master; $| = 1;

  $pty_slave = $pty_master->slave();
  select $pty_slave; $| = 1;

  # Redirect our STDIN and STDOUT to the pipes.

  open(STDIN, "<&=" . fileno($pty_slave)) or die "stdin pipe redir: $!";
  open(STDOUT, ">&=" . fileno($pty_slave)) or die "stdout pipe redir: $!";
  select STDOUT; $| = 1;
}

BEGIN {
  plan skip_all => "Need help with Curses functions blocking under ptys";
  plan tests => 5;
  use_ok('POE');
  use_ok('POE::Wheel::Curses');
  use_ok('POE::Filter::Stream');
  use_ok('POE::Wheel::ReadWrite');
}

# Restore the original stdio at the end of the run.

END {
  if ($saved_stdin) {
    open(STDIN, "<&=" . fileno($saved_stdin)) or die "stdin restore: $!";
    $saved_stdin = undef;
  }

  if ($saved_stdout) {
    open(STDOUT, ">&=" . fileno($saved_stdout)) or die "stdout restore: $!";
    $saved_stdout = undef;
  }
}

### Session to drive the tests.

POE::Session->create(
  inline_states => {
    _start                => \&test_start,
    got_keystroke         => \&test_keystroke,
    got_readwrite_input   => sub { },
    _stop                 => sub { },
  },
);

### main loop

POE::Kernel->run();

### Event handlers from here on.

sub test_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{child_input} = "";

  $heap->{curses} = POE::Wheel::Curses->new(
    InputEvent => "got_keystroke"
  );

  $heap->{readwrite} = POE::Wheel::ReadWrite->new(
    Handle => $pty_master,
    Filter => POE::Filter::Stream->new(),
    InputEvent => "got_readwrite_input",
  );

  $heap->{readwrite}->put("this is a test!");
}

sub test_keystroke {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  $heap->{child_input} .= $input;
  if ($heap->{child_input} =~ /!/) {
    delete $heap->{curses}; }
    delete $heap->{readwrite};
    ok( $heap->{child_input} eq "this is a test!", "got keystrokes" );
  }
}

1;
