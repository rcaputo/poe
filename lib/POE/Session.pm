# $Id$
# Documentation exists after __END__

package POE::Session;

use strict;
use Carp;

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
    print "$self -> $state\n";
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
    elsif (ref($handler) ne '') {
      croak "object '" . ref($handler) .
        "' does not have a '$state' method" unless ($handler->can($state));
      carp "redefining state($state) for session($self)"
        if (exists $self->{'states'}->{$state});
      $self->{'states'}->{$state} = $handler;
    }
    elsif ($self->{'namespace'}->{'_debug'}) {
      print "$self : state($state) is not a proper ref - not registered\n";
    }
  }
  else {
    delete $self->{'states'}->{$state};
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - a state machine, driven by C<POE::Kernel>

=head1 SYNOPSIS

  new POE::Session(
    $kernel,
    '_start' => sub {
      my ($k, $me, $from) = @_;
      # initialize the session
    },
    '_stop'  => sub {
      my ($k, $me, $from) = @_;
      # shut down the session
    },
    '_default' => sub {
      my ($k, $me, $from, $state, @etc) = @_;
      # catches states for which no handlers are registered
      # returns 0 if the state is not handled; 1 if it is (for signal squelch)
      return 0;
    },
  );

  # ... or ...

  new POE::Session(
    $kernel,
    $object, \@methods,
    'state' => \&handler,
    $object_2, \@methods_2,
    'state2' => \&handler_2,
  );

=head1 DESCRIPTION

C<POE::Session> builds an initial state table and registers it as a
full session with C<POE::Kernel>.  The Kernel will invoke C<_start>
after the session is registered, and C<_stop> just before destroying
it.  C<_default> is called when a signal is dispatched to a
nonexistent handler.

Regular states (C<'scalar' => $code_ref>) are invoked as:
C<&$code_ref($kernel, $namespace, $source_session, @$etc)>.

Object states (C<$object, \@event_handler_methods>) are invoked as
C<$object->$method($kernel, $namespace, $source_session, @$etc)>.
Don't forget that C<$_[0]> is a reference to the object in this case.

=head1 PUBLIC METHODS

=over 4

=item new POE::Session($kernel, $name, $handler, $name, $handler, ...);

Build an initial state table (list of events), and register it with a
C<$kernel>.

Normal events/states are named after C<$name>, and handled by CODE
references in C<$handler>.

Then there is the C<$object>, C<\@methods> format.  C<$object> is a
blessed object, and C<\@methods> is a list of events that the object
will handle.  Methods are named after their corresponding events.
When using this syntax, remember that Perl's "=> operator stringifies
its left operand.

The Session will hold a copy of the C<$object> reference for each
registered method.  These references will be freed when the Session
exits, and the referenced C<$object> should be garbage collected at
that time.  The references are also freed when handlers are
deallocated, and deallocating the last handler in an object will free
that object before the Session is destroyed.

C<new(...)> returns a reference to the new Session, which should be
discarded promptly since the C<$kernel> will maintain it.  Keeping
extra copies of the reference will prevent sessions from being freed
when they are done.

=back

=head1 SPECIAL NAMESPACE VARIABLES

=over 4

=item _debug

This will set the runtime debugging level for the C<POE::Session>.

Currently it only toggles (true/false) displaying states as they are
dispatched, and maybe some minor harmless warnings.

=back

=head1 SPECIAL STATES

All states except _start are optional.  Events will be discarded quietly
for any states that do not exist.

=over 4

=item _start ($kernel, $namespace, $from)

Informs a C<POE::Session> that it has been added to a C<POE::Kernel>.

C<$kernel> is a reference to the kernel that owns this session; C<$namespace>
is a reference to a hash that has been set aside for this session to store
persistent information; C<$from> is the session that sent the _start event
(usually a C<POE::Kernel>).

This is the only required state.

=item _stop ($kernel, $namespace, $from)

Informs a C<POE::Session> that is about to be removed from a C<POE::Kernel>.
Anything in C<$namespace> that Perl cannot garbage-collect should be destroyed
here to avoid leaking memory.

C<$kernel>, C<$namespace> and C<$from> are the same as for _start.

=item _default ($kernel, $namespace, $from, $state, @etc)

Informs a C<POE::Session> that it has received an event for which no state
has been registered.  Without a _default state, C<POE::Kernel> will silently
drop undeliverable events.

C<$kernel>, C<$namespace> and C<$from> are the same as for _start.  C<$state>
is the state name that would have received the event.  C<@etc> are any
additional parameters (other than C<$kernel>, C<$namespace> and C<$from>) that
would have been sent to C<$state>.

If the C<_default> state handles the event, return 1.  If the C<_default>
state does not handle the event, return 0.  This allows default states to
squelch signals by handling them.

=item _child ($kernel, $namespace, $departing_session)

Informs a C<POE::Session> that a session it created (or inherited) is about
to be stopped.  One use for this is maintaining a limited pool of parallel
sub-sessions, starting new sessions when old ones go away.

C<$kernel> and C<$namespace> are the same as for _start.  C<$departing_session>
is a reference to the session going away.

=item _parent ($kernel, $namespace, $new_parent)

Informs a C<POE::Session> that its parent session is stopping, and that its
new parent will be C<$new_parent>.

C<$kernel> and C<$namespace> are the same as for _start.  C<$new_parent> is
the new parent of this session.

=back

=head1 SPECIAL STATE CLASSES

=over 4

=item Special States

These states are generated by C<POE::Kernel> and mainly deal with session
management.  Construction, destruction, and parent/child relationships.

=item Signal States

These are states that have been registered as C<%SIG> handlers by
C<POE::Kernel::sig(...)>.

Signal states are invoked with these paramters:

=over 4

=item C<$kernel>

This is the kernel that is managing this session.

=item C<$namespace>

This is a hash into which the session can store "persistent" data.  The
C<$namespace> hash is preserved in the Kernel until the Session stops.

=item $from

This is the Session that generated this state.  Under normal circumstances,
this will be the Kernel.

=item $signal_name

The name of the signal that caused this state event to be sent.  It does
not include the "SIG" prefix (e.g., 'ZOMBIE'; not 'SIGZOMBIE').

=back

Signal states should return 0 if they do not handle the signal, or 1 if the
signal is handled.  Sessions will be stopped if they do not handle terminal
signals that they receive.  Terminal signals currently are defined as
SIGQUIT, SIGTERM, SIGINT, SIGKILL and SIGHUP in F<Kernel.pm>.

Note: C<_default> is also the default signal handle.  It can prevent most
signals from terminating a Session.

There is one "super-terminal" signal, SIGZOMBIE.  It is sent to all tasks when
the Kernel detects that nothing can be done.  The session will be terminated
after this signal is delivered, whether or not the signal is handled.

=item Select States

These states are registerd to C<signal(2)> logic by C<POE::Kernel::select(...)>
and related functions.

Select states are invoked with these parameters:

=over 4

=item C<$kernel>

Same as it ever was.

=item C<$namespace>

Same as it ever was.

=item C<$from>

Same as it ever was.

=item C<$handle>

This is the C<IO::Handle> object that is ready for processing.  How it
should be processed (read, write or exception) depends on the previous
C<$kernel-E<gt>select(...)> call.

=back

=item Alarm States

These are states that accept delayed events sent by C<POE::Kernel::alarm(...)>,
but any state can do this, so why is it listed separately?

=over 4

=item C<$kernel>

Same as it ever was.

=item C<$namespace>

Same as it ever was.

=item C<$from>

Same as it ever was.

=item C<@etc>

Parameters passed to C<$kernel-E<gt>alarm(...)> when it was called will be sent
to the alarm handler here.

=back

=item Wheel States

These states are added to and removed from sessions whenever C<POE::Wheel>
derivatives are created or destroyed.  They can last the entire life of a
session, or they can come and go depending on the current needs of a session.

=back

=head1 PROTECTED METHODS

=over 4

=item $session->_invoke_state($kernel, $source_session, $state, \@etc)

Called by C<POE::Kernel> to invoke state C<$state> generated from
C<$source_session> with a list of optional parameters in C<\@etc>.
Invokes the _default state if it exists and C<$state> does not.

Returns 1 if the event was dispatched, or 0 if the event had nowhere to go.

=item $session->register_state($state, $handler)

Called back by C<POE::Kernel> to add, change or remove states from this
session.

=back

=head1 PRIVATE METHODS

=over 4

=item DESTROY

Destroys the session.  Deletes internal storage.

=back

=head1 EXAMPLES

All the programs in F<tests/> use C<POE::Session>, but especially see
F<tests/sessions.perl> and F<tests/forkbomb.perl>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
