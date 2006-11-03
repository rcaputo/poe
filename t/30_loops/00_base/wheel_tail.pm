#!/usr/bin/perl -w
# $Id$

# Exercises Wheel::FollowTail, Wheel::ReadWrite, and Filter::Block.
# -><- Needs tests for Seek and SeekBack.

use strict;
use lib qw(./mylib ../mylib);
use Socket;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More;

unless (-f "run_network_tests") {
  plan skip_all => "Network access (and permission) required to run this test";
}

if ($^O eq "cygwin") {
  plan skip_all => "Cygwin file open/locking semantics thwart this test.";
}

plan tests => 10;

use POE qw(
  Component::Server::TCP
  Wheel::FollowTail
  Wheel::ReadWrite
  Wheel::SocketFactory
  Filter::Line
  Filter::Block
  Driver::SysRW
);

sub DEBUG () { 0 }

my $tcp_server_port = 31909;
my $max_send_count  = 10;    # expected to be even

###############################################################################
# A generic server session.

sub sss_new {
  my ($socket, $peer_addr, $peer_port) = @_;
  POE::Session->create(
    inline_states => {
      _start      => \&sss_start,
      _stop       => \&sss_stop,
      got_error   => \&sss_error,
      got_block   => \&sss_block,
      ev_timeout  => sub {
        DEBUG and warn "=== sss got timeout";
        delete $_[HEAP]->{wheel};
      },
    },
    args => [ $socket, $peer_addr, $peer_port ],
  );
}

sub sss_start {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0..ARG2];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::FollowTail->new(
    Handle       => $socket,
    Driver       => POE::Driver::SysRW->new( BlockSize => 24 ),
    Filter       => POE::Filter::Block->new( BlockSize => 16 ),
    InputEvent   => 'got_block_nonexistent',
    ErrorEvent   => 'got_error_nonexistent',
  );

  # Test event changing.
  $heap->{wheel}->event(
    InputEvent => 'got_block',
    ErrorEvent => 'got_error',
  );

  $heap->{test_two} = 1;
  $heap->{wheel_id} = $heap->{wheel}->ID;
  $heap->{read_count} = 0;
}

sub sss_block {
  my ($kernel, $heap, $block) = @_[KERNEL, HEAP, ARG0];
  DEBUG and warn "=== sss got block";
  $heap->{read_count}++;
  $kernel->delay( ev_timeout => 10 );
}

sub sss_error {
  my ($heap, $syscall, $errnum, $errstr, $wheel_id) = @_[HEAP, ARG0..ARG3];
  DEBUG and warn "=== sss got $syscall error $errnum: $errstr";
  if ($errnum) {
    $_[HEAP]->{test_two} = 0;
  }
}

sub sss_stop {
  my $heap = $_[HEAP];
  DEBUG and warn "=== sss stopped";
  ok($heap->{test_two}, "test two");
  ok(
    $heap->{read_count} == $max_send_count,
    "read everything we were sent " .
    "did($heap->{read_count}) wanted($max_send_count)"
  );
}

###############################################################################
# A TCP socket client.

sub client_tcp_start {
  my $heap = $_[HEAP];

  DEBUG and warn "=== client tcp started";

  $heap->{wheel} = POE::Wheel::SocketFactory->new(
    RemoteAddress  => '127.0.0.1',
    RemotePort    => $tcp_server_port,
    SuccessEvent  => 'got_server_nonexistent',
    FailureEvent  => 'got_error_nonexistent',
  );

  # Test event changing.
  $heap->{wheel}->event(
    SuccessEvent => 'got_server',
    FailureEvent => 'got_error',
  );

  $heap->{socketfactory_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_three} = 1;
}

sub client_tcp_stop {
  my $heap =$_[HEAP];
  ok(
    $heap->{test_three},
    "test three"
  );
  ok(
    $heap->{put_count} == $max_send_count,
    "sent everything we should"
  );

  my $sent_count = $_[HEAP]->{put_count} / 2;
  ok(
    $heap->{flush_count} == $sent_count,
    "flushed what we sent (flush=$heap->{flush_count}; sent=$sent_count)"
  );
  ok(
    $heap->{test_six},
    "test six"
  );
}

sub client_tcp_connected {
  my ($kernel, $heap, $server_socket) = @_[KERNEL, HEAP, ARG0];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new(
    Handle       => $server_socket,
    Driver       => POE::Driver::SysRW->new( BlockSize => 32 ),
    Filter       => POE::Filter::Block->new( BlockSize => 16 ),
    ErrorEvent   => 'got_error_nonexistent',
    FlushedEvent => 'got_flush_nonexistent',
  );

  DEBUG and warn "=== client tcp connected";

  # Test event changing.
  $heap->{wheel}->event(
    ErrorEvent   => 'got_error',
    FlushedEvent => 'got_flush',
  );

  $heap->{test_six} = 1;
  $heap->{readwrite_wheel_id} = $heap->{wheel}->ID;

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 0;

  $kernel->yield( 'got_alarm' );
}

sub client_tcp_got_alarm {
  my ($kernel, $heap, $line) = @_[KERNEL, HEAP, ARG0];

  DEBUG and warn "=== client tcp got alarm";

  $heap->{wheel}->put( '0123456789ABCDEF0123456789ABCDEF' );

  $heap->{put_count} += 2;
  if ($heap->{put_count} < $max_send_count) {
    # Delay is 1 for slow hardware.
    $kernel->delay( got_alarm => 1 );
  }
}

sub client_tcp_got_error {
  my ($heap, $operation, $errnum, $errstr, $wheel_id) = @_[HEAP, ARG0..ARG3];

  if ($wheel_id == $heap->{socketfactory_wheel_id}) {
    $heap->{test_three} = 0;
  }

  if ($wheel_id == $heap->{readwrite_wheel_id}) {
    $heap->{test_six} = 0;
  }

  delete $heap->{wheel};
  warn "$operation error $errnum: $errstr";
}

sub client_tcp_got_flush {
  $_[HEAP]->{flush_count}++;
  DEBUG and warn "=== client_tcp_got_flush";
  # Delays destruction until all data is out.
  delete $_[HEAP]->{wheel} if $_[HEAP]->{put_count} >= $max_send_count;
}

###############################################################################
# Start the TCP server and client.

POE::Component::Server::TCP->new(
  Port     => $tcp_server_port,
  Acceptor => sub {
    &sss_new(@_[ARG0..ARG2]);
    # This next badness is just for testing.
    my $sockname = $_[HEAP]->{listener}->getsockname();
    delete $_[HEAP]->{listener};

    my ($port, $addr) = sockaddr_in($sockname);
    $addr = inet_ntoa($addr);

    ok(
      ($addr eq '0.0.0.0') && ($port == $tcp_server_port),
      "received connection"
    );
  },
);

POE::Session->create(
  inline_states => {
    _start     => \&client_tcp_start,
    _stop      => \&client_tcp_stop,
    got_server => \&client_tcp_connected,
    got_error  => \&client_tcp_got_error,
    got_flush  => \&client_tcp_got_flush,
    got_alarm  => \&client_tcp_got_alarm,
  }
);

### Test a file that appears and disappears.

POE::Session->create(
  inline_states => {
    _start => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];

      unlink "./test-tail-file";
      $heap->{wheel} = POE::Wheel::FollowTail->new(
        Filename => "./test-tail-file",
        InputEvent => "got_input",
        ErrorEvent => "got_error",
        ResetEvent => "got_reset",
  PollInterval => 0.1,
      );
      $kernel->delay(create_file => 1);
      $heap->{sent_count}  = 0;
      $heap->{recv_count}  = 0;
      $heap->{reset_count} = 0;
      DEBUG and warn "=== start";
    },

    create_file => sub {
      open(FH, ">./test-tail-file") or die $!;
      print FH "moo\015\012";
      close FH;
      DEBUG and warn "=== create";
      $_[HEAP]->{sent_count}++;
    },

    got_input => sub {
      my ($kernel, $heap) = @_[KERNEL, HEAP];
      $heap->{recv_count}++;

      DEBUG and warn "=== input";

      unlink "./test-tail-file";

      if ($heap->{recv_count} == 1) {
        $kernel->delay(create_file => 1);
        return;
      }

      delete $heap->{wheel};
    },

    got_error => sub { warn "error"; die },

    got_reset => sub {
      DEBUG and warn "=== reset";
      $_[HEAP]->{reset_count}++;
    },

    _stop => sub {
      DEBUG and warn "=== stop";
      my $heap = $_[HEAP];
      ok(
        ($heap->{sent_count} == $heap->{recv_count}) &&
        ($heap->{sent_count} == 2),
        "sent and received everything we should " .
        "sent($heap->{sent_count}) recv($heap->{recv_count}) wanted(2)"
      );
      ok($heap->{reset_count} > 0, "reset more than once");
    },
  },
);

### main loop

POE::Kernel->run();

pass("run() returned successfully");

1;
