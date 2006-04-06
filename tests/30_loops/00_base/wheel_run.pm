#!/usr/bin/perl -w
# $Id$

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);
use Socket;

use Test::More;

# Skip these tests if fork() is unavailable.
# We can't test_setup(0, "reason") because that calls exit().  And Tk
# will croak if you call BEGIN { exit() }.  And that croak will cause
# this test to FAIL instead of skip.
BEGIN {
  my $error;
  if ($^O eq "MacOS") {
    $error = "$^O does not support fork";
  }

  if ($^O eq "MSWin32" and exists $INC{"Event.pm"}) {
    $error = "$^O\'s fork() emulation breaks Event";
  }

  if ($error) {
    plan skip_all => $error;
    CORE::exit();
  }
}

plan tests => 9;

# Turn on extra debugging output within this test program.
sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw(Wheel::Run Filter::Line);

### Test Wheel::Run with filehandles.  Uses "!" as a newline to avoid
### having to deal with whatever the system uses.  Use double quotes
### if we're running on Windows.  Wraps the input in an outer loop
### because Win32's non-blocking flag bleeds across "forks".

my $pty_flush_count = 0;

my $os_quote = ($^O eq 'MSWin32') ? q(") : q(');
my $program = (
  "$^X -we $os_quote" .
  '$/ = q(!); select STDERR; $| = 1; select STDOUT; $| = 1; ' .
  'my $out = shift; '.
  'my $err = shift; '.
  'OUTER: while (1) { ' .
  '  while (<STDIN>) { ' .
  '    last OUTER if /^bye/; ' .
  '    print(STDOUT qq($out: $_)) if s/^out //; ' .
  '    print(STDERR qq($err: $_)) if s/^err //; ' .
  '  } ' .
  '} ' .
  "exit 0; $os_quote"
);

{ POE::Session->create(
    inline_states => {
      _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Run a child process.
        $heap->{wheel} = POE::Wheel::Run->new(
          Program      => $program,
          ProgramArgs  => [ "out", "err" ],
          StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
          StderrFilter => POE::Filter::Line->new( Literal => "!" ),
          StdoutEvent  => 'stdout_nonexistent',
          StderrEvent  => 'stderr_nonexistent',
          ErrorEvent   => 'error_nonexistent',
          StdinEvent   => 'stdin_nonexistent',
        );

        # Test event changing.
        $heap->{wheel}->event(
          StdoutEvent => 'stdout',
          StderrEvent => 'stderr',
          StdinEvent  => 'stdin',
        );
        $heap->{wheel}->event(
          ErrorEvent  => 'error',
          CloseEvent  => 'close',
        );

        # Ask the child for something on stdout.
        $heap->{wheel}->put( 'out test-out' );

        $kernel->delay(close => 10);
      },

      # Error! Ow!
      error => sub {
        DEBUG and warn "$_[ARG0] error $_[ARG1]: $_[ARG2]";
      },

      # The child has closed.  Delete its wheel.
      close => sub {
        DEBUG and warn "close";
        delete $_[HEAP]->{wheel};
        $_[KERNEL]->delay(close => undef);
      },

      # Dummy _stop to prevent runtime errors.
      _stop => sub { },

      # Count every line that's flushed to the child.
      stdin  => sub {
        DEBUG and warn "flush";
        $pty_flush_count++;
      },

      # Got a stdout response.  Ask for something on stderr.
      stdout => sub {
        ok(
          $_[ARG0] eq 'out: test-out',
          "subprogram got stdout response: $_[ARG0]"
        );
        DEBUG and warn $_[ARG0];
        $_[HEAP]->{wheel}->put( 'err test-err' );
      },

      # Got a stderr response.  Tell the child to exit.
      stderr => sub {
        ok(
          $_[ARG0] eq 'err: test-err',
          "subprogram got stderr response: $_[ARG0]"
        );
        DEBUG and warn $_[ARG0];
        $_[HEAP]->{wheel}->put( 'bye' );
        $_[KERNEL]->delay(close => undef);
      },
    },
  );

}

### Test Wheel::Run with a coderef instead of a subprogram.  Uses "!"
### as a newline to avoid having to deal with whatever the system
### uses.  Wraps the input in an outer loop because Win32's
### non-blocking flag bleeds across "forks".

my $coderef_flush_count = 0;

SKIP: {
#  skip "Wheel::Run + Tk + ActiveState Perl + CODE Program = pain", 2
#    if $^O eq "MSWin32" and exists $INC{"Tk.pm"};

  my $program = sub {
    $! = 1;
    my ($out, $err) = @_;
    local $/ = q(!);
    OUTER: while (1) {
      while (<STDIN>) {
        last OUTER if /^bye/;
        print(STDOUT qq($out: $_)) if s/^out //;
        print(STDERR qq($err: $_)) if s/^err //;
      }
    }
  };

  POE::Session->create(
    inline_states => {
      _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Run a child process.
        $heap->{wheel} = POE::Wheel::Run->new(
          Program      => $program,
          ProgramArgs  => [ "out", "err" ],
          StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
          StderrFilter => POE::Filter::Line->new( Literal => "!" ),
          StdoutEvent  => 'stdout_nonexistent',
          StderrEvent  => 'stderr_nonexistent',
          ErrorEvent   => 'error_nonexistent',
          StdinEvent   => 'stdin_nonexistent',
        );

        # Test event changing.
        $heap->{wheel}->event(
          StdoutEvent => 'stdout',
          StderrEvent => 'stderr',
          StdinEvent  => 'stdin',
        );
        $heap->{wheel}->event(
          ErrorEvent  => 'error',
          CloseEvent  => 'close',
        );

        # Ask the child for something on stdout.
        DEBUG and warn "put";
        $heap->{wheel}->put( 'out test-out' );

        # Timeout.
        $kernel->delay(close => 10);
      },

      # Error! Ow!
      error => sub {
        DEBUG and warn "$_[ARG0] error $_[ARG1]: $_[ARG2]";
      },

      # The child has closed.  Delete its wheel.
      close => sub {
        DEBUG and warn "close";
        delete $_[HEAP]->{wheel};
        $_[KERNEL]->delay(close => undef);
      },

      # Dummy _stop to prevent runtime errors.
      _stop => sub { },

      # Count every line that's flushed to the child.
      stdin  => sub {
        DEBUG and warn "flush";
        $coderef_flush_count++;
      },

      # Got a stdout response.  Ask for something on stderr.
      stdout => sub {
        ok(
          $_[ARG0] eq 'out: test-out',
          "coderef got stdout response: $_[ARG0]"
        );
        DEBUG and warn $_[ARG0];
        $_[HEAP]->{wheel}->put( 'err test-err' );
      },

      # Got a stderr response.  Tell the child to exit.
      stderr => sub {
        ok(
          $_[ARG0] eq 'err: test-err',
          "coderef got stderr response: $_[ARG0]"
        );
        DEBUG and warn $_[ARG0];
        $_[HEAP]->{wheel}->put( 'bye' );
        $_[KERNEL]->delay(close => undef);
      },
    },
  );

}

### Test Wheel::Run with ptys.  Uses "!" as a newline to avoid having
### to deal with whatever the system uses.

my $pty_flush_count = 0;

SKIP: {
  skip "IO::Pty is needed for this test.", 2
    unless POE::Wheel::Run::PTY_AVAILABLE;

  skip "The underlying event loop has trouble with ptys on $^O", 2
    if $^O eq "darwin" and (
      exists $INC{"POE/Loop/IO_Poll.pm"} or
      exists $INC{"POE/Loop/Event.pm"}
    );

  POE::Session->create(
    inline_states => {
      _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Handle SIGCHLD.
        $kernel->sig(CHLD => "sigchild");

        # Run a child process.
        $heap->{wheel} = POE::Wheel::Run->new(
          Program      => $program,
          ProgramArgs  => [ "out", "err" ],
          StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
          StdoutEvent  => 'stdout_nonexistent',
          ErrorEvent   => 'error_nonexistent',
          StdinEvent   => 'stdin_nonexistent',
          Conduit      => 'pty',
        );

        # Test event changing.
        $heap->{wheel}->event(
          StdoutEvent => 'stdout',
          ErrorEvent  => 'error',
          StdinEvent  => 'stdin',
        );

        # Ask the child for something on stdout.
        $heap->{wheel}->put( 'out test-out' );
        $kernel->delay(bye => 10);

        DEBUG and warn "_start";
      },

      # Timed out.

      bye => sub {
        DEBUG and warn "bye";
        delete $_[HEAP]->{wheel};
        $_[KERNEL]->delay(bye => undef);
      },

      # Error!  Ow!
      error => sub {
        DEBUG and warn "$_[ARG0] error $_[ARG1]: $_[ARG2]";
      },

      # Catch SIGCHLD.  Stop the wheel if the exited child is ours.
      sigchild => sub {
        my $signame = $_[ARG0];

        DEBUG and
          warn "session ", $_[SESSION]->ID, " caught signal $signame\n";

        my ($heap, $child_pid) = @_[HEAP, ARG1];

        DEBUG and warn "\tthe child process ID is $child_pid\n";

        return unless $heap->{wheel};

        if ($child_pid == $heap->{wheel}->PID()) {
          DEBUG and warn "\tthe child process is ours\n";
          $_[KERNEL]->yield("bye");
        }
        return 0;
      },

      # Dummy _stop to prevent runtime errors.
      _stop => sub { },

      # Count every line that's flushed to the child.
      stdin  => sub {
        DEBUG and warn "stdin";
        $pty_flush_count++;
      },

      # Got a stdout response.  Do a little expect/send dance.
      stdout => sub {
        my ($heap, $input) = @_[HEAP, ARG0];
        DEBUG and warn "got child input: $input";
        if ($input eq 'out: test-out') {
          pass("pty got stdout response: $_[ARG0]");
          $heap->{wheel}->put( 'err test-err' );
        }
        elsif ($input eq 'err: test-err') {
          pass("pty got stderr response: $_[ARG0]");
          $heap->{wheel}->put( 'bye' );
        }
      },
    },
  );

}

### Run the main loop.

POE::Kernel->run();

### Post-run tests.


SKIP: {
  skip "ptys not available", 3 unless POE::Wheel::Run::PTY_AVAILABLE;
  skip "The underlying event loop has trouble with ptys on $^O", 3
    if $^O eq "darwin" and (
      exists $INC{"POE/Loop/IO_Poll.pm"} or
      exists $INC{"POE/Loop/Event.pm"}
    );
  ok($pty_flush_count == 3, "pty flushed $pty_flush_count times");
  ok($pty_flush_count == 3, "pty flushed $pty_flush_count times");
  ok($coderef_flush_count == 3, "coderef flushed $coderef_flush_count times");
}

1;
