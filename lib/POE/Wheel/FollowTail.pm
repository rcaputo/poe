# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Wheel::FollowTail;

use strict;
use Carp;
use POSIX qw(SEEK_SET SEEK_CUR SEEK_END);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $kernel = shift;
  my %params = @_;

  croak "Handle required" unless (exists $params{'Handle'});
  croak "Driver required" unless (exists $params{'Driver'});
  croak "Filter required" unless (exists $params{'Filter'});
  croak "InputState required" unless (exists $params{'InputState'});

  my ($handle, $driver, $filter, $state_in, $state_error) =
    @params{ qw(Handle Driver Filter InputState ErrorState) };

  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                     'driver' => $driver,
                     'filter' => $filter,
                   }, $type;
                                        # pre-declare (whee!)
  $self->{'state read'} = $self . ' -> select read';
  $self->{'state wake'} = $self . ' -> alarm';
                                        # check for file activity
  $kernel->state
    ( $self->{'state read'},
      sub {
        my ($k, $me, $from, $handle) = @_;
        
        while (defined(my $raw_input = $driver->get($handle))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->post($me, $state_in, $cooked_input)
          }
        }

        $k->select_read($handle);

        if ($!) {
          $state_error && $k->post($me, $state_error, 'read', ($!+0), $!);
        }
        else {
          $k->alarm($self->{'state wake'}, time()+1);
        }
      }
    );
                                        # wake up and smell the filehandle
  $kernel->state
    ( $self->{'state wake'},
      sub {
        my ($k, $me) = @_;
        $k->select_read($handle, $self->{'state read'});
      }
    );
                                        # set the file position to the end
  seek($handle, 0, SEEK_END);
  seek($handle, -4096, SEEK_CUR);
                                        # discard partial lines and stuff
  while (defined(my $raw_input = $driver->get($handle))) {
    $filter->get($raw_input);
  }
                                        # nudge the wheel into action
  $kernel->select($handle, $self->{'state read'});

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
                                        # remove tentacles from our owner
  $self->{'kernel'}->select($self->{'handle'});

  if ($self->{'state read'}) {
    $self->{'kernel'}->state($self->{'state read'});
    delete $self->{'state read'};
  }

  if ($self->{'state wake'}) {
    $self->{'kernel'}->state($self->{'state wake'});
    delete $self->{'state wake'};
  }
}

###############################################################################
1;
