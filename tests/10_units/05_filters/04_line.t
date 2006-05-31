#!/usr/bin/perl -w
# $Id$
# vim: filetype=perl

# Exercises Filter::Line without the rest of POE.

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use Test::More tests => 14;

use_ok("POE::Filter::Line");

# Test the line filter in default mode.

{
  my $filter = POE::Filter::Line->new();

  my $received = $filter->get( [ "a\x0D", "b\x0A", "c\x0D\x0A", "d\x0A\x0D" ] );
  is_deeply(
    $received, [ "a", "b", "c", "d" ],
    "line serializer stripped newlines on input"
  );

  my $sent = $filter->put($received);
  is_deeply(
    $sent, [ "a\x0D\x0A", "b\x0D\x0A", "c\x0D\x0A", "d\x0D\x0A" ],
    "line serializer added newlines to output"
  );
}

# Test the line filter in literal mode.

{
  my $filter = POE::Filter::Line->new( Literal => 'x' );

  my $received = $filter->get( [ "axa", "bxb", "cxc", "dxd" ] );
  is_deeply(
    $received, [ "a", "ab", "bc", "cd" ],
    "literal mode line filter parsed input"
  );

  my $sent = $filter->put( $received );
  is_deeply(
    $sent, [ "ax", "abx", "bcx", "cdx" ],
    "literal mode line filter serialized output"
  );
}

# Test the line filter with different input and output literals.
{
  my $filter = POE::Filter::Line->new(
    InputLiteral  => 'x',
    OutputLiteral => 'y',
  );

  my $received = $filter->get( [ "axa", "bxb", "cxc", "dxd" ] );
  is_deeply(
    $received, [ "a", "ab", "bc", "cd" ],
    "different literals parsed input",
  );

  my $sent = $filter->put( $received );
  is_deeply(
    $sent, [ "ay", "aby", "bcy", "cdy" ],
    "different literals serialized output"
  );
}

# Test the line filter with an input string regexp and an output
# literal.

{
  my $filter = POE::Filter::Line->new(
    InputRegexp   => '[xy]',
    OutputLiteral => '!',
  );

  my $received = $filter->get( [ "axa", "byb", "cxc", "dyd" ] );
  is_deeply(
    $received, [ "a", "ab", "bc", "cd" ],
    "regexp parser parsed input"
  );

  my $sent = $filter->put( $received );
  is_deeply(
    $sent, [ "a!", "ab!", "bc!", "cd!" ],
    "regexp parser serialized output"
  );
}

# Test the line filter with an input compiled regexp and an output
# literal.

SKIP: {
  skip("Perl $] doesn't support qr//", 2) if $] < 5.005;

  my $compiled_regexp = eval "qr/[xy]/";
  my $filter = POE::Filter::Line->new(
    InputRegexp   => $compiled_regexp,
    OutputLiteral => '!',
  );

  my $received = $filter->get( [ "axa", "byb", "cxc", "dyd" ] );
  is_deeply(
    $received, [ "a", "ab", "bc", "cd" ],
    "compiled regexp parser parsed input"
  );

  my $sent = $filter->put( $received );
  is_deeply(
    $sent, [ "a!", "ab!", "bc!", "cd!" ],
    "compiled regexp parser serialized output"
  );
}

# Test newline autodetection.  \x0D\x0A split between lines.
{
  my $filter = POE::Filter::Line->new(
    InputLiteral  => undef,
    OutputLiteral => '!',
  );

  my @received;
  foreach ("a\x0d", "\x0Ab\x0D\x0A", "c\x0A\x0D", "\x0A") {
    my $local_received = $filter->get( [ $_ ] );
    if (defined $local_received and @$local_received) {
      push @received, @$local_received;
    }
  }

  my $sent = $filter->put( \@received );
  is_deeply(
    $sent,
    [ "a!", "b!", "c\x0A!" ],
    "autodetected MacOS newlines parsed and reserialized",
  );
}

# Test newline autodetection.  \x0A\x0D on first line.
{
  my $filter = POE::Filter::Line->new(
    InputLiteral  => undef,
    OutputLiteral => '!',
  ); # autodetect

  my @received;
  foreach ("a\x0A\x0D", "\x0Db\x0A\x0D", "c\x0D", "\x0A\x0D") {
    my $local_received = $filter->get( [ $_ ] );
    if (defined $local_received and @$local_received) {
      push @received, @$local_received;
    }
  }

  my $sent = $filter->put( \@received );
  is_deeply(
    $sent,
    [ "a!", "\x0Db!", "c\x0D!" ],
    "autodetected network newline parsed and reserialized"
  );
}

# Test newline autodetection.  \x0A by itself, with suspicion.
{
  my $filter = POE::Filter::Line->new(
    InputLiteral  => undef,
    OutputLiteral => '!',
  ); # autodetect

  my @received;
  foreach ("a\x0A", "b\x0D\x0A", "c\x0D", "\x0A") {
    my $local_received = $filter->get( [ $_ ] );
    if (defined $local_received and @$local_received) {
      push @received, @$local_received;
    }
  }

  my $sent = $filter->put( \@received );
  is_deeply(
    $sent,
    [ "a!", "b\x0D!", "c\x0D!" ],
    "autodetected Unix newlines parsed and reserialized"
  );
}
