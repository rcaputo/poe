# $Id$

package POE::Filter::Block;
use POE::Preprocessor ( isa => "POE::Macro::UseBytes" );

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(croak);

sub BLOCK_SIZE     () { 0 }
sub FRAMING_BUFFER () { 1 }
sub EXPECTED_SIZE  () { 2 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  my $block_size = $params{BlockSize};
  if (defined($params{BlockSize}) and defined($block_size)) {
    croak "$type doesn't support zero or negative block sizes"
      if $block_size < 1;
  }

  my $self =
    bless [ $block_size,
            '',
            undef,
          ], $type;

  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my @blocks;
  $self->[FRAMING_BUFFER] .= join '', @{$stream};

  {% use_bytes %}

  # If a block size is specified, then frame input into blocks of that
  # size.
  if (defined $self->[BLOCK_SIZE]) {
    while (length($self->[FRAMING_BUFFER]) >= $self->[BLOCK_SIZE]) {
      push @blocks, substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]);
      substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]) = '';
    }
  }

  # Otherwise we're doing the variable-length block thing. Look for a
  # length marker, and then pull off a chunk of that length.  Repeat.

  else {
    while ( defined($self->[EXPECTED_SIZE]) ||
            ( ($self->[FRAMING_BUFFER] =~ s/^(\d+)\0//s) &&
              ($self->[EXPECTED_SIZE] = $1)
            )
          ) {
      last if (length $self->[FRAMING_BUFFER] < $self->[EXPECTED_SIZE]);

      my $chunk = substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]);
      substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]) = '';
      undef $self->[EXPECTED_SIZE];

      push @blocks, $chunk;
    }
  }

  \@blocks;
}

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

  {% use_bytes %}

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

  if ( defined($self->[EXPECTED_SIZE]) ||
       ( ($self->[FRAMING_BUFFER] =~ s/^(\d+)\0//s) &&
         ($self->[EXPECTED_SIZE] = $1)
       )
     ) {
    return [ ] if length($self->[FRAMING_BUFFER]) < $self->[EXPECTED_SIZE];

    my $block = substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]);
    substr($self->[FRAMING_BUFFER], 0, $self->[EXPECTED_SIZE]) = '';
    undef $self->[EXPECTED_SIZE];

    return [ $block ];
  }

  return [ ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $blocks) = @_;
  my @raw;

  {% use_bytes %}

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
    @raw = map { length($_) . "\0" . $_; } @$blocks;
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
  $arrayref_of_blocks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_blocks);
  $arrayref_of_leftovers =
    $filter->get_pending();

=head1 DESCRIPTION

The Block filter translates data between serial streams and blocks.
It can handle two kinds of block: fixed-length and length-prepended.

Fixed-length blocks are used when Block's constructor is given a block
size.  Otherwise the Block filter uses length-prepended blocks.

Users who specify block sizes less than one deserve to be soundly
spanked.

Extra bytes are buffered until more bytes arrive to complete a block.

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
