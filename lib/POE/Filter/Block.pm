package POE::Filter::Block;

use strict;
use POE::Filter;

use vars qw($VERSION @ISA);
$VERSION = '1.359'; # NOTE - Should be #.### (three decimal places)
@ISA = qw(POE::Filter);

use Carp qw(croak);

sub FRAMING_BUFFER () { 0 }
sub BLOCK_SIZE     () { 1 }
sub EXPECTED_SIZE  () { 2 }
sub ENCODER        () { 3 }
sub DECODER        () { 4 }
sub MAX_LENGTH     () { 5 }
sub MAX_BUFFER     () { 6 }
sub FIRST_UNUSED   () { 7 }

use base 'Exporter';
our @EXPORT_OK = qw( FIRST_UNUSED );

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

  my $max_buffer = $type->__param_max( MaxBuffer => 512*1024*1024, \%params );

  my ($encoder, $decoder, $max_length);
  my $block_size = delete $params{BlockSize};
  if (defined $block_size) {
    croak "$type doesn't support zero or negative block sizes"
      if $block_size < 1;
    croak "Can't use both LengthCodec and BlockSize at the same time"
      if exists $params{LengthCodec};
    croak "Can't use both MaxLength and BlockSize at the same time"
      if exists $params{MaxLength};
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
    $max_length = $type->__param_max( MaxLength => 64*1024*1024, \%params );
    croak "MaxBuffer is not large enough for MaxLength blocks"
        unless $max_buffer >= $max_length + length( $max_length ) + 1;
  }

  delete @params{qw(MaxLength MaxBuffer LengthCode BlockSize)};
  carp("$type ignores unknown parameters: ", join(', ', sort keys %params))
    if scalar keys %params;

  my $self = bless [
    '',           # FRAMING_BUFFER
    $block_size,  # BLOCK_SIZE
    undef,        # EXPECTED_SIZE
    $encoder,     # ENCODER
    $decoder,     # DECODER
    $max_length,  # MAX_LENGTH
    $max_buffer   # MAX_BUFFER
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
  die "Framing buffer exceeds the limit"
    if $self->[MAX_BUFFER] < length( $self->[FRAMING_BUFFER] );
}

sub get_one {
  my $self = shift;

  # Need to check lengths in octets, not characters.
  BEGIN { eval { require bytes } and bytes->import; }

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

  unless( defined($self->[EXPECTED_SIZE]) ) {
    $self->[EXPECTED_SIZE] = $self->[DECODER]->(\$self->[FRAMING_BUFFER]);
    die "Expected size of next block exceeds the limit"
        if defined($self->[EXPECTED_SIZE]) and 
           $self->[EXPECTED_SIZE] > $self->[MAX_LENGTH];
  }
  if ( defined($self->[EXPECTED_SIZE]) ) {
    return [ ] if length($self->[FRAMING_BUFFER]) < $self->[EXPECTED_SIZE];

    # Four-arg substr() would be better here, but it's not compatible
    # with Perl as far back as we support.
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
  BEGIN { eval { require bytes } and bytes->import; }

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

1;

__END__

=head1 NAME

POE::Filter::Block - translate data between streams and blocks

=head1 SYNOPSIS

  #!perl

  use warnings;
  use strict;
  use POE::Filter::Block;

  my $filter = POE::Filter::Block->new( BlockSize => 8 );

  # Prints three lines: abcdefgh, ijklmnop, qrstuvwx.
  # Bytes "y" and "z" remain in the buffer and await completion of the
  # next 8-byte block.

  $filter->get_one_start([ "abcdefghijklmnopqrstuvwxyz" ]);
  while (1) {
    my $block = $filter->get_one();
    last unless @$block;
    print $block->[0], "\n";
  }

  # Print one line: yz123456

  $filter->get_one_start([ "123456" ]);
  while (1) {
    my $block = $filter->get_one();
    last unless @$block;
    print $block->[0], "\n";
  }

=head1 DESCRIPTION

POE::Filter::Block translates data between serial streams and blocks.
It can handle fixed-length and length-prepended blocks, and it may be
extended to handle other block types.

Fixed-length blocks are used when Block's constructor is called with a
BlockSize value.  Otherwise the Block filter uses length-prepended
blocks.

Users who specify block sizes less than one deserve what they get.

In variable-length mode, a LengthCodec parameter may be specified.
The LengthCodec value should be a reference to a list of two
functions: the length encoder, and the length decoder:

  LengthCodec => [ \&encoder, \&decoder ]

The encoder takes a reference to a buffer and prepends the buffer's
length to it.  The default encoder prepends the ASCII representation
of the buffer's length and a chr(0) byte to separate the length from
the actual data:

  sub _default_encoder {
    my $stuff = shift;
    substr($$stuff, 0, 0) = length($$stuff) . "\0";
    return;
  }

The corresponding decoder returns the block length after removing it
and the separator from the buffer.  It returns nothing if no length
can be determined.

  sub _default_decoder {
    my $stuff = shift;
    unless ($$stuff =~ s/^(\d+)\0//s) {
      warn length($1), " strange bytes removed from stream"
        if $$stuff =~ s/^(\D+)//s;
      return;
    }
    return $1;
  }

This filter holds onto incomplete blocks until they are completed in a
framing buffer.  To control memory usage, a maximum framing buffer size is
imposed.  This maximum size defaults to 512 MB (512*1024*1024 octets).  You
may change this size limit with the C<MaxBuffer> parameter.

    MaxBuffer => 1099511627776  # One terabyte!

The size of each individual block is also limited.  By default, each block
may be no more then 64 MB.  You may change this size limit with the
C<MaxLength> parameter.

    MaxLength => 10             # small blocks

Remember that MaxBuffer needs to be larger then MaxLength.  What's more, it
needs to have room for the length prefix.

If either the C<MaxLength> or C<MaxBuffer> constraint is exceeded,
C<POE::Filter::Bock> will throw an exception.


=head1 PUBLIC FILTER METHODS

POE::Filter::Block has no additional public methods.

=head1 SEE ALSO

Please see L<POE::Filter> for documentation regarding the base
interface.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

The put() method doesn't verify block sizes.

=head1 AUTHORS & COPYRIGHTS

The Block filter was contributed by Dieter Pearcey, with changes by
Rocco Caputo.

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
