# $Id$

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Session;

use strict;
use Carp;
use POSIX qw(ENOSYS);

use Exporter;
@POE::Session::ISA = qw(Exporter);
@POE::Session::EXPORT = qw(OBJECT SESSION KERNEL HEAP STATE SENDER
                           ARG0 ARG1 ARG2 ARG3 ARG4 ARG5 ARG6 ARG7 ARG8 ARG9
                          );

sub OBJECT  () {  0 }
sub SESSION () {  1 }
sub KERNEL  () {  2 }
sub HEAP    () {  3 }
sub STATE   () {  4 }
sub SENDER  () {  5 }
sub ARG0    () {  6 }
sub ARG1    () {  7 }
sub ARG2    () {  8 }
sub ARG3    () {  9 }
sub ARG4    () { 10 }
sub ARG5    () { 11 }
sub ARG6    () { 12 }
sub ARG7    () { 13 }
sub ARG8    () { 14 }
sub ARG9    () { 15 }

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

  croak "sessions no longer require a kernel reference as the first parameter"
    if ((@states > 1) && (ref($states[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $POE::Kernel::poe_kernel);

  my $self = bless { 'namespace' => { },
                     'options'   => { },
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

      unless ((defined $state) && (length $state)) {
        carp "depreciated: using an undefined state";
      }

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
    else {
      last;
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

sub create {
  my ($type, @params) = @_;
  my @args;

  croak "$type requires a working Kernel"
    unless (defined $POE::Kernel::poe_kernel);

  if (@params & 1) {
    croak "odd number of events/handlers (missin one or the other?)";
  }

  my %params = @params;

  my $self = bless { 'namespace' => { },
                     'options'   => { },
                   }, $type;

  if (exists $params{'args'}) {
    if (ref($params{'args'}) eq 'ARRAY') {
      push @args, @{$params{'args'}};
    }
    else {
      push @args, $params{'args'};
    }
    delete $params{'args'};
  }

  my @params_keys = keys(%params);
  foreach (@params_keys) {
    my $state_hash = $params{$_};

    croak "$_ does not refer to a hashref"
      unless (ref($state_hash) eq 'HASH');

    if ($_ eq 'inline_states') {
      while (my ($state, $handler) = each(%$state_hash)) {
        croak "inline state '$state' needs a CODE reference"
          unless (ref($handler) eq 'CODE');
        $self->register_state($state, $handler);
      }
    }
    elsif ($_ eq 'package_states') {
      while (my ($state, $handler) = each(%$state_hash)) {
        croak "states for package '$state' needs an ARRAY reference"
          unless (ref($handler) eq 'ARRAY');
        foreach my $method (@$handler) {
          $self->register_state($method, $state);
        }
      }
    }
    elsif ($_ eq 'object_states') {
      while (my ($state, $handler) = each(%$state_hash)) {
        croak "states for object '$state' need an ARRAY reference"
          unless (ref($handler) eq 'ARRAY');
        foreach my $method (@$handler) {
          $self->register_state($method, $state);
        }
      }
    }
    else {
      croak "unknown $type parameter: $_";
    }
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

  if (exists($self->{'options'}->{'trace'})) {
    warn "$self -> $state\n";
  }

  if (exists $self->{'states'}->{$state}) {
                                        # inline
    if (ref($self->{'states'}->{$state}) eq 'CODE') {
      return &{$self->{'states'}->{$state}}(undef,                    # object
                                            $self,                    # session
                                            $POE::Kernel::poe_kernel, # kernel
                                            $self->{'namespace'},     # heap
                                            $state,                   # state
                                            $source_session,          # sender
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
                                            $state,                   # state
                                            $source_session,          # sender
                                            @$etc                     # args
                                           );
    }
  }
                                        # recursive, so it does the right thing
  elsif (exists $self->{'states'}->{'_default'}) {
    return $self->_invoke_state( $source_session,
                                 '_default',
                                 [ $state, $etc ]
                               );
  }
                                        # whoops!  no _default?
  else {
    $! = ENOSYS;
    if (exists $self->{'options'}->{'default'}) {
      warn "\t$self -> $state does not exist (and no _default)\n";
    }
    return undef;
  }

  return 0;
}

#------------------------------------------------------------------------------

sub register_state {
  my ($self, $state, $handler) = @_;

  if ($handler) {
    if (ref($handler) eq 'CODE') {
      carp "redefining state($state) for session($self)"
        if ( (exists $self->{'options'}->{'debug'}) &&
             (exists $self->{'states'}->{$state})
           );
      $self->{'states'}->{$state} = $handler;
    }
    elsif ($handler->can($state)) {
      carp "redefining state($state) for session($self)"
        if ( (exists $self->{'options'}->{'debug'}) &&
             (exists $self->{'states'}->{$state})
           );
      $self->{'states'}->{$state} = $handler;
    }
    else {
      if (ref($handler) eq 'CODE' &&
          exists($self->{'options'}->{'trace'})
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
  push(@_, 0) if (scalar(@_) & 1);
  my %parameters = @_;

  while (my ($flag, $value) = each(%parameters)) {
                                        # booleanize some handy aliases
    ($value = 1) if ($value =~ /^(on|yes)$/i);
    ($value = 0) if ($value =~ /^(no|off)$/i);
                                        # set or clear the option
    if ($value) {
      $self->{'options'}->{lc($flag)} = $value;
    }
    else {
      delete $self->{'options'}->{lc($flag)};
    }
  }
}

###############################################################################
1;
