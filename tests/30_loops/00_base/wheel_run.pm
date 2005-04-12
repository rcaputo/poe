#!/usr/bin/perl -w
# $Id$

# Test the portable pipe classes and Wheel::Run, which uses them.

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);
use Socket;

use TestSetup;

# Skip these tests if fork() is unavailable.
# We can't test_setup(0, "reason") because that calls exit().  And Tk
# will croak if you call BEGIN { exit() }.  And that croak will cause
# this test to FAIL instead of skip.
BEGIN {
  my $error;
  if ($^O eq "MacOS") {
    $error = "$^O does not support fork";
  }

  if ($error) {
    print "1..0 # Skip $error\n";
    CORE::exit();
  }
}

test_setup(24);

# Turn on extra debugging output within this test program.
sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE qw(Wheel::Run Filter::Line Pipe::TwoWay Pipe::OneWay);

### Test one-way pipe() pipe.
{ my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('pipe');

  if (defined $uni_read and defined $uni_write) {
    &ok(1);

    print $uni_write "whee pipe\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 2, $uni_input eq 'whee pipe' );
  }
  else {
    &many_ok(1, 2, "skipped: $^O does not support pipe().");
  }
}

### Test one-way socketpair() pipe.
{ my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('socketpair');

  if (defined $uni_read and defined $uni_write) {
    &ok(3);

    print $uni_write "whee socketpair\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 4, $uni_input eq 'whee socketpair' );
  }
  else {
    &many_ok(3, 4, "skipped: $^O does not support socketpair().");
  }
}

### Test one-way pair of inet sockets.
{ my ($uni_read, $uni_write) = POE::Pipe::OneWay->new('inet');

  if (defined $uni_read and defined $uni_write) {
    &ok(5);

    print $uni_write "whee inet\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 6, $uni_input eq 'whee inet' );
  }
  else {
    &many_ok(5, 6, "skipped: $^O does not support inet sockets.");
  }
}

### Test two-way pipe.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::TwoWay->new('pipe');

  if (defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr) {
    &ok(7);

    print $a_wr "a wr inet\n";
    my $b_input = <$b_rd>; chomp $b_input;
    &ok_if(8, $b_input eq 'a wr inet');

    print $b_wr "b wr inet\n";
    my $a_input = <$a_rd>; chomp $a_input;
    &ok_if(9, $a_input eq 'b wr inet');
  }
  else {
    &many_ok(7, 9, "skipped: $^O does not support pipe().");
  }
}

### Test two-way socketpair.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::TwoWay->new('socketpair');

  if (defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr) {
    &ok(10);

    print $a_wr "a wr inet\n";
    my $b_input = <$b_rd>; chomp $b_input;
    &ok_if(11, $b_input eq 'a wr inet');

    print $b_wr "b wr inet\n";
    my $a_input = <$a_rd>; chomp $a_input;
    &ok_if(12, $a_input eq 'b wr inet');
  }
  else {
    &many_ok(10, 12, "skipped: $^O does not support socketpair().");
  }
}

### Test two-way inet sockets.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::TwoWay->new('inet');

  if (defined $a_rd and defined $a_wr and defined $b_rd and defined $b_wr) {
    &ok(13);

    print $a_wr "a wr inet\n";
    my $b_input = <$b_rd>; chomp $b_input;
    &ok_if(14, $b_input eq 'a wr inet');

    print $b_wr "b wr inet\n";
    my $a_input = <$a_rd>; chomp $a_input;
    &ok_if(15, $a_input eq 'b wr inet');
  }
  else {
    &many_ok(13, 15, "skipped: $^O does not support inet sockets.");
  }
}

### Test Wheel::Run with filehandles.  Uses "!" as a newline to avoid
### having to deal with whatever the system uses.  Use double quotes
### if we're running on Windows.  Wraps the input in an outer loop
### because Win32's non-blocking flag bleeds across "forks".

my $tty_flush_count = 0;

my $os_quote = ($^O eq 'MSWin32') ? q(") : q(');

my $program =
  ( "$^X -we $os_quote" .
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

{ POE::Session->create
    ( inline_states =>
      { _start => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          # Run a child process.
          $heap->{wheel} = POE::Wheel::Run->new
            ( Program      => $program,
              ProgramArgs  => [ "out", "err" ],
              StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
              StderrFilter => POE::Filter::Line->new( Literal => "!" ),
              StdoutEvent  => 'stdout_nonexistent',
              StderrEvent  => 'stderr_nonexistent',
              ErrorEvent   => 'error_nonexistent',
              StdinEvent   => 'stdin_nonexistent',
            );

          # Test event changing.
          $heap->{wheel}->event( StdoutEvent => 'stdout',
                                 StderrEvent => 'stderr',
                                 StdinEvent  => 'stdin',
                               );
          $heap->{wheel}->event( ErrorEvent  => 'error',
                                 CloseEvent  => 'close',
                               );

          # Ask the child for something on stdout.
          $heap->{wheel}->put( 'out test-out' );
        },

        # Error! Ow!
        error => sub { },

        # The child has closed.  Delete its wheel.
        close => sub {
          delete $_[HEAP]->{wheel};
        },

        # Dummy _stop to prevent runtime errors.
        _stop => sub { },

        # Count every line that's flushed to the child.
        stdin  => sub { $tty_flush_count++; },

        # Got a stdout response.  Ask for something on stderr.
        stdout => sub { &ok_if(17, $_[ARG0] eq 'out: test-out');
                        DEBUG and warn $_[ARG0];
                        $_[HEAP]->{wheel}->put( 'err test-err' );
                      },

        # Got a sterr response.  Tell the child to exit.
        stderr => sub { &ok_if(18, $_[ARG0] eq 'err: test-err');
                        DEBUG and warn $_[ARG0];
                        $_[HEAP]->{wheel}->put( 'bye' );
                      },
      },
    );
}

### Test Wheel::Run with a coderef instead of a subprogram.  Uses "!"
### as a newline to avoid having to deal with whatever the system
### uses.  Wraps the input in an outer loop because Win32's
### non-blocking flag bleeds across "forks".

my $coderef_flush_count = 0;

{ my $program = sub {
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

  POE::Session->create
    ( inline_states =>
      { _start => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          # Run a child process.
          $heap->{wheel} = POE::Wheel::Run->new
            ( Program      => $program,
              ProgramArgs  => [ "out", "err" ],
              StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
              StderrFilter => POE::Filter::Line->new( Literal => "!" ),
              StdoutEvent  => 'stdout_nonexistent',
              StderrEvent  => 'stderr_nonexistent',
              ErrorEvent   => 'error_nonexistent',
              StdinEvent   => 'stdin_nonexistent',
            );

          # Test event changing.
          $heap->{wheel}->event( StdoutEvent => 'stdout',
                                 StderrEvent => 'stderr',
                                 StdinEvent  => 'stdin',
                               );
          $heap->{wheel}->event( ErrorEvent  => 'error',
                                 CloseEvent  => 'close',
                               );

          # Ask the child for something on stdout.
          $heap->{wheel}->put( 'out test-out' );
        },

        # Error! Ow!
        error => sub { },

        # The child has closed.  Delete its wheel.
        close => sub {
          delete $_[HEAP]->{wheel};
        },

        # Dummy _stop to prevent runtime errors.
        _stop => sub { },

        # Count every line that's flushed to the child.
        stdin  => sub { $coderef_flush_count++; },

        # Got a stdout response.  Ask for something on stderr.
        stdout => sub { &ok_if(23, $_[ARG0] eq 'out: test-out');
                        DEBUG and warn $_[ARG0];
                        $_[HEAP]->{wheel}->put( 'err test-err' );
                      },

        # Got a sterr response.  Tell the child to exit.
        stderr => sub { &ok_if(24, $_[ARG0] eq 'err: test-err');
                        DEBUG and warn $_[ARG0];
                        $_[HEAP]->{wheel}->put( 'bye' );
                      },
      },
    );
}

### Test Wheel::Run with ptys.  Uses "!" as a newline to avoid having
### to deal with whatever the system uses.

my $pty_flush_count = 0;

if (POE::Wheel::Run::PTY_AVAILABLE) {
  POE::Session->create
    ( inline_states =>
      { _start => sub {
          my ($kernel, $heap) = @_[KERNEL, HEAP];

          # Handle SIGCHLD.
          $kernel->sig(CHLD => "sigchild");

          # Run a child process.
          $heap->{wheel} = POE::Wheel::Run->new
            ( Program      => $program,
              ProgramArgs  => [ "out", "err" ],
              StdioFilter  => POE::Filter::Line->new( Literal => "!" ),
              StdoutEvent  => 'stdout_nonexistent',
              ErrorEvent   => 'error_nonexistent',
              StdinEvent   => 'stdin_nonexistent',
              Conduit      => 'pty',
            );

          # Test event changing.
          $heap->{wheel}->event( StdoutEvent => 'stdout',
                                 ErrorEvent  => 'error',
                                 StdinEvent  => 'stdin',
                               );

          # Ask the child for something on stdout.
          $heap->{wheel}->put( 'out test-out' );
        },

        # Error!  Ow!
        error => sub { },

        # Catch SIGCHLD.  Stop the wheel if the exited child is ours.
        sigchild => sub {
          my $signame = $_[ARG0];

          DEBUG and
            warn "session ", $_[SESSION]->ID, " caught signal $signame\n";

          my ($heap, $child_pid) = @_[HEAP, ARG1];

          DEBUG and warn "\tthe child process ID is $child_pid\n";

          if ($child_pid == $heap->{wheel}->PID()) {
            DEBUG and warn "\tthe child process is ours\n";
            delete $heap->{wheel};
          }
          return 0;
        },

        # Dummy _stop to prevent runtime errors.
        _stop => sub { },

        # Count every line that's flushed to the child.
        stdin  => sub { $pty_flush_count++; },

        # Got a stdout response.  Do a little expect/send dance.
        stdout => sub {
          my ($heap, $input) = @_[HEAP, ARG0];
          if ($input eq 'out: test-out') {
            &ok(20);
            $heap->{wheel}->put( 'err test-err' );
          }
          elsif ($input eq 'err: test-err') {
            &ok(21);
            $heap->{wheel}->put( 'bye' );
          }
        },
      },
    );
}
else {
  &many_ok( 19, 21, "skipped: IO::Pty is needed for this test.");
}

### Run the main loop.

$poe_kernel->run();

### Post-run tests.

&ok_if( 16, $tty_flush_count == 3 );
&ok_if( 19, $pty_flush_count == 3 ) if POE::Wheel::Run::PTY_AVAILABLE;
&ok_if( 22, $coderef_flush_count == 3 );

&results();

1;
