#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises filter changing.  A lot of this code comes from Philip
# Gwyn's filterchange.perl sample.

use strict;
use lib qw(./mylib ../mylib);

use Test::More;
use MyOtherFreezer;

sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use POE qw(
  Wheel::ReadWrite Driver::SysRW
  Filter::Block Filter::Line Filter::Reference Filter::Stream
  Pipe::OneWay Pipe::TwoWay
);

# Showstopper here.  Try to build a pair of file handles.  This will
# try a pair of pipe()s and socketpair().  If neither succeeds, then
# all tests are skipped.  Try socketpair() first, so that both methods
# will be tested on my test platforms.

# Socketpair.  Read and write handles are the same.
my ($master_read, $master_write, $slave_read, $slave_write) = (
  POE::Pipe::TwoWay->new()
);
unless (defined $master_read) {
  plan skip_all => "Could not create a pipe in any form."
}

# Set up tests, and go.
plan tests => 41;

### Skim down to PARTIAL BUFFER TESTS to find the partial buffer
### get_pending tests.  Those tests can run stand-alone without the
### event loop.

### Script for the master session.  This is a send/expect thing, but
### the expected responses are implied by the commands that are sent.
### Normal master operation is: (1) send the command; (2) get
### response; (3) switch our filter if we sent a "do".  Normal slave
### operation is: (1) get a command; (2) send response; (3) switch our
### filter if we got "do".

# Tests:
# (lin -> lin)  (lin -> str)  (lin -> ref)  (lin -> blo)
# (str -> lin)  (str -> str)  (str -> ref)  (str -> blo)
# (ref -> lin)  (ref -> str)  (ref -> ref)  (ref -> blo)
# (blo -> lin)  (blo -> str)  (blo -> ref)  (blo -> blo)

# Symbolic constants for mode names, so we don't make typos.
sub LINE      () { 'line'      }
sub STREAM    () { 'stream'    }
sub REFERENCE () { 'reference' }
sub BLOCK     () { 'block'     }

# Commands to switch modes.
sub DL () { 'do ' . LINE      }
sub DS () { 'do ' . STREAM    }
sub DR () { 'do ' . REFERENCE }
sub DB () { 'do ' . BLOCK     }

# Script that drives the master session.
my @master_script = (
  DL, # line      -> line
  'rot13 1 kyriel',
  DS, # line      -> stream
  'rot13 2 addi',
  DS, # stream    -> stream
  'rot13 3 attyz',
  DL, # stream    -> line
  'rot13 4 crimson',
  DR, # line      -> reference
  'rot13 5 crysflame',
  DR, # reference -> reference
  'rot13 6 dngor',
  DL, # reference -> line
  'rot13 7 freeside',
  DB, # line      -> block
  'rot13 8 halfjack',
  DB, # block     -> block
  'rot13 9 lenzo',
  DS, # block     -> stream
  'rot13 10 mendel',
  DR, # stream    -> reference
  'rot13 11 purl',
  DB, # reference -> block
  'rot13 12 roderick',
  DR, # block     -> reference
  'rot13 13 shizukesa',
  DS, # reference -> stream
  'rot13 14 simon',
  DB, # stream    -> block
  'rot13 15 sky',
  DL, # o/` and that brings us back to line o/`
  'rot13 16 stimps',

  'done',
);

### Helpers to wrap payloads in mode-specific envelopes.  Stream and
### line modes don't need envelopes.

sub wrap_payload {
  my ($mode, $payload) = @_;

  if ($mode eq REFERENCE) {
    my $copy = $payload;
    $payload = \$copy;
  }

  return $payload;
}

sub unwrap_payload {
  my ($mode, $payload) = @_;
  $payload = $$payload if $mode eq REFERENCE;
  return $payload;
}

### Slave session.  This session is controlled by the master session.
### It's also the server, in the client/server context.

sub slave_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::ReadWrite->new(
    InputHandle  => $slave_read,
    OutputHandle => $slave_write,
    Filter       => POE::Filter::Line->new(),
    Driver       => POE::Driver::SysRW->new(),
    InputEvent   => 'got_input',
    FlushedEvent => 'got_flush',
    ErrorEvent   => 'got_error',
  );

  $heap->{current_mode} = LINE;
  $heap->{shutting_down} = 0;

  DEBUG and warn "S: started\n";
}

sub slave_stop {
  DEBUG and warn "S: stopped\n";
}

sub slave_input {
  my ($heap, $input) = @_[HEAP, ARG0];
  my $mode = $heap->{current_mode};
  $input = unwrap_payload( $mode, $input );
  DEBUG and warn "S: got $mode input: $input\n";

  # Asking us to switch modes.  Whee!
  if ($input =~ /^do (.+)$/) {
    my $response = "will $1";
    if ($1 eq LINE) {
      $heap->{wheel}->put( wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Line->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq STREAM) {
      $heap->{wheel}->put( wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Stream->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq REFERENCE) {
      $heap->{wheel}->put( wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter(
        POE::Filter::Reference->new('MyOtherFreezer')
      );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq BLOCK) {
      $heap->{wheel}->put( wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Block->new() );
      $heap->{current_mode} = $1;
    }
    # Don't know; don't care; why bother?
    else {
      $heap->{wheel}->put( wrap_payload( $mode, "wont $response" ) );
    }
    DEBUG and warn "S: switched to $1 filter\n";
    return;
  }

  # Asking us to respond in the current mode.  Whee!
  if ($input =~ /^rot13\s+(\d+)\s+(.+)$/) {
    my ($test_number, $query, $response) = ($1, $2, $2);
    $response =~ tr[a-zA-Z][n-za-mN-ZA-M];
    $heap->{wheel}->put(
      wrap_payload( $mode, "rot13 $test_number $query=$response" )
    );
    return;
  }

  # Telling us we're done.
  if ($input eq 'done') {
    DEBUG and warn "S: shutting down upon request\n";
    $heap->{wheel}->put( wrap_payload( $mode, 'done' ) );
    $heap->{shutting_down} = 1;
    return;
  }

  if ($input eq 'oops') {
    DEBUG and warn "S: got oops... shutting down\n";
    delete $heap->{wheel};
  }
  else {
    $heap->{wheel}->put( wrap_payload( $mode, 'oops' ) );
    $heap->{shutting_down} = 1;
  }
}

sub slave_flush {
  my $heap = $_[HEAP];
  if ($heap->{shutting_down}) {
    DEBUG and warn "S: shut down...\n";
    delete $heap->{wheel};
  }
}

sub slave_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
  DEBUG and do {
    warn "S: got $operation error $errnum: $errstr\n";
    warn "S: shutting down...\n";
  };
  delete $heap->{wheel};
}

### Master session.  This session controls the tests.  It's also the
### client, if you look at things from a client/server perspective.

sub master_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{wheel}   = POE::Wheel::ReadWrite->new(
    InputHandle  => $master_read,
    OutputHandle => $master_write,
    Filter       => POE::Filter::Line->new(),
    Driver       => POE::Driver::SysRW->new(),
    InputEvent   => 'got_input',
    FlushedEvent => 'got_flush',
    ErrorEvent   => 'got_error',
  );

  $heap->{current_mode}  = LINE;
  $heap->{script_step}   = 0;
  $heap->{shutting_down} = 0;
  $kernel->yield( 'do_cmd' );

  DEBUG and warn "M: started\n";
}

sub master_stop {
  DEBUG and warn "M: stopped\n";
}

sub master_input {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $mode = $heap->{current_mode};
  $input = unwrap_payload( $mode, $input );
  DEBUG and warn "M: got $mode input: $input\n";

  # Telling us they've switched modes.  Whee!
  if ($input =~ /^will (.+)$/) {
    if ($1 eq LINE) {
      $heap->{wheel}->set_filter( POE::Filter::Line->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq STREAM) {
      $heap->{wheel}->set_filter( POE::Filter::Stream->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq REFERENCE) {
      $heap->{wheel}->set_filter(
        POE::Filter::Reference->new('MyOtherFreezer')
      );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq BLOCK) {
      $heap->{wheel}->set_filter( POE::Filter::Block->new() );
      $heap->{current_mode} = $1;
    }
    # Don't know; don't care; why bother?
    else {
      die "dunno what $input means in real filter switching context";
    }

    DEBUG and warn "M: switched to $1 filter\n";
    $kernel->yield( 'do_cmd' );
    return;
  }

  # Telling us a response in the current mode.
  if ($input =~ /^rot13\s+(\d+)\s+(.*?)=(.*?)$/) {
    my ($test_number, $query, $response) = ($1, $2, $3);
    $query =~ tr[a-zA-Z][n-za-mN-ZA-M];
    ok( $query eq $response, "got rot13 response $response" );
    $kernel->yield( 'do_cmd' );
    return;
  }

  if ($input eq 'done') {
    DEBUG and warn "M: got done ACK; shutting down\n";
    delete $heap->{wheel};
    return;
  }

  if ($input eq 'oops') {
    DEBUG and warn "M: got oops... shutting down\n";
    delete $heap->{wheel};
  }
  else {
    $heap->{wheel}->put( wrap_payload( $mode, 'oops' ) );
    $heap->{shutting_down} = 1;
  }
}

sub master_do_next_command {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my $script_step = $heap->{script_step}++;
  if ($script_step < @master_script) {
    DEBUG and warn(
      "M: is sending cmd $script_step: $master_script[$script_step]\n"
    );
    $heap->{wheel}->put(
      wrap_payload( $heap->{current_mode}, $master_script[$script_step] )
    );
  }
  else {
    DEBUG and warn "M: is done sending commands...\n";
  }
}

sub master_flush {
  my $heap = $_[HEAP];
  if ($heap->{shutting_down}) {
    DEBUG and warn "S: shut down...\n";
    delete $heap->{wheel};
  }
}

sub master_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
  DEBUG and do {
    warn "M: got $operation error $errnum: $errstr\n";
    warn "M: shutting down...\n";
  };
  delete $heap->{wheel};
}

### Streamed session does just about everything together.

# Streamed tests:
# (lin -> lin)  (lin -> ref)  (lin -> blo)
# (ref -> lin)  (ref -> ref)  (ref -> blo)
# -blo -> lin)  (blo -> ref)  (blo -> blo)

# Script that drives the streamed test session.  It must be different
# because "stream" eats everything all at once, ruining the data
# beyond it.  That's okay with handshaking (above), but not here.

my @streamed_script = (
  DL, # line      -> line
  'kyriel',
  DR, # line      -> reference
  'coral',
  DR, # reference -> reference
  'drforr',
  DB, # reference -> block
  'fimmtiu',
  DB, # block     -> block
  'sungo',
  DR, # block     -> reference
  'dynweb',
  DL, # reference -> line
  'sky',
  DB, # line      -> block
  'braderuna',
  DL, # o/` and that brings us back to line o/`
  'fletch',

  'done',
);

sub streamed_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my ($read, $write) = POE::Pipe::OneWay->new();
  die $! unless defined $read;

  $heap->{stream} = POE::Wheel::ReadWrite->new(
    InputHandle  => $read,
    OutputHandle => $write,
    Filter       => POE::Filter::Line->new(),
    Driver       => POE::Driver::SysRW->new(),
    InputEvent   => 'got_input',
    ErrorEvent   => 'got_error',
  );

  # Start in line mode.
  my $current_mode = $heap->{current_mode} = LINE;
  $heap->{errors} = $heap->{current_step} = 0;

  # Stream it all at once.  Whee!
  foreach my $step (@streamed_script) {

    # Send whatever it is in the current mode.
    $heap->{stream}->put( wrap_payload( $current_mode, $step ) );

    # Switch to the next mode if we should.
    if ($step =~ /^do (\S+)/) {
      $current_mode = $1;

      if ($current_mode eq LINE) {
        $heap->{stream}->set_output_filter( POE::Filter::Line->new() ),
      }
      elsif ($current_mode eq REFERENCE) {
        $heap->{stream}->set_output_filter(
          POE::Filter::Reference->new('MyOtherFreezer')
        );
      }
      elsif ($current_mode eq BLOCK) {
        $heap->{stream}->set_output_filter( POE::Filter::Block->new() ),
      }
      else {
        die;
      }
    }
  }
}

sub streamed_input {
  my ($kernel, $heap, $wrapped_input) = @_[KERNEL, HEAP, ARG0];

  my $input = unwrap_payload( $heap->{current_mode}, $wrapped_input );

  ok(
    $input eq $streamed_script[$heap->{current_step}++],
    "unwrapped payload ($input) matches expectation"
  );

  if ($input =~ /^do (\S+)/) {
    my $current_mode = $heap->{current_mode} = $1;

    if ($current_mode eq LINE) {
      $heap->{stream}->set_input_filter( POE::Filter::Line->new() ),
    }
    elsif ($current_mode eq REFERENCE) {
      $heap->{stream}->set_input_filter(
        POE::Filter::Reference->new('MyOtherFreezer')
      );
    }
    elsif ($current_mode eq BLOCK) {
      $heap->{stream}->set_input_filter( POE::Filter::Block->new() ),
    }
    else {
      die;
    }

    return;
  }

  delete $heap->{stream} if $input eq 'done';
}


### Handshaking tests.

# Start the slave/server session first.
POE::Session->create(
  inline_states => {
    _start    => \&slave_start,
    _stop     => \&slave_stop,
    got_input => \&slave_input,
    got_flush => \&slave_flush,
    got_error => \&slave_error,
  }
);

# Start the master/client session last.
POE::Session->create(
  inline_states => {
    _start    => \&master_start,
    _stop     => \&master_stop,
    got_input => \&master_input,
    got_flush => \&master_flush,
    got_error => \&master_error,
    do_cmd    => \&master_do_next_command,
  }
);

### Streamed filter transition tests.  These are all run together.
### The object is to figure out how to unglom things.

POE::Session->create(
  inline_states => {
    _start    => \&streamed_start,
    _stop     => sub { }, # placeholder for stricture test
    got_input => \&streamed_input,
  }
);

# Begin the handshaking and streaming tests.  I think this is an
# improvement over forking.

POE::Kernel->run();

### PARTIAL BUFFER TESTS.  (1) Create each test filter; (2) stuff each
### filter with a whole message and a part of one; (3) check that one
### whole message comes out; (4) check that get_pending returns the
### incomplete message; (5) check that get_pending again returns
### undef.

# Line filter.
{
  my $filter = POE::Filter::Line->new();
  my $return = $filter->get( [ "whole line\x0D\x0A", "partial line" ] );
  is_deeply(
    $return, [ "whole line" ],
    "parsed only whole line from input"
  );

  my $pending = $filter->get_pending();
  is_deeply(
    $pending, [ "partial line" ],
    "partial line is waiting in buffer"
  );
}

# Block filter.
{
  my $filter = POE::Filter::Block->new( BlockSize => 64 );
  my $return = $filter->get( [ pack('A64', "whole block"), "partial block" ] );
  is_deeply(
    $return, [ pack("A64", "whole block") ],
    "parsed only whole block from input"
  );

  my $pending = $filter->get_pending();
  is_deeply(
    $pending, [ "partial block" ],
    "partial block is waiting in buffer"
  );
}

# Reference filter.
{
  my $filter = POE::Filter::Reference->new();
  my $original_reference = \"whole_reference";
  my $serialized_reference = $filter->put( [ $original_reference ] );

  my $return = $filter->get(
    [
      $serialized_reference->[0], "100\0partial reference"
    ]
  );

  is_deeply(
    $return, [ $original_reference ],
    "parsed only whole reference from input"
  );

  my $pending = $filter->get_pending();
  is_deeply(
    $pending, [ "100\0partial reference" ],
    "partial reference is waiting in buffer"
  );
}

exit;
