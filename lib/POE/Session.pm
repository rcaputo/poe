# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Session;

use strict;
use Carp;
use Exporter;

@POE::Session::ISA = qw(Exporter);
@POE::Session::EXPORT = qw(OBJECT SESSION KERNEL HEAP SENDER
                           ARG0 ARG1 ARG2 ARG3 ARG4 ARG5 ARG6 ARG7 ARG8 ARG9
                          );

#------------------------------------------------------------------------------
# Exported Constants

sub OBJECT  () {  0 }
sub SESSION () {  1 }
sub KERNEL  () {  2 }
sub HEAP    () {  3 }
sub SENDER  () {  4 }
sub ARG0    () {  5 }
sub ARG1    () {  6 }
sub ARG2    () {  7 }
sub ARG3    () {  8 }
sub ARG4    () {  9 }
sub ARG5    () { 10 }
sub ARG6    () { 11 }
sub ARG7    () { 12 }
sub ARG8    () { 13 }
sub ARG9    () { 14 }

#------------------------------------------------------------------------------
# AUTOLOAD to translate regular calls into method invocations.

# sub AUTOLOAD {
#   use vars qw($AUTOLOAD);
#   die "not ready: $AUTOLOAD";
# }

#------------------------------------------------------------------------------

# sub post {
#   warn "*** post(", join(', ', @_), ")\n";
# }

#------------------------------------------------------------------------------

sub new {
  my ($type, @states) = @_;

  my @args;

  croak "$type requires a working Kernel"
    unless (defined $POE::Kernel::poe_kernel);

  my $self = bless { 'namespace'   => { },
                     'debug_flags' => { },
                   }, $type;

  while (@states) {
                                        # handle arguments
    if (ref($states[0]) eq 'ARRAY') {
      if (@args) {
        croak "$type must only have one block of arguments";
      }
      push @args, @{$states[0]};
      shift @states;
      next;
    }

    if (@states >= 2) {
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
        croak "strange reference ($handler) used as an object session method";
      }
      foreach my $method (@$handler) {
        $self->register_state($method, $state);
      }
    }
  }

  if (@states) {
    croak "odd number of events/handlers (missing one or the other?)";
  }

  if (exists $self->{'states'}->{'_start'}) {
    $POE::Kernel::poe_kernel->session_alloc($self, @args);
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
  my ($self, $source_session, $state, $etc) = @_;

  if (exists($self->{'debug_flags'}->{'trace'})) {
    warn "$self -> $state\n";
  }

  if (exists $self->{'states'}->{$state}) {
                                        # inline
    if (ref($self->{'states'}->{$state}) eq 'CODE') {
      return &{$self->{'states'}->{$state}}(undef,                    # object
                                            $self,                    # session
                                            $POE::Kernel::poe_kernel, # kernel
                                            $self->{'namespace'},     # heap
                                            $source_session,          # from
                                            @$etc                     # args
                                           );
    }
                                        # package and object
    else {
      return
        $self->{'states'}->{$state}->$state(                          # object
                                            $self,                    # session
                                            $POE::Kernel::poe_kernel, # kernel
                                            $self->{'namespace'},     # heap
                                            $source_session,          # from
                                            @$etc                     # args
                                           );
    }
  }
                                        # recursive, so it does the right thing
  elsif (exists $self->{'states'}->{'_default'}) {
    return $self->_invoke_state($source_session, '_default', [ $state, $etc ]);
  }
                                        # whoops!  no _default?
  elsif (exists $self->{'debug_flags'}->{'default'}) {
    warn "\t$self -> $state does not exist (and no _default)\n";
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
      if (ref($handler) eq 'CODE' &&
          exists($self->{'debug_flags'}->{'trace'})
      ) {
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

#------------------------------------------------------------------------------

sub option {
  my $self = shift;
  push(@_, 0) if (@_ % 1);
  my %parameters = @_;

  while (my ($flag, $value) = each(%parameters)) {
                                        # booleanize some handy aliases
    ($value = 1) if ($value =~ /^(on|yes)$/i);
    ($value = 0) if ($value =~ /^(no|off)$/i);
                                        # set or clear the debug flag
    if ($value) {
      $self->{'debug_flags'}->{lc($flag)} = $value;
    }
    else {
      delete $self->{'debug_flags'}->{lc($flag)};
    }
  }
}

###############################################################################
1;
