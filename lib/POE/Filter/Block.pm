# $Id$

package POE::Filter::Block;

use strict;
use POE::Filter;

use vars qw($VERSION @ISA);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};
@ISA = qw(POE::Filter);

use Carp qw(croak);

sub BLOCK_SIZE     () { 0 }
sub FRAMING_BUFFER () { 1 }
sub EXPECTED_SIZE  () { 2 }
sub ENCODER        () { 3 }
sub DECODER        () { 4 }

#------------------------------------------------------------------------------

sub _default_decoder {
  my $stuff = shift;
  unless ($$stuff =~ s/^(\d+)\0//s) {
    warn length($1), " strange bytes removed from stream"
      if $$stuff =~ s/^(\D+)//s;
    return;
  }
  return $1;
}

sub _default_encoder {
  my $stuff = shift;
  substr($$stuff, 0, 0) = length($$stuff) . "\0";
  return;
}

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  my ($encoder, $decoder);
  my $block_size = delete $params{BlockSize};
  if (defined $block_size) {
    croak "$type doesn't support zero or negative block sizes"
      if $block_size < 1;
    croak "Can't use both LengthCodec and BlockSize at the same time"
      if exists $params{LengthCodec};
  }
  else {
    my $codec = delete $params{LengthCodec};
    if ($codec) {
      croak "LengthCodec must be an array reference"
        unless ref($codec) eq "ARRAY";
      croak "LengthCodec must contain two items"
        unless @$codec == 2;
      ($encoder, $decoder) = @$codec;
      croak "LengthCodec encoder must be a code reference"
        unless ref($encoder) eq "CODE";
      croak "LengthCodec decoder must be a code reference"
        unless ref($decoder) eq "CODE";
    }
    else {
      $encoder = \&_default_encoder;
      $decoder = \&_default_decoder;
    }
  }

  my $self = bless [
    $block_size,  # BLOCK_SIZE
    '',           # FRAMING_BUFFER
    undef,        # EXPECTED_SIZE
    $encoder,     # ENCODER
    $decoder,     # DECODER
  ], $type;

  $self;
}

#------------------------------------------------------------------------------
# get() is inherited from POE::Filter.

#------------------------------------------------------------------------------
# 2001-07-27 RCC: The get_one() variant of get() allows Wheel::Xyz to
# retrieve one filtered block at a time.  This is necessary for filter
# changing and proper input flow control.

sub get_one_start {
  my ($self, $stream) = @_;
  $self->[FRAMING_BUFFER] .= join '', @$stream;
}

sub get_one {
  my $self = shift;

  # Need to check lengths in octets, not characters.
  use bytes;

  # If a block size is specified, then pull off a block of that many
  # bytes.

  if (defined $self->[BLOCK_SIZE]) {
    return [ ] unless length($self->[FRAMING_BUFFER]) >= $self->[BLOCK_SIZE];
    my $block = substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]);
    substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]) = '';
    return [ $block ];
  }

  # Otherwise we're doing the variable-length block thing.  Look for a
  # length marker, and then pull off a chunk of that length.  Repeat.

  if (
    defined($self->[EXPECTED_SIZE]) ||
    defined(
      $self->[EXPECTED_SIZE] = $self->[DECODER]->(\$self->[FRAMING_BUFFER])
    )
  ) {
    return [ ] if length($self->[FRAMING_BUFFER]) < $self->[EXPECTED_SIZE];

    # TODO - Four-arg substr() would be better here, but it's not
    # compatible with Perl as far back as we support.
    my $block = substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]);
    substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]) = '';
    $self->[EXPECTED_SIZE] = undef;

    return [ $block ];
  }

  return [ ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $blocks) = @_;
  my @raw;

  # Need to check lengths in octets, not characters.
  use bytes;

  # If a block size is specified, then just assume the put is right.
  # This will cause quiet framing errors on the receiving side.  Then
  # again, we'll have quiet errors if the block sizes on both ends
  # differ.  Ah, well!

  if (defined $self->[BLOCK_SIZE]) {
    @raw = join '', @$blocks;
  }

  # No specified block size. Do the variable-length block thing. This
  # steals a lot of Artur's code from the Reference filter.

  else {
    @raw = @$blocks;
    foreach (@raw) {
      $self->[ENCODER]->(\$_);
    }
  }

  \@raw;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  return undef unless length $self->[FRAMING_BUFFER];
  [ $self->[FRAMING_BUFFER] ];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Block - filter between streams and blocks

=head1 SYNOPSIS

  $filter = POE::Filter::Block->new( BlockSize => 1024 );
  $filter = POE::Filter::Block->new(
    LengthCodec => [ \&encoder, \&decoder ]
  );
  $arrayref_of_blocks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_blocks);
  $arrayref_of_leftovers =
    $filter->get_pending();

=head1 DESCRIPTION

The Block filter translates data between serial streams and blocks.
It can handle two kinds of block: fixed-length and length-prepended.

Fixed-length blocks are used when Block's constructor is called with a
BlockSize value.  Otherwise the Block filter uses length-prepended
blocks.

Users who specify block sizes less than one deserve to be soundly
spanked.

In variable-length mode, a LengthCodec parameter is valid.  The
LengthCodec should be a list reference of two functions: The length
encoder, and the length decoder:

  LengthCodec => [ \&encoder, \&decoder ]

The encoder takes a reference to a buffer and prepends the buffer's
length to it.  The default encoder prepends the ASCII representation
of the buffer's length.  The length is separated from the buffer by an
ASCII NUL ("\0") character.

  sub _default_encoder {
    my $stuff = shift;
    substr($$stuff, 0, 0) = length($$stuff) . "\0";
    return;
  }

Sensibly enough, the corresponding decoder removes the prepended
length and separator, returning its numeric value.  It returns nothing
if no length can be determined.

  sub _default_decoder {
    my $stuff = shift;
    unless ($$stuff =~ s/^(\d+)\0//s) {
      warn length($1), " strange bytes removed from stream"
        if $$stuff =~ s/^(\D+)//s;
      return;
    }
    return $1;
  }

This filter holds onto incomplete blocks until they are completed.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

The put() method doesn't verify block sizes.

=head1 AUTHORS & COPYRIGHTS

The Block filter was contributed by Dieter Pearcey, with changes by
Rocco Caputo.

Please see L<POE> for more information about authors and contributors.

=cut
