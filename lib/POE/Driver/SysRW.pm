# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Driver::SysRW;

use strict;
use POSIX qw(EAGAIN);
use Carp;

sub OUTPUT_QUEUE        () { 0 }
sub CURRENT_OCTETS_DONE () { 1 }
sub CURRENT_OCTETS_LEFT () { 2 }
sub BLOCK_SIZE          () { 3 }
sub TOTAL_OCTETS_LEFT   () { 4 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless [ [ ], # OUTPUT_QUEUE
                     0,   # CURRENT_OCTETS_DONE
                     0,   # CURRENT_OCTETS_LEFT
                     512, # BLOCK_SIZE
                     0,   # TOTAL_OCTETS_LEFT
                   ], $type;

  if (@_) {
    if (@_ % 2) {
      croak "$type requires an even number of parameters, if any";
    }
    my %args = @_;
    if (exists $args{BlockSize}) {
      $self->[BLOCK_SIZE] = delete $args{BlockSize};
      croak "$type BlockSize must be greater than 0"
        if ($self->[BLOCK_SIZE]<1);
    }
    if (keys %args) {
      my @bad_args = sort keys %args;
      croak "$type has unknown parameter(s): @bad_args";
    }
  }

  $self;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  my $old_queue_octets = $self->[TOTAL_OCTETS_LEFT];

  foreach (grep { length } @$chunks) {
    $self->[TOTAL_OCTETS_LEFT] += length;
    push @{$self->[OUTPUT_QUEUE]}, $_;
  }

  if ($self->[TOTAL_OCTETS_LEFT] && (!$old_queue_octets)) {
    $self->[CURRENT_OCTETS_LEFT] = length($self->[OUTPUT_QUEUE]->[0]);
    $self->[CURRENT_OCTETS_DONE] = 0;
  }

  $self->[TOTAL_OCTETS_LEFT];
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $handle) = @_;

  my $result = sysread($handle, my $buffer = '', $self->[BLOCK_SIZE]);
  if ($result || ($! == EAGAIN)) {
    $! = 0;
    [ $buffer ];
  }
  else {
    undef;
  }
}

#------------------------------------------------------------------------------

sub flush {
  my ($self, $handle) = @_;
                                        # syswrite it, like we're supposed to
  while (@{$self->[OUTPUT_QUEUE]}) {
    my $wrote_count = syswrite($handle,
                               $self->[OUTPUT_QUEUE]->[0],
                               $self->[CURRENT_OCTETS_LEFT],
                               $self->[CURRENT_OCTETS_DONE],
                              );

    unless ($wrote_count) {
      $! = 0 if ($! == EAGAIN);
      last;
    }

    $self->[CURRENT_OCTETS_DONE] += $wrote_count;
    $self->[TOTAL_OCTETS_LEFT] -= $wrote_count;
    unless ($self->[CURRENT_OCTETS_LEFT] -= $wrote_count) {
      shift(@{$self->[OUTPUT_QUEUE]});
      if (@{$self->[OUTPUT_QUEUE]}) {
        $self->[CURRENT_OCTETS_DONE] = 0;
        $self->[CURRENT_OCTETS_LEFT] = length($self->[OUTPUT_QUEUE]->[0]);
      }
      else {
        $self->[CURRENT_OCTETS_DONE] = $self->[CURRENT_OCTETS_LEFT] = 0;
      }
    }
  }

  $self->[TOTAL_OCTETS_LEFT];
}

###############################################################################
1;

__END__

=head1 NAME

POE::Driver::SysRW - POE sysread/syswrite Abstraction

=head1 SYNOPSIS

  $driver = new POE::Driver::SysRW();
  $arrayref_of_data_chunks = $driver->get($filehandle);
  $queue_octets = $driver->put($arrayref_of_data_chunks);
  $queue_octets = $driver->flush($filehandle);

=head1 DESCRIPTION

This driver provides an abstract interface to sysread and syswrite.

=head1 PUBLIC METHODS

=over 4

=item *

POE::Driver::SysRW::new( ... );

The new() constructor accepts one optional parameter:

  BlockSize => $block_size

This is the maximum data size that the SysRW driver will read at once.
If omitted, $block_size defaults to 512.

=back

=head1 SEE ALSO

POE::Driver

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
