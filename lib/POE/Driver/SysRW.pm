# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Driver::SysRW;

use strict;
use POSIX qw(EAGAIN);
use Carp;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'out queue'  => [ ],
                     'bytes done' => 0,
                     'bytes left' => 0,
                     BlockSize    => 512,
                   }, $type;

  if (@_) {
    if (@_ % 2) {
      croak "$type requires an even number of parameters, if any";
    }
    my %args = @_;
    if (exists $self->{BlockSize}) {
      $self->{BlockSize} = delete $args{BlockSize};
      croak "$type BlockSize must be greater than 0" if ($self->{BlockSize}<1);
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
  my $old_queue_length = @{$self->{'out queue'}};
  my $new_queue_length = push @{$self->{'out queue'}}, @$chunks;
  if ($new_queue_length && (!$old_queue_length)) {
    $self->{'bytes left'} = length($self->{'out queue'}->[0]);
    $self->{'bytes done'} = 0;
  }
  $new_queue_length;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $handle) = @_;

  my $result = sysread($handle, my $buffer = '', $self->{BlockSize});
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
  while (@{$self->{'out queue'}}) {
    my $wrote_count = syswrite($handle,
                               $self->{'out queue'}->[0],
                               $self->{'bytes left'},
                               $self->{'bytes done'}
                              );

    unless ($wrote_count) {
      $! = 0 if ($! == EAGAIN);
      last;
    }

    $self->{'bytes done'} += $wrote_count;
    unless ($self->{'bytes left'} -= $wrote_count) {
      shift(@{$self->{'out queue'}});
      if (@{$self->{'out queue'}}) {
        $self->{'bytes done'} = 0;
        $self->{'bytes left'} = length($self->{'out queue'}->[0]);
      }
      else {
        $self->{'bytes done'} = $self->{'bytes left'} = 0;
      }
    }
  }

  scalar(@{$self->{'out queue'}});
}

###############################################################################
1;

__END__

=head1 NAME

POE::Driver::SysRW - POE sysread/syswrite Abstraction

=head1 SYNOPSIS

  $driver = new POE::Driver::SysRW();
  $arrayref_of_data_chunks = $driver->get($filehandle);
  $queue_size = $driver->put($arrayref_of_data_chunks);
  $queue_size = $driver->flush($filehandle);

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
