#!/usr/bin/perl -w
# $Id: /branches/poe-tests/tests/30_loops/00_base/wheel_tail.pm 10644 2006-05-29T17:02:47.597324Z bsmith  $

# Exercises Wheel::ReadLine

use strict;
use warnings;
use lib qw(./mylib ../mylib);

sub DEBUG () { 0 }

### Tests to run.
#
# Each test consists of a "name" for test reporting, a series of steps
# that contain text to "type" in a particular order, and a "done" line
# that should contain the final input from Wheel::ReadLine.

my $enter = "\012";
my $bs    = "\010";

my @tests = (
  {
    name => "plain typing",
    step => [
      "this is a test$enter",
    ],
    done => "this is a test",
  },
  {
    name => "backspace",
    step => [
      "this is a test$bs$bs$bs${bs}TEST$enter",
    ],
    done => "this is a TEST",
  },
);

sub POE::Kernel::CATCH_EXCEPTIONS () { 0 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;

# There are some reasons not to run this test.

BEGIN {
  my $error;
  if ($^O eq "MSWin32") {
    $error = "$^O cannot multiplex terminals";
  }
  elsif (!-t STDIN) {
    $error = "not running in a terminal";
  }
  else {
    eval "use Term::ReadKey";
    if ($@) {
      $error = "This test requires Term::ReadKey" if $@;
    }
    else {
      eval "use IO::Pty";
      $error = "This test requires IO::Pty" if $@;
    }
  }

  if ($error) {
    plan skip_all => $error;
    CORE::exit();
  }
}

plan tests => scalar(@tests);

use Symbol qw(gensym);
use POSIX qw(
  sysconf setsid _SC_OPEN_MAX ECHO ICANON IEXTEN ISIG BRKINT ICRNL
  INPCK ISTRIP IXON CSIZE PARENB OPOST TCSANOW
);

# Redirection must be done before POE::Wheel::ReadLine is loaded,
# otherwise it grabs copies of STDIN and STDOUT.

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

  # Put the pty conduit (slave side) into "raw" or "cbreak" mode,
  # per APITUE 19.4 and 11.10.

  my $tio = POSIX::Termios->new();
  $tio->getattr(fileno($pty_slave));
  my $lflag = $tio->getlflag;
  $lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
  $tio->setlflag($lflag);
  my $iflag = $tio->getiflag;
  $iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  $tio->setiflag($iflag);
  my $cflag = $tio->getcflag;
  $cflag &= ~(CSIZE | PARENB);
  $tio->setcflag($cflag);
  my $oflag = $tio->getoflag;
  $oflag &= ~(OPOST);
  $tio->setoflag($oflag);
  $tio->setattr(fileno($pty_slave), TCSANOW);

  select $pty_slave; $| = 1;

  # Redirect our STDIN and STDOUT to the pipes.

  open(STDIN, "<&=" . fileno($pty_slave)) or die "stdin pipe redir: $!";
  open(STDOUT, ">&=" . fileno($pty_slave)) or die "stdout pipe redir: $!";
  select STDOUT; $| = 1;
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

use POE qw(Filter::Stream Wheel::ReadLine Wheel::ReadWrite);

### Session to run the tests.

POE::Session->create(
  inline_states => {
    _start                => \&test_start,
    got_readwrite_output  => \&test_readwrite_output,
    got_readline_input    => \&test_readline_input,
    start_next_test       => \&test_start_next,
    step_this_test        => \&test_step,
    _stop                 => sub { },
  },
);

### Main loop.

POE::Kernel->run();

### The rest of this code is event handlers.

sub test_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  # Create a Wheel::ReadWrite to work on the driving side of the
  # pipes.

  $heap->{readwrite} = POE::Wheel::ReadWrite->new(
    Handle => $pty_master,
    Filter => POE::Filter::Stream->new(),
    InputEvent => "got_readwrite_output",
  );

  # The ReadLine wheel to drive and test.

  $heap->{readline} = POE::Wheel::ReadLine->new(
    InputEvent => "got_readline_input",
    appname => "my_cli",
  );

  # And start testing.

  $kernel->yield("start_next_test");
}

sub test_readwrite_output {
  my ($heap, $input) = @_[HEAP, ARG0];
  if (DEBUG) {
    $input =~ s/[\x0A\x0D]+/{ENTER}/g;
    warn "$heap->{test}{name} - got output from child ($input)\n";
  }
}

sub test_readline_input {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $test = $heap->{test};
  my $name = $test->{name};

  DEBUG and warn "$name - got readline input ($input)\n";

  if (@{$test->{step}}) {
    fail("$name - got test input prematurely");
  }
  else {
    ok( $test->{done} eq $input, $name );
  }

  $kernel->yield("start_next_test");
}

sub test_start_next {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  if (@tests) {
    $heap->{test} = shift @tests;
    $kernel->yield("step_this_test");
    return;
  }

  DEBUG and warn "Done with all tests.\n";
  $heap->{readline} = undef;
  $heap->{readwrite} = undef;
}

sub test_step {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my $next_step = shift @{$heap->{test}{step}};
  unless ($next_step) {
    DEBUG and warn "$heap->{test}{name} - done with test\n";
    $kernel->yield("start_next_test");
    return;
  }

  if (DEBUG) {
    my $output_next_step = $next_step;
    $output_next_step =~ s/$bs/{BS}/g;
    $output_next_step =~ s/$enter/{ENTER}/g;
    warn "$heap->{test}{name} - typing ($output_next_step)\n";
  }

  $heap->{readline}->get("next step");
  $heap->{readwrite}->put($next_step);
}

1;
