###############################################################################
# Select.pm - Documentation and Copyright are after __END__.
###############################################################################

package POE::Wheel::Select;

use strict;

#------------------------------------------------------------------------------

sub new {
  my ($type, $kernel, $handle, $driver, $filter, $state_in, $state_flush,
      $state_error
     ) = @_;
  my $self = bless { 'handle' => $handle,
                     'kernel' => $kernel,
                     'driver' => $driver,
                     'filter' => $filter,
                   }, $type;
                                        # register the select-read handler
  $kernel->state
    ( $self->{'state read'} = $self . ' -> select read',
      sub {
        my ($k, $me, $from, $handle) = @_;
        if (defined(my $raw_input = $driver->get($handle))) {
          foreach my $cooked_input (@{$filter->get($raw_input)}) {
            $k->post($me, $state_in, $cooked_input)
          }
        }
        else {
          $k->post($me, $state_error, 'read', $!);
          $k->select_read($handle);
        }
      }
    );
                                        # register the select-write handler
  $kernel->state
    ( $self->{'state write'} = $self . ' -> select write',
      sub {
        my ($k, $me, $from, $handle) = @_;

        my $writes_pending = $driver->flush($k, $handle);
        if (defined $writes_pending) {
          unless ($writes_pending) {
            $k->select_write($handle);
          }
        }
        elsif ($!) {
          $k->post($me, $state_error, 'write', $!);
          $k->select_write($handle);
        }
      }
    );

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

  if ($self->{'state write'}) {
    $self->{'kernel'}->state($self->{'state write'});
    delete $self->{'state write'};
  }
}

#------------------------------------------------------------------------------

sub put {
  my $self = shift;
  if ($self->{'driver'}->put($self->{'filter'}->put(join('', @_)))) {
    $self->{'kernel'}->select_write($self->{'handle'}, $self->{'state write'});
  }
}

###############################################################################
1;
__END__

Documentation: to be

Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
This is a pre-release version.  Redistribution and modification are
prohibited.
