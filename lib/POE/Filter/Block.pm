# $Id$

package POE::Filter::Block;

use strict;
use Carp qw(croak);

sub BLOCK_SIZE     () { 0 }
sub FRAMING_BUFFER () { 1 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  my $block_size =
    ( (exists $params{BlockSize})
      ? ( ($params{BlockSize} < 1)
          ? 512
          : $params{BlockSize}
        )
      : 512
    );

  my $self =
    bless [ $block_size,
            '',
          ], $type;

  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;

  $self->[FRAMING_BUFFER] .= join '', @{$stream};

  my @blocks;
  while (length($self->[FRAMING_BUFFER]) >= $self->[BLOCK_SIZE]) {
    push @blocks, substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]);
    substr($self->[FRAMING_BUFFER], 0, $self->[BLOCK_SIZE]) = '';
  }

  \@blocks;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $blocks) = @_;
  my @raw = join '', @{$blocks};
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

POE::Filter::Block - POE Block Protocol Abstraction

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

The Block filter translates streams to and from blocks of bytes of a
specified size.  If the size is not specified, 512 is used as default;
if the given size is negative, the absolute value is used instead.
Anyway, people trying to use negative blocksizes should be soundly
spanked.

Extra bytes are buffered until more bytes arrive to complete a block.

=head1 PUBLIC FILTER METHODS

Please see POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Stream; POE::Filter::Line

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
