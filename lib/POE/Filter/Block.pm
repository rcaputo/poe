# $Id$

package POE::Filter::Block;

use strict;
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

sub put {
  my ($self, $blocks) = @_;
  my @raw;

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
  return unless $self->[FRAMING_BUFFER];
  [ $self->[FRAMING_BUFFER] ];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Block - filter between streams and blocks

=head1 SYNOPSIS

  $filter = new POE::Filter::Block( BlockSize => 1024 );
  $arrayref_of_blocks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($arrayref_of_blocks);
  $arrayref_of_streamable_chunks_for_driver =
    $filter->put($single_block);
  $arrayref_of_leftovers =
    $filter->get_pending();

=head1 DESCRIPTION

The Block filter translates data between serial streams and blocks.
It can handle two kinds of block: fixed-length and length-prepended.

Fixed-length blocks are used when Block's constructor is given a block
size.  Otherwise the Block filter uses length-prepended blocks.

Users who specify block sizes less than one deserver to be soundly
spanked.

Extra bytes are buffered until more bytes arrive to complete a block.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

The Block filter was contributed by Dieter Pearcey, with changes by
Rocco Caputo.

Please see L<POE> for more information about authors and contributors.

=cut
