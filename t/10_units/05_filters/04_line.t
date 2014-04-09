#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Exercises Filter::Line without the rest of POE.

use strict;
use lib qw(./mylib ../mylib);
use lib qw(t/10_units/05_filters);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use TestFilter;
use Test::More tests => 28 + $COUNT_FILTER_INTERFACE + 2*$COUNT_FILTER_STANDARD;

use_ok("POE::Filter::Line");
test_filter_interface("POE::Filter::Line");

test_new("new(): even number of args", "one", "two", "odd");
test_new("new(): empty Literal", Literal => "");
# What is Regexp?  I see InputRegexp, but not Regexp
test_new("new(): Literal and Regexp", Regexp => "\r", Literal => "\n");
test_new("new(): Literal and InputRegexp", InputRegexp => "\r", Literal => "\n");
test_new("new(): Literal and InputLiteral", InputLiteral => "\r", Literal => "\n");
test_new("new(): Literal and OutputLiteral", OutputLiteral => "\r", Literal => "\n");
test_new("new(): InputLiteral and InputRegexp", InputRegexp => "\r", InputLiteral => "\n");

sub test_new {
    my ($name, @args) = @_;
    eval { POE::Filter::Line->new(@args); };
    ok(!(!$@), $name);
}

# Test the line filter in default mode.
{
  my $filter = POE::Filter::Line->new();
  isa_ok($filter, 'POE::Filter::Line');

  test_filter_standard(
    $filter,
    [ "a\x0D", "b\x0A", "c\x0D\x0A", "d\x0A\x0D" ],
    [ "a", "b", "c", "d" ],
    [ "a\x0D\x0A", "b\x0D\x0A", "c\x0D\x0A", "d\x0D\x0A" ],
  );
}

# Test the line filter in literal mode.
{
  my $filter = POE::Filter::Line->new( Literal => 'x' );

  test_filter_standard(
    $filter,
    [ "axa", "bxb", "cxc", "dxd" ],
    [ "a", "ab", "bc", "cd" ],
    [ "ax", "abx", "bcx", "cdx" ],
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

# Test param constraints
{
    my $filter = eval {
            new POE::Filter::Line(
                        MaxLength => 10,
                        MaxBuffer => 5 );
        };
    ok( $@, "MaxLength must not exceed MaxBuffer" );
    ok( !$filter, "No object on error" );

    $filter = eval { new POE::Filter::Line( MaxLength => -1 ) };
    ok( $@, "MaxLength must be positive" );

    $filter = eval { new POE::Filter::Line( MaxLength => 'something' ) };
    ok( $@, "MaxLength must be a number" );

    $filter = eval { new POE::Filter::Line( MaxBuffer => 0 ) };
    ok( $@, "MaxBuffer must be positive" );

    $filter = eval { new POE::Filter::Line( MaxBuffer => 'something' ) };
    ok( $@, "MaxBuffer must be a number" );
}

# Test MaxLength
{
    my $filter = new POE::Filter::Line( MaxLength => 10 );
    isa_ok( $filter, 'POE::Filter::Line' );

    my $data = "This line is going to be to long for our filter\n";
    my $blocks = eval { $filter->get( [ $data ] ) };
    like( $@, qr/line exceeds/, "Line is to large" );
}

# Test MaxBuffer
{
    my $filter = new POE::Filter::Line( MaxBuffer => 10,
                                         MaxLength => 5 );
    isa_ok( $filter, 'POE::Filter::Line' );

    my $data = "This line is going to be to long for our filter\n";
    my $blocks = eval { $filter->get( [ $data ] ) };
    like( $@, qr/buffer exceeds/, "buffer grew to large" );
}
