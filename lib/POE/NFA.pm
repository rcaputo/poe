# $Id$

package POE::NFA;

use strict;
use Carp qw(carp croak confess);

use POE::Preprocessor;

# I had made these constant subs, but you can't use constant subs as
# hash keys, so they're POE::Preprocessor constants.  Blargh!  This is
# kinda dumb; you *can* make them hash keys, as long as you prefix
# them with a plus so they're not quite barewords.  D'oh.  Maybe
# change these back, or something.

const SPAWN_INLINES  'inline_states'
const SPAWN_OPTIONS  'options'

const OPT_TRACE   'trace'
const OPT_DEBUG   'debug'
const OPT_DEFAULT 'default'

const EN_DEFAULT '_default'
const EN_START   '_start'
const EN_STOP    '_stop'

const NFA_EN_GOTO_STATE 'poe_nfa_goto_state'
const NFA_EN_POP_STATE  'poe_nfa_pop_state'
const NFA_EN_PUSH_STATE 'poe_nfa_push_state'
const NFA_EN_STOP       'poe_nfa_stop'

enum   SELF_RUNSTATE SELF_OPTIONS SELF_STATES SELF_CURRENT SELF_STATE_STACK
enum + SELF_INTERNALS SELF_CURRENT_NAME SELF_IS_IN_INTERNAL

enum   STACK_STATE STACK_EVENT

# Define some debugging flags for subsystems, unless someone already
# has defined them.
BEGIN {
  defined &DEB_DESTROY or eval 'sub DEB_DESTROY () { 0 }';
}

#------------------------------------------------------------------------------

macro fetch_id (<whence>) {
  $POE::Kernel::poe_kernel->ID_session_to_id(<whence>)
}

# MACROS END <-- search tag for editing

#------------------------------------------------------------------------------
# Export constants into calling packages.  This is evil; perhaps
# EXPORT_OK instead?

sub OBJECT   () {  0 }
sub MACHINE  () {  1 }
sub KERNEL   () {  2 }
sub RUNSTATE () {  3 }
sub EVENT    () {  4 }
sub SENDER   () {  5 }
sub ARG0     () {  6 }
sub ARG1     () {  7 }
sub ARG2     () {  8 }
sub ARG3     () {  9 }
sub ARG4     () { 10 }
sub ARG5     () { 11 }
sub ARG6     () { 12 }
sub ARG7     () { 13 }
sub ARG8     () { 14 }
sub ARG9     () { 15 }

use Exporter;
@POE::NFA::ISA = qw(Exporter);
@POE::NFA::EXPORT = qw( OBJECT MACHINE KERNEL RUNSTATE EVENT SENDER
                        ARG0 ARG1 ARG2 ARG3 ARG4 ARG5 ARG6 ARG7 ARG8 ARG9
                      );

#------------------------------------------------------------------------------
# Spawn a new state machine.

sub spawn {
  my ($type, @params) = @_;
  my @args;

  # We treat the parameter list strictly as a hash.  Rather than dying
  # here with a Perl error, we'll catch it and blame it on the user.

  croak "odd number of states/handlers (missing one or the other?)"
    if @params & 1;
  my %params = @params;

  croak "$type requires a working Kernel"
    unless defined $POE::Kernel::poe_kernel;

  # Options are optional.
  my $options = delete $params{SPAWN_OPTIONS};
  $options = { } unless defined $options;

  # States are required.
  croak "$type constructor requires a SPAWN_INLINES parameter"
    unless exists $params{SPAWN_INLINES};
  my $states = delete $params{SPAWN_INLINES};

  # These are unknown.
  croak( "$type constructor does not recognize these parameter names: ",
         join(', ', sort(keys(%params)))
       ) if keys %params;

  # Build me.
  my $self =
    bless [ { },        # SELF_RUNSTATE
            $options,   # SELF_OPTIONS
            $states,    # SELF_STATES
            undef,      # SELF_CURRENT
            [ ],        # SELF_STATE_STACK
            { },        # SELF_INTERNALS
            '(undef)',  # SELF_CURRENT_NAME
            0,          # SELF_IS_IN_INTERNAL
          ], $type;

  # Register the machine with the POE kernel.
  $POE::Kernel::poe_kernel->session_alloc($self);

  # Return it for immediate reuse.
  return $self;
}

#------------------------------------------------------------------------------
# Another good inheritance candidate.

sub DESTROY {
  my $self = shift;

  # NFA's data structures are destroyed through Perl's usual
  # garbage collection.  DEB_DESTROY here just shows what's in the
  # session before the destruction finishes.

  DEB_DESTROY and do {
    print "----- NFA $self Leak Check -----\n";
    print "-- Namespace (HEAP):\n";
    foreach (sort keys (%{$self->[SELF_RUNSTATE]})) {
      print "   $_ = ", $self->[SELF_RUNSTATE]->{$_}, "\n";
    }
    print "-- Options:\n";
    foreach (sort keys (%{$self->[SELF_OPTIONS]})) {
      print "   $_ = ", $self->[SELF_OPTIONS]->{$_}, "\n";
    }
    print "-- States:\n";
    foreach (sort keys (%{$self->[SELF_STATES]})) {
      print "   $_ = ", $self->[SELF_STATES]->{$_}, "\n";
    }
  };
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $sender, $event, $args, $file, $line) = @_;

  # Turn a synchronous wheel call into an asynchronous event.  This
  # desynchronizes wheel callbacks to us.
  if ($self->[SELF_IS_IN_INTERNAL]) {
    if (exists($self->[SELF_OPTIONS]->{OPT_TRACE})) {
      warn {% fetch_id $self %}, " -> $event (reposting to desynchronize)\n";
    }

    $POE::Kernel::poe_kernel->post( $self, $event, @$args );
    return;
  }

  # Trace the state invocation if tracing is enabled.

  if (exists($self->[SELF_OPTIONS]->{OPT_TRACE})) {
    warn {% fetch_id $self %}, " -> $event\n";
  }

  # Discard troublesome things.
  return if $event eq EN_START;
  return if $event eq EN_STOP;

  # Stop request has come through the queue.  Shut us down.
  if ($event eq NFA_EN_STOP) {
    $POE::Kernel::poe_kernel->session_free( $self );
    return;
  }

  # Make a state transition.
  if ($event eq NFA_EN_GOTO_STATE) {
    my ($new_state, $enter_event, @enter_args) = @$args;

    # Make sure the new state exists.
    die( {% fetch_id $self %},
         " tried to enter nonexistent state '$new_state'\n"
       )
      unless exists $self->[SELF_STATES]->{$new_state};

    # If an enter event was specified, make sure that exists too.
    die( {% fetch_id $self %},
         " tried to invoke nonexistent enter event '$enter_event' ",
         "in state '$new_state'\n"
       )
      unless ( defined $enter_event and length $enter_event and
               exists $self->[SELF_STATES]->{$new_state}->{$enter_event}
             );

    # Invoke the current state's leave event, if one exists.
    $self->_invoke_state( $self, 'leave', [], undef, undef )
      if exists $self->[SELF_CURRENT]->{leave};

    # Enter the new state.
    $self->[SELF_CURRENT]      = $self->[SELF_STATES]->{$new_state};
    $self->[SELF_CURRENT_NAME] = $new_state;

    # Invoke the new state's enter event, if requested.
    $self->_invoke_state( $self, $enter_event, \@enter_args, undef, undef );

    return undef;
  }

  # Push a state transition.
  if ($event eq NFA_EN_PUSH_STATE) {

    my @args = @$args;
    push( @{$self->[SELF_STATE_STACK]},
          [ $self->[SELF_CURRENT_NAME], # STACK_STATE
            shift(@args),               # STACK_EVENT
          ]
        );
    $self->_invoke_state( $self, NFA_EN_GOTO_STATE, \@args, undef, undef );

    return undef;
  }

  # Pop a state transition.
  if ($event eq NFA_EN_POP_STATE) {

    die( {% fetch_id $self %},
         " tried to pop a state from an empty stack\n"
       )
      unless @{ $self->[SELF_STATE_STACK] };

    my ($previous_state, $previous_event) =
      @{ pop @{ $self->[SELF_STATE_STACK] } };
    $self->_invoke_state( $self, NFA_EN_GOTO_STATE,
                          [ $previous_state, $previous_event, @$args ],
                          undef, undef
                        );

    return undef;
  }

  # Stop.

  # Try to find the event handler in the current state or the internal
  # event handlers used by wheels and the like.
  my ( $handler, $is_in_internal );

  if (exists $self->[SELF_CURRENT]->{$event}) {
    $handler = $self->[SELF_CURRENT]->{$event};
  }

  elsif (exists $self->[SELF_INTERNALS]->{$event}) {
    $handler = $self->[SELF_INTERNALS]->{$event};
    $is_in_internal = ++$self->[SELF_IS_IN_INTERNAL];
  }

  # If it wasn't found in either of those, then check for _default in
  # the current state.
  elsif (exists $self->[SELF_CURRENT]->{EN_DEFAULT}) {
    # If we get this far, then there's a _default event to redirect
    # the event to.  Trace the redirection.
    if (exists($self->[SELF_OPTIONS]->{OPT_TRACE})) {
      warn( {% fetch_id $self %},
            " -> $event redirected to EN_DEFAULT in state ",
            "'$self->[SELF_CURRENT_NAME]'\n"
          );
    }

    $handler = $self->[SELF_CURRENT]->{EN_DEFAULT};

    # Fix up ARG0.. for _default.
    $args  = [ $event, $args ];
    $event = EN_DEFAULT;
  }

  # No external event handler, no internal event handler, and no
  # external _default handler.  This is a grievous error, and now we
  # must die.
  else {
    die( "a '$event' event was sent from $file at $line to session ",
         {% fetch_id $self %}, ", but session ", {% fetch_id $self %},
         " has neither that event nor a _default event to handle it ",
         "in its current state, '$self->[SELF_CURRENT_NAME]'\n"
       );
  }

  # Inline event handlers are invoked this way.

  my $return;
  if (ref($handler) eq 'CODE') {
    $return = $handler->
      ( undef,                      # OBJECT
        $self,                      # MACHINE
        $POE::Kernel::poe_kernel,   # KERNEL
        $self->[SELF_RUNSTATE],     # RUNSTATE
        $event,                     # EVENT
        $sender,                    # SENDER
        @$args                      # ARG0..
      );
  }

  # Package and object handlers are invoked this way.

  else {
    my ($object, $method) = @$handler;
    $return = $object->$method      # OBJECT (package, implied)
      ( $self,                      # MACHINE
        $POE::Kernel::poe_kernel,   # KERNEL
        $self->[SELF_RUNSTATE],     # RUNSTATE
        $event,                     # EVENT
        $sender,                    # SENDER
        @$args                      # ARG0..
      );
  }

  $self->[SELF_IS_IN_INTERNAL]-- if $is_in_internal;

  return $return;
}

#------------------------------------------------------------------------------
# Add, remove or replace event handlers in the session.  This is going
# to be tricky since wheels need this but the event handlers can't be
# limited to a single state.  I think they'll go in a hidden internal
# state, or something.

macro validate_state {
  carp "redefining state($name) for session(", {% fetch_id $self %}, ")"
    if ( (exists $self->[SELF_OPTIONS]->{OPT_DEBUG}) &&
         (exists $self->[SELF_INTERNALS]->{$name})
       );
}

sub register_state {
  my ($self, $name, $handler, $method) = @_;
  $method = $name unless defined $method;

  # There is a handler, so try to define the state.  This replaces an
  # existing state.

  if ($handler) {

    # Coderef handlers are inline states.

    if (ref($handler) eq 'CODE') {
      {% validate_state %}
      $self->[SELF_INTERNALS]->{$name} = $handler;
    }

    # Non-coderef handlers may be package or object states.  See if
    # the method belongs to the handler.

    elsif ($handler->can($method)) {
      {% validate_state %}
      $self->[SELF_INTERNALS]->{$name} = [ $handler, $method ];
    }

    # Something's wrong.  This code also seems wrong, since
    # ref($handler) can't be 'CODE'.

    else {
      if ( (ref($handler) eq 'CODE') and
           exists($self->[SELF_OPTIONS]->{OPT_TRACE})
         ) {
        carp( {% fetch_id $self %},
              " : state($name) is not a proper ref - not registered"
            )
      }
      else {
        croak "object $handler does not have a '$method' method"
          unless ($handler->can($method));
      }
    }
  }

  # No handler.  Delete the state!

  else {
    delete $self->[SELF_INTERNALS]->{$name};
  }
}

#------------------------------------------------------------------------------
# Return the session's ID.  This is a thunk into POE::Kernel, where
# the session ID really lies.  This is a good inheritance candidate.

sub ID {
  {% fetch_id shift %}
}

#------------------------------------------------------------------------------
# Set or fetch session options.  This is virtually identical to
# POE::Session and a good inheritance candidate.

sub option {
  my $self = shift;
  my %return_values;

  # Options are set in pairs.

  while (@_ >= 2) {
    my ($flag, $value) = splice(@_, 0, 2);
    $flag = lc($flag);

    # If the value is defined, then set the option.

    if (defined $value) {

      # Change some handy values into boolean representations.  This
      # clobbers the user's original values for the sake of DWIM-ism.

      ($value = 1) if ($value =~ /^(on|yes|true)$/i);
      ($value = 0) if ($value =~ /^(no|off|false)$/i);

      $return_values{$flag} = $self->[SELF_OPTIONS]->{$flag};
      $self->[SELF_OPTIONS]->{$flag} = $value;
    }

    # Remove the option if the value is undefined.

    else {
      $return_values{$flag} = delete $self->[SELF_OPTIONS]->{$flag};
    }
  }

  # If only one option is left, then there's no value to set, so we
  # fetch its value.

  if (@_) {
    my $flag = lc(shift);
    $return_values{$flag} =
      ( exists($self->[SELF_OPTIONS]->{$flag})
        ? $self->[SELF_OPTIONS]->{$flag}
        : undef
      );
  }

  # If only one option was set or fetched, then return it as a scalar.
  # Otherwise return it as a hash of option names and values.

  my @return_keys = keys(%return_values);
  if (@return_keys == 1) {
    return $return_values{$return_keys[0]};
  }
  else {
    return \%return_values;
  }
}

#------------------------------------------------------------------------------
# This stuff is identical to the stuff in POE::Session.  Good
# inheritance candidate.

# Create an anonymous sub that, when called, posts an event back to a
# session.  This is highly experimental code to support Tk widgets and
# maybe Event callbacks.  There's no guarantee that this code works
# yet, nor is there one that it'll be here in the next version.

# This maps postback references (stringified; blessing, and thus
# refcount, removed) to parent session IDs.  Members are set when
# postbacks are created, and postbacks' DESTROY methods use it to
# perform the necessary cleanup when they go away.  Thanks to njt for
# steering me right on this one.

my %postback_parent_id;

# I assume that when the postback owner loses all reference to it,
# they are done posting things back to us.  That's when the postback's
# DESTROY is triggered, and referential integrity is maintained.

sub POE::NFA::Postback::DESTROY {
  my $self = shift;
  my $parent_id = delete $postback_parent_id{$self};
  $POE::Kernel::poe_kernel->refcount_decrement( $parent_id, 'postback' );
}

# Create a postback closure, maintaining referential integrity in the
# process.  The next step is to give it to something that expects to
# be handed a callback.

sub postback {
  my ($self, $event, @etc) = @_;
  my $id = {% fetch_id $self %};

  my $postback = bless
    sub {
      $POE::Kernel::poe_kernel->post( $id, $event, [ @etc ], [ @_ ] );
      0;
    }, 'POE::NFA::Postback';

  $postback_parent_id{$postback} = $id;
  $POE::Kernel::poe_kernel->refcount_increment( $id, 'postback' );

  $postback;
}

#==============================================================================
# New methods.

sub goto_state {
  my ($self, $new_state, $entry_event, @entry_args) = @_;
  $POE::Kernel::poe_kernel->post( $self, NFA_EN_GOTO_STATE,
                                  $new_state, $entry_event, @entry_args
                                );
}

sub stop {
  my $self = shift;
  $POE::Kernel::poe_kernel->post( $self, NFA_EN_STOP );
}

sub call_state {
  my ($self, $return_event, $new_state, $entry_event, @entry_args) = @_;
  $POE::Kernel::poe_kernel->post( $self, NFA_EN_PUSH_STATE,
                                  $return_event,
                                  $new_state, $entry_event, @entry_args
                                );
}

sub return_state {
  my ($self, @entry_args) = @_;
  $POE::Kernel::poe_kernel->post( $self, NFA_EN_POP_STATE, @entry_args );
}

###############################################################################
1;

__END__

=head1 NAME

POE::NFA - a Nondeterministic Finite Automaton session

=head1 SYNOPSIS

  use POE::NFA;

  # Define a machine's states, each state's events, and the coderefs
  # that handle each event.
  my %states =
    ( start =>
      { event_one => \&handler_one,
        event_two => \&handler_two,
        ...,
      },
      other_state =>
      { event_n          => \&handler_n,
        event_n_plus_one => \&handler_n_plus_one,
        ...,
      },
      ...,
    );

  # Spawn a state machine, and enter an initial state/event pair.
  POE::NFA->spawn( inline_states => \%states
                 )->goto_state( $start_state, $start_event );

  # Enter a new state without the intention of returning to the
  # current one.
  $machine->goto_state( $new_state, $new_event, @args );

  # Enter a new state with the intention of resuming the current
  # state.  $return_event is the event in the calling state that will
  # be invoked when the called state returns.
  $machine->call_state( $return_event, $new_state, $new_event, @args );

  # Return from the current state to its calling state.  The caller's
  # $return_event (from a previous call_state() call) will be invoked
  # with @returns.
  $machine->return_state( @returns );

  # Force the machine to stop.  The machine also will stop if it runs
  # out of events or event sources (such as filehandles or alarms).
  $machine->stop();

=head1 DESCRIPTION

This document assumes the reader already is familiar with
POE::Session.

POE::NFA instances run a particular kind of session: the
nondeterministic finite automaton (NFA).  NFAs are state machines
which determine the next state to be in by conditions at runtime.
This is different from DFA (deterministic FAs), which have next states
determined for them at compile time.

=head2 Resource Tracking

See POE::Session's documentation.

=head2 Job Control and Family Values

See POE::Session's documentation.

=head2 State Types

See POE::Session's documentation.

Only inline_states are supported at this time.

=head1 POE::NFA Exports

See POE::Session's documentation.

Three exported constants differ from POE::Session:

=over 2

=item MACHINE

This is equivalent to POE::Sesion's SESSION constant.  It holds a
reference to the current state machine, and it's useful for calling
methods on it:

  $_[MACHINE]->goto_state( $next_state, $next_state_entry_event );

=item RUNSTATE

This is equivalent to POE::Session's HEAP constant.  It holds an
anonymous hash reference which POE will guarantee not to touch.  Each
POE::NFA instance gets its own RUNSTATE.  This is a great place to put
machine-scoped data.

=item EVENT

This is equivalent to POE::Session's STATE constant.  It contains the
name of the event which invoked the current event handler.  This is
mainly for the _default state, which may need to know what was
supposed to be invoked.

=back

=head1 POE::NFA's Predefined Events

See POE::Session's documentation on "Predefined States".

POE::NFA defines four events of its own:

=over 2

=item poe_nfa_goto_state

=item poe_nfa_pop_state

=item poe_nfa_push_state

=item poe_nfa_stop

POE::NFA uses these four states internally to manage state transitions
and stopping the machine in an orderly fashion.  There may be others
in the future, and they will all follow the /^poe_nfa_/ naming
convention.  To avoid conflicts, please don't define events beginning
with "poe_nfa_".

=back

=head2 States' Return Values

See POE::Session's documentation.

=head1 PUBLIC METHODS

See POE::Session's documentation.

=over 2

=item ID

Same as with POE::Session.

=item no create method

=item no new method

Instead, POE::NFA uses a spawn() method to spawn a new NFA nistance.
The NFA is defined by one or more hashes that map state/event pairs to
handlers:

  my %machine =
    ( state_1 =>
      { event_1 => \&handler_1,
        event_2 => \&handler_2,
      },
      state_2 =>
      { event_1 => \&handler_3,
        event_2 => \&handler_4,
      },
    );

The same event may exist in different states.  POE::NFA will call the
appropriate handler for the current event in the current state.  For
example, if event_1 is dispatched while the machine is in state_2,
then handler_3 will be called.  This happens because...

  $machine{state_2}->{event_1} = \&handler_3;

POE::NFA's spawn() method currently only accepts C<inline_states> and
C<options>.

=item option OPTION_NAME

=item option OPTION_NAME, OPTION_VALUE

=item option NAME_VALUE_PAIR_LIST

Same as with POE::Session.

=item postback EVENT_NAME, PARAMETER_LIST

Same as with POE::Session.

=item goto_state NEW_STATE

=item goto_state NEW_STATE, ENTRY_EVENT

=item goto_state NEW_STATE, ENTRY_EVENT, EVENT_ARGS

Puts the current machine into a new state.  If an ENTRY_EVENT is
specified, then that event will be called when the machine enters the
new state.  EVENT_ARGS, if specified, will be passed to it via
C<@_[ARG0..$#_]>.

  $_[MACHINE]->goto_state( 'next_state' );
  $_[MACHINE]->goto_state( 'next_state', 'call_this_event' );
  $_[MACHINE]->goto_state( 'next_state', 'call_this_event', @with_these_args );

=item stop

This forces a machine to stop.  It's similar to posting C<_stop> to
the machine, but it does some extra NFA cleanup.  The machine will
also stop gracefully if it runs out of things to do.

C<stop()> is heavy-handed.  It will force resource cleanup.  Circular
references in the machine's RUNSTATE are not POE's responsibility.

  $_[MACHINE]->stop();

=item call_state RETURN_EVENT, NEW_STATE

=item call_state RETURN_EVENT, NEW_STATE, ENTRY_EVENT

=item call_state RETURN_EVENT, NEW_STATE, ENTRY_EVENT, EVENT_ARGS

C<call_state> is similar to C<goto_state>, but the intention is that
the new state will eventually C<return_state> back.  It accepts an
extra parameter, RETURN_EVENT, which is the event in the caller's
state that will be called when the callee's state returns.  That is,
the called state returns to our RETURN_EVENT.

ENTRY_EVENT is the event in the called state that will be called when
the machine enters it.  ENTRY_ARGS are passed to the called state's
event via C<@_[ARG0..$#_]>.

RETURN_EVENT is the event in the B<caller's> state that is invoked
when the B<callee> returns via C<return_state>.  It receives
C<return_state>'s RETURN_ARGS via C<@_[ARG0..$#_]>.

=item return_state

=item return_state RETURN_ARGS

Return to the most recent state which called C<call_state>, optionally
invoking the C<call_state>'s RETURN_EVENT, possibly with RETURN_ARGS.

  $_[MACHINE]->return_state( );
  $_[MACHINE]->return_state( 'success', $something );

=back

=head1 SEE ALSO

Many of POE::NFA's features are taken directly from POE::Session.
Please see L<POE::Session> for more information.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

See POE::Session's documentation.

Object and package states aren't implemented.  Some other stuff is
just lashed together with twine.  POE::NFA needs some more
development.

The documentation is slapped together hastily, too.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
