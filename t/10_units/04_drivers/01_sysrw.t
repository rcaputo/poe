#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

use strict;

use Test::More tests => 17;
use POE::Pipe::OneWay;

BEGIN { use_ok("POE::Driver::SysRW") }

# Start with some errors.

eval { my $d = POE::Driver::SysRW->new( BlockSize => 0 ) };
ok(
  $@ && $@ =~ /BlockSize must be greater than 0/,
  "disallow zero or negative block sizes"
);

eval { my $d = POE::Driver::SysRW->new( 0 ) };
ok(
  $@ && $@ =~ /requires an even number of parameters/,
  "disallow zero or negative block sizes"
);

eval { my $d = POE::Driver::SysRW->new( Booga => 1 ) };
ok(
  $@ && $@ =~ /unknown parameter.*Booga/,
  "disallow unknown parameters"
);

# This block of tests also exercises the driver with its default
# constructor parameters.

{ my $d = POE::Driver::SysRW->new();

  use Symbol qw(gensym);
  my $fh = gensym();
  open $fh, ">deleteme.now" or die $!;

  $! = 0;

  open(SAVE_STDERR, ">&STDERR") or die $!;
  close(STDERR) or die $!;

  my $get_ret = $d->get($fh);
  ok(!defined($get_ret), "get() returns undef on error");
  ok($!, "get() sets \$! on error ($!)");

  open(STDERR, ">&SAVE_STDERR") or die $!;
  close(SAVE_STDERR) or die $!;

  close $fh;
  unlink "deleteme.now";
}

my $d = POE::Driver::SysRW->new( BlockSize => 1024 );

# Empty put().

{ my $octets_left = $d->put([ ]);
  ok( $octets_left == 0, "buffered 0 octets on empty put()" );
}

ok( $d->get_out_messages_buffered() == 0, "no messages buffered" );

# The number of octets we expect in the driver's put() buffer.
my $expected = 0;

# Put() returns the correct number of octets.

{ my $string_to_put = "test" x 10;
  my $length_to_put = length($string_to_put);
  $expected += $length_to_put;

  my $octets_left = $d->put([ $string_to_put ]);
  ok(
    $octets_left == $expected,
    "first put: buffer contains $octets_left octets (should be $expected)"
  );
}

# Only one message buffered.

ok( $d->get_out_messages_buffered() == 1, "one message buffered" );

# Put() returns the correct number of octets on a subsequent call.

{ my $string_to_put = "more test" x 5;
  my $length_to_put = length($string_to_put);
  $expected += $length_to_put;

  my $octets_left = $d->put([ $string_to_put ]);
  ok(
    $octets_left == $expected,
    "second put: buffer contains $octets_left octets (should be $expected)"
  );
}

# Remaining tests require some live handles.

my ($r, $w) = POE::Pipe::OneWay->new();
die "can't open a pipe: $!" unless $r;

nonblocking($w);
nonblocking($r);

# Number of flushed octets == number of read octets.

{ my $flushed_count = write_until_pipe_is_full($d, $w);
  my $read_count    = read_until_pipe_is_empty($d, $r);

  ok(
    $flushed_count == $read_count,
    "flushed $flushed_count octets == read $read_count octets"
  );
}

# Flush the buffer and the pipe.

while (flush_remaining_buffer($d, $w)) {
  read_until_pipe_is_empty($d, $r);
}

{
  my $out_messages = $d->get_out_messages_buffered();
  ok($out_messages == 0, "buffer exhausted (got $out_messages wanted 0)");
}

# Get() returns undef ($! == 0) on EOF.

{ write_until_pipe_is_full($d, $w);
  close($w);

  open(SAVE_STDERR, ">&STDERR") or die $!;
  close(STDERR) or die $!;

  while (1) {
    $! = 1;
    last unless defined $d->get($r);
  }

  pass("driver returns undef on eof");
  ok($! == 0, "\$! is clear on eof");

  open(STDERR, ">&SAVE_STDERR") or die $!;
  close(SAVE_STDERR) or die $!;
}

# Flush() returns the number of octets remaining, and sets $! to
# nonzero on major error.

{ open(SAVE_STDERR, ">&STDERR") or die $!;
  close(STDERR) or die $!;

  # Make sure $w is closed.  Sometimes, like on Cygwin, it isn't.
  close $w;

  $! = 0;
  my $error_left = $d->flush($w);

  ok($error_left, "put() returns octets left on error");
  ok($!, "put() sets \$! nonzero on error");

  open(STDERR, ">&SAVE_STDERR") or die $!;
  close(SAVE_STDERR) or die $!;
}

exit 0;

# Buffer data, and flush it, until the pipe refuses to hold more data.
# This should also cause the driver to experience an EAGAIN or
# EWOULDBLOCK on write.

sub write_until_pipe_is_full {
  my ($driver, $handle) = @_;

  my $big_chunk = "*" x (1024 * 1024);

  my $flushed   = 0;
  my $full      = 0;

  while (1) {
    # Put a big chunk into the buffer.
    my $buffered    = $driver->put([ $big_chunk ]);

    # Try to flush it.
    my $after_flush = $driver->flush($handle);

    # Flushed amount.
    $flushed += $buffered - $after_flush;

    # The pipe is full if there's data after the flush.
    last if $after_flush;
  }

  return $flushed;
}

# Assume the driven has buffered data.  This makes sure it's flushed,
# or at least the pipe is clogged.  Combine it with
# read_until_pipe_is_empty() to flush the driver and the pipe.

sub flush_remaining_buffer {
  my ($driver, $handle) = @_;

  my $before_flush = $driver->get_out_messages_buffered();
  $driver->flush($handle);
  return $before_flush;
}

# Read until there's nothing left to read from the pipe.  This should
# exercise the driver's EAGAIN/EWOULDBLOCK code on the read side.

sub read_until_pipe_is_empty {
  my ($driver, $handle) = @_;

  my $read_octets = 0;

  # SunOS catalogue1 5.11 snv_101b i86pc i386 i86pc
  # Sometimes returns "empty" when there's data in the pipe.
  # Looping again seems to fetch the remaining data, though.
  for (1..3) {
    while (1) {
      my $data = $driver->get($handle);
      last unless defined($data) and @$data;
      $read_octets += length() foreach @$data;
    }
  }

  return $read_octets;
}

# Portable nonblocking sub.  blocking(0) doesn't do it all the time,
# everywhere, and it sucks.
#
# This sub sucks, too.  The code is lifted almost verbatim from
# POE::Resource::FileHandles.  That code should probably be made a
# library function, but where should it go?

sub nonblocking {
  my $handle = shift;

  # For DOSISH systems like OS/2.  Wrapped in eval{} in case it's a
  # tied handle that doesn't support binmode.
  eval { binmode *$handle };

  # Turn off blocking.
  eval { $handle->blocking(0) };

  # Turn off buffering.
  CORE::select((CORE::select($handle), $| = 1)[0]);
}
