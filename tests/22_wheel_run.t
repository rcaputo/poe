#!/usr/bin/perl -w
# $Id$

# Test the portable pipe classes and Wheel::Run, which uses them.

use strict;
use lib qw(./lib ../lib);
use Socket;

use TestSetup;
&test_setup(18);

# Turn on all asserts, and use POE and other modules.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Wheel::Run Filter::Line Pipe::Bidirectional Pipe::Unidirectional );

### Test unidirectional pipe() pipe.
{ my ($uni_read, $uni_write) = POE::Pipe::Unidirectional->new('pipe');

  if (defined $uni_read and defined $uni_write) {
    &ok(1);

    print $uni_write "whee pipe\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 2, $uni_input eq 'whee pipe' );
  }
  else {
    &many_not_ok(1, 2, "Skip: pipe not supported");
  }
}

### Test unidirectional socketpair() pipe.
{ my ($uni_read, $uni_write) = POE::Pipe::Unidirectional->new('socketpair');

  if (defined $uni_read and defined $uni_write) {
    &ok(3);

    print $uni_write "whee socketpair\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 4, $uni_input eq 'whee socketpair' );
  }
  else {
    &many_not_ok(3, 4, "Skip: socketpair not supported");
  }
}

### Test unidirectional pair of inet sockets.
{ my ($uni_read, $uni_write) = POE::Pipe::Unidirectional->new('inet');

  if (defined $uni_read and defined $uni_write) {
    &ok(5);

    print $uni_write "whee inet\n";
    my $uni_input = <$uni_read>; chomp $uni_input;
    &ok_if( 6, $uni_input eq 'whee inet' );
  }
  else {
    &many_not_ok(5, 6, "Skip: inet sockets not supported");
  }
}

### Test bidirectional pipe.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::Bidirectional->new('pipe');

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
    &many_not_ok(7, 9, "Skip: pipe not supported");
  }
}

### Test bidirectional socketpair.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::Bidirectional->new('socketpair');

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
    &many_not_ok(10, 12, "Skip: socketpair not supported");
  }
}

### Test bidirectional inet sockets.
{ my ($a_rd, $a_wr, $b_rd, $b_wr) =
    POE::Pipe::Bidirectional->new('inet');

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
    &many_not_ok(13, 15, "Skip: inet sockets not supported");
  }
}

### Test Wheel::Run.  Uses "!" as a newline to avoid having to deal
### with whatever the system uses.

my $program =
  ( '/usr/bin/perl -we \'' .
    '$/ = q(!); select STDERR; $| = 1; select STDOUT; $| = 1; ' .
    'while (<STDIN>) { ' .
    'last if /^bye/; ' .
    '  print(STDOUT qq(out: $_)) if s/^out //; ' .
    '  print(STDERR qq(err: $_)) if s/^err //; ' .
    '} ' .
    'exit 0;\''
  );

my $flush_count = 0;

POE::Session->create
  ( inline_states =>
    { _start => sub {
        my ($kernel, $heap) = @_[KERNEL, HEAP];

        # Run a child process.
        $heap->{wheel} = POE::Wheel::Run->new
          ( Program     => $program,
            Filter      => POE::Filter::Line->new( Literal => "!" ),
            StdoutEvent => 'stdout',
            StderrEvent => 'stderr',
            ErrorEvent  => 'error',
            StdinEvent  => 'stdin',
          );

        # Ask the child for something on stdout.
        $heap->{wheel}->put( 'out test-out' );
      },

      # Catch SIGCHLD.  Stop the wheel if the exited child is ours.
      _signal => sub {
        my $signame = $_[ARG0];
        if ($signame eq 'CHLD') {
          my ($heap, $child_pid) = @_[HEAP, ARG1];
          delete $heap->{wheel} if $child_pid == $heap->{wheel}->PID();
        }
        return 0;
      },

      # Count every line that's flushed to the child.
      stdin  => sub { $flush_count++; },

      # Got a stdout response.  Ask for something on stderr.
      stdout => sub { &ok_if(17, $_[ARG0] eq 'out: test-out');
                      $_[HEAP]->{wheel}->put( 'err test-err' );
                    },

      # Got a sterr response.  Tell the child to exit.
      stderr => sub { &ok_if(18, $_[ARG0] eq 'err: test-err');
                      $_[HEAP]->{wheel}->put( 'bye' );
                    },
    },
  );

$poe_kernel->run();

&ok_if( 16, $flush_count == 3 );

&results();
