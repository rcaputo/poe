# 2001/01/25 shizukesa@pobox.com

package POE::Filter::RecordBlock;

use Carp qw(croak);
use strict;

sub BLOCKSIZE () { 0 };
sub GETBUFFER () { 1 };
sub PUTBUFFER () { 2 };
sub CHECKPUT  () { 3 };

#------------------------------------------------------------------------------

sub new {
  my $type = shift;

  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  croak "BlockSize must be greater than 0" if
    !defined($params{BlockSize}) || ($params{BlockSize} < 1);

  my $self = bless [$params{BlockSize}, [], [], $params{CheckPut}], $type;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $data) = @_;
  my @result;
  push @{$self->[GETBUFFER]}, @$data;
  while (@{$self->[GETBUFFER]} >= $self->[BLOCKSIZE]) {
    push @result, [ splice @{$self->[GETBUFFER]}, 0, $self->[BLOCKSIZE] ];
  }
  \@result;
}

#------------------------------------------------------------------------------
# 2001-07-27 RCC: Add get_one_start() and get_one() to correct filter
# changing and make input flow control possible.

sub get_one_start {
  my ($self, $data) = @_;
  push @{$self->[GETBUFFER]}, @$data;
}

sub get_one {
  my $self = shift;

  return [ ] unless @{$self->[GETBUFFER]} >= $self->[BLOCKSIZE];
  return [ splice @{$self->[GETBUFFER]}, 0, $self->[BLOCKSIZE] ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $data) = @_;
  my @result;

  if ($self->[CHECKPUT]) {
    foreach (@$data) {
      push @{$self->[PUTBUFFER]}, @$_;
    }
    while (@{$self->[PUTBUFFER]} >= $self->[BLOCKSIZE]) {
      push @result, splice @{$self->[GETBUFFER]}, 0, $self->[BLOCKSIZE];
    }
  }
  else {
    push @result, splice(@{$self->[PUTBUFFER]}, 0);
    foreach (@$data) {
      push @result, @$_;
    }
  }
  \@result;
}

#------------------------------------------------------------------------------

sub get_pending {
  my $self = shift;
  return undef unless @{$self->[GETBUFFER]};
  return [ @{$self->[GETBUFFER]} ];
}

#------------------------------------------------------------------------------

sub put_pending {
  my ($self) = @_;
  return undef unless $self->[CHECKPUT];
  return undef unless @{$self->[PUTBUFFER]};
  return [ @{$self->[PUTBUFFER]} ];
}

#------------------------------------------------------------------------------

sub blocksize {
  my ($self, $size) = @_;
  if (defined($size) && ($size > 0)) {
    $self->[BLOCKSIZE] = $size;
  }
  $self->[BLOCKSIZE];
}

#------------------------------------------------------------------------------

sub checkput {
  my ($self, $val) = @_;
  if (defined($val)) {
    $self->[CHECKPUT] = $val;
  }
  $self->[CHECKPUT];
}

###############################################################################

1;

__END__

=head1 NAME

POE::Filter::RecordBlock - POE Record Block Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::RecordBlock( BlockSize => 4 );
  $arrayref_of_arrayrefs = $filter->get($arrayref_of_raw_data);
  $arrayref_of_raw_chunks = $filter->put($arrayref_of_arrayrefs);
  $arrayref_of_raw_chunks = $filter->put($single_arrayref);
  $arrayref_of_leftovers = $filter->get_pending;
  $arrayref_of_leftovers = $filter->put_pending;

=head1 DESCRIPTION

RecordBlock translates between streams of B<records> and blocks of
B<records>.  In other words, it combines a number of received records
into frames (array references), and it breaks frames back into streams
of records in preparation for transmitting.

A BlockSize parameter must be specified when the filter is
constructed.  It determines how many records are framed into a block,
and it can be changed at runtime.  Checking put() for proper block
sizes is optional and can be either passed as a parameter to the new()
method or changed at runtime.

Extra records are held until enough records arrive to complete a
block.

=head1 PUBLIC FILTER METHODS

=over 4

=item *

POE::Filter::RecordBlock::new

The new() method takes at least one mandatory argument, the BlockSize
parameter.  It must be defined and greater than zero.  The CheckPut
parameter is optional, but if it contains a true value, "put"
blocksize checking is turned on.  Note that if this is the case,
flushing pending records to be put is your responsibility (see
put_pending()).

=item *

POE::Filter::RecordBlock::put_pending

The put_pending() method returns an arrayref of any records that are
waiting to be sent.

=item *

See POE::Filter.

=back

=head1 SEE ALSO

POE::Filter; POE::Filter::Stackable; POE::Filter::HTTPD;
POE::Filter::Reference; POE::Filter::Line; POE::Filter::Block;
POE::Filter::Stream

=head1 BUGS

Undoubtedly.

=head1 AUTHORS & COPYRIGHTS

The RecordBlock filter was contributed by Dieter Pearcey.  Rocco
Caputo is sure to have had his hands in it.

Please see the POE manpage for more information about authors and
contributors.

=cut
