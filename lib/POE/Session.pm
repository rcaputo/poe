# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Session;

use strict;
use Carp;

#------------------------------------------------------------------------------

sub post {
  print "*** post(", join(', ', @_), ")\n";
}

#------------------------------------------------------------------------------

sub new {
  my ($type, $kernel, @states) = @_;

  my $self = bless { 'kernel'    => $kernel,
                     'namespace' => { },
                   }, $type;

  while (@states >= 2) {
    my ($state, $handler) = splice(@states, 0, 2);

    if (ref($state) eq 'CODE') {
      croak "using a CODE reference as an event handler name is not allowed";
    }
                                        # regular states
    if (ref($state) eq '') {
      if (ref($handler) eq 'CODE') {
        $self->register_state($state, $handler);
        next;
      }
      elsif (ref($handler) eq 'ARRAY') {
        foreach my $method (@$handler) {
          $self->register_state($method, $state);
        }
        next;
      }
      else {
        croak "using something other than a CODEREF for $state handler";
      }
    }
                                        # object states
    if (ref($handler) eq '') {
      $self->register_state($handler, $state);
      next;
    }
    if (ref($handler) ne 'ARRAY') {
      croak "strange reference ($handler) used as an 'object' session method";
    }
    foreach my $method (@$handler) {
      $self->register_state($method, $state);
    }
  }

  if (@states) {
    croak "odd number of events/handlers (missing one or the other?)";
  }

  if (exists $self->{'states'}->{'_start'}) {
    $kernel->session_alloc($self);
  }
  else {
    carp "discarding session $self - no '_start' state";
  }

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  delete $self->{'kernel'};
  delete $self->{'namespace'};
  delete $self->{'states'};
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;

  if ($self->{'namespace'}->{'_debug'}) {
    print "\e[1;36m$self -> $state\e[0m\n";
  }

  if (exists $self->{'states'}->{$state}) {
    if (ref($self->{'states'}->{$state}) eq 'CODE') {
      return &{$self->{'states'}->{$state}}($kernel, $self->{'namespace'},
                                            $source_session, @$etc
                                           );
    }
    else {
      return $self->{'states'}->{$state}->$state($kernel, $self->{'namespace'},
                                                 $source_session, @$etc
                                                );
    }
  }
                                        # recursive, so it does the right thing
  elsif (exists $self->{'states'}->{'_default'}) {
    return $self->_invoke_state($kernel, $source_session, '_default',
                                [ $state, $etc ]
                               );
  }
  return 0;
}

#------------------------------------------------------------------------------

sub register_state {
  my ($self, $state, $handler) = @_;

  if ($handler) {
    if (ref($handler) eq 'CODE') {
      carp "redefining state($state) for session($self)"
        if (exists $self->{'states'}->{$state});
      $self->{'states'}->{$state} = $handler;
    }
    elsif ($handler->can($state)) {
      carp "redefining state($state) for session($self)"
        if (exists $self->{'states'}->{$state});
      $self->{'states'}->{$state} = $handler;
    }
    else {
      if (ref($handler) eq 'CODE' && $self->{'namespace'}->{'_debug'}) {
        carp "$self : state($state) is not a proper ref - not registered"
      }
      else {
        croak "object $handler does not have a '$state' method"
          unless ($handler->can($state));
      }
    }
  }
  else {
    delete $self->{'states'}->{$state};
  }
}

###############################################################################
1;
