# $Id$

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

sub SE_NAMESPACE () { 0 }
sub SE_OPTIONS   () { 1 }
sub SE_KERNEL    () { 2 }
sub SE_STATES    () { 3 }

#------------------------------------------------------------------------------

sub new {
  my ($type, @states) = @_;

  my @args;

  croak "sessions no longer require a kernel reference as the first parameter"
    if ((@states > 1) && (ref($states[0]) eq 'POE::Kernel'));

  croak "$type requires a working Kernel"
    unless (defined $POE::Kernel::poe_kernel);

  my $self = bless [ ], $type;
  $self->[SE_NAMESPACE] = { };
  $self->[SE_OPTIONS  ] = { };
  $self->[SE_KERNEL   ] = undef;
  $self->[SE_STATES   ] = { };

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
            $self->register_state($method, $state, $method);
          }
          next;
        }

        elsif (ref($handler) eq 'HASH') {
          while (my ($state_name, $method_name) = each %$handler) {
            $self->register_state($state_name, $state, $method_name);
          }
          next;
        }

        else {
          croak "using something other than a CODEREF for $state handler";
        }
      }
                                        # object states
      if (ref($handler) eq '') {
        $self->register_state($handler, $state, $handler);
        next;
      }

      if (ref($handler) eq 'ARRAY') {
        foreach my $method (@$handler) {
          $self->register_state($method, $state, $method);
        }
        next;
      }

      if (ref($handler) eq 'HASH') {
        while (my ($state_name, $method_name) = each %$handler) {
          $self->register_state($state_name, $state, $method_name);
        }
        next;
      }

      croak "strange reference ($handler) used as an object session method";
    }
    else {
      last;
    }
  }

  if (@states) {
    croak "odd number of events/handlers (missing one or the other?)";
  }

  if (exists $self->[SE_STATES]->{'_start'}) {
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

  my $self = bless [ ], $type;
  $self->[SE_NAMESPACE] = { };
  $self->[SE_OPTIONS  ] = { };
  $self->[SE_KERNEL   ] = undef;
  $self->[SE_STATES   ] = { };

  if (exists $params{'args'}) {
    if (ref($params{'args'}) eq 'ARRAY') {
      push @args, @{$params{'args'}};
    }
    else {
      push @args, $params{'args'};
    }
    delete $params{'args'};
  }

  if (exists $params{options}) {
    if (ref($params{options}) eq 'HASH') {
      $self->[SE_OPTIONS] = $params{options};
    }
    else {
      croak "options for $type constructor is expected to be a HASH reference";
    }
    delete $params{options};
  }

  my @params_keys = keys(%params);
  foreach (@params_keys) {
    my $states = $params{$_};

     if ($_ eq 'inline_states') {
      croak "$_ does not refer to a hash" unless (ref($states) eq 'HASH');

      while (my ($state, $handler) = each(%$states)) {
        croak "inline state '$state' needs a CODE reference"
          unless (ref($handler) eq 'CODE');
        $self->register_state($state, $handler);
      }
    }
    elsif ($_ eq 'package_states') {
      croak "$_ does not refer to an array" unless (ref($states) eq 'ARRAY');
      croak "the array for $_ has an odd number of elements" if (@$states & 1);

      while (my ($package, $handlers) = splice(@$states, 0, 2)) {

        # Array of handlers is passed through as method names.
        if (ref($handlers) eq 'ARRAY') {
          foreach my $method (@$handlers) {
            $self->register_state($method, $package, $method);
          }
        }

        # Hashes of handlers are passed through as key names.
        elsif (ref($handlers) eq 'HASH') {
          while (my ($state, $method) = each %$handlers) {
            $self->register_state($method, $package, $state);
          }
        }

        else {
          croak "states for '$package' needs to be a hash or array ref";
        }
      }
    }
    elsif ($_ eq 'object_states') {
      croak "$_ does not refer to an array" unless (ref($states) eq 'ARRAY');
      croak "the array for $_ has an odd number of elements" if (@$states & 1);

      while (my ($object, $handlers) = each(%$states)) {

        # Array of handlers is passed through as method names.
        if (ref($handlers) eq 'ARRAY') {
          foreach my $method (@$handlers) {
            $self->register_state($method, $object, $method);
          }
        }

        # Hashes of handlers are passed through as key names.
        elsif (ref($handlers) eq 'HASH') {
          while (my ($state, $method) = each %$handlers) {
            $self->register_state($method, $object, $state);
          }
        }

        else {
          croak "states for '$object' needs to be a hash or array ref";
        }

      }
    }
    else {
      croak "unknown $type parameter: $_";
    }
  }

  if (exists $self->[SE_STATES]->{'_start'}) {
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
  # -><- clean out things
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $source_session, $state, $etc) = @_;

  if (exists($self->[SE_OPTIONS]->{'trace'})) {
    warn "$self -> $state\n";
  }

  if (exists $self->[SE_STATES]->{$state}) {
                                        # inline
    if (ref($self->[SE_STATES]->{$state}) eq 'CODE') {
      return &{$self->[SE_STATES]->{$state}}(undef,                   # object
                                            $self,                    # session
                                            $POE::Kernel::poe_kernel, # kernel
                                            $self->[SE_NAMESPACE],    # heap
                                            $state,                   # state
                                            $source_session,          # sender
                                            @$etc                     # args
                                           );
    }
                                        # package and object
    else {
      my ($object, $method) = @{$self->[SE_STATES]->{$state}};
      return
        $object->$method(                          # object
                         $self,                    # session
                         $POE::Kernel::poe_kernel, # kernel
                         $self->[SE_NAMESPACE],    # heap
                         $state,                   # state
                         $source_session,          # sender
                         @$etc                     # args
                        );
    }
  }
                                        # recursive, so it does the right thing
  elsif (exists $self->[SE_STATES]->{'_default'}) {
    return $self->_invoke_state( $source_session,
                                 '_default',
                                 [ $state, $etc ]
                               );
  }
                                        # whoops!  no _default?
  else {
    $! = ENOSYS;
    if (exists $self->[SE_OPTIONS]->{'default'}) {
      warn "\t$self -> $state does not exist (and no _default)\n";
      confess;
    }
    return undef;
  }

  return 0;
}

#------------------------------------------------------------------------------

sub register_state {
  my ($self, $state, $handler, $method) = @_;
  $method = $state unless defined $method;

  if ($handler) {
    # Inline coderef.
    if (ref($handler) eq 'CODE') {
      carp "redefining state($state) for session($self)"
        if ( (exists $self->[SE_OPTIONS]->{'debug'}) &&
             (exists $self->[SE_STATES]->{$state})
           );
      $self->[SE_STATES]->{$state} = $handler;
    }
    # Object or package method.
    elsif ($handler->can($method)) {
      carp "redefining state($state) for session($self)"
        if ( (exists $self->[SE_OPTIONS]->{'debug'}) &&
             (exists $self->[SE_STATES]->{$state})
           );
      $self->[SE_STATES]->{$state} = [ $handler, $method ];
    }
    # Something's wrong.
    else {
      if (ref($handler) eq 'CODE' &&
          exists($self->[SE_OPTIONS]->{'trace'})
      ) {
        carp "$self : state($state) is not a proper ref - not registered"
      }
      else {
        croak "object $handler does not have a '$state' method"
          unless ($handler->can($method));
      }
    }
  }
  else {
    delete $self->[SE_STATES]->{$state};
  }
}

#------------------------------------------------------------------------------

#sub ID {
#  my $self = shift;
#  $POE::Kernel::poe_kernel->ID_session_to_id($self);
#}

#------------------------------------------------------------------------------

sub option {
  my $self = shift;
  my %return_values;

  while (@_ >= 2) {
    my ($flag, $value) = splice(@_, 0, 2);
    $flag = lc($flag);
                                        # set the value, if defined
    if (defined $value) {
                                        # booleanize some handy aliases
      ($value = 1) if ($value =~ /^(on|yes|true)$/i);
      ($value = 0) if ($value =~ /^(no|off|false)$/i);

      $return_values{$flag} = $self->[SE_OPTIONS]->{$flag};
      $self->[SE_OPTIONS]->{$flag} = $value;
    }
                                        # remove the value, if undefined
    else {
      $return_values{$flag} = delete $self->[SE_OPTIONS]->{$flag};
    }
  }
                                        # only one option?  fetch it.
  if (@_) {
    my $flag = lc(shift);
    $return_values{$flag} =
      ( exists($self->[SE_OPTIONS]->{$flag})
        ? $self->[SE_OPTIONS]->{$flag}
        : undef
      );
  }
                                        # only one option?  return it
  my @return_keys = keys(%return_values);
  if (@return_keys == 1) {
    return $return_values{$return_keys[0]};
  }
  else {
    return \%return_values;
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - POE State Machine

=head1 SYNOPSIS

  # Original inline session constructor:
  new POE::Session(
    name1 => \&name1_handler, # \&name1_handler is the "name1" state
    name2 => sub { ... },     # anonymous is the "name2" state
    \@start_args,             # ARG0..ARGn for the the _start state
  );

  # Original package session constructor:
  new POE::Session(
    $package, [ 'name1',      # $package->name1() is the "name1" state
                'name2',      # $package->name2() is the "name2" state
              ],
    \@start_args,             # ARG0..ARGn for the start _start state
  );

  # Original object session constructor:
  my $object1 = new SomeObject(...);
  my $object2 = new SomeOtherObject(...);
  new POE::Session(
    # $object1->name1() is the "name1" state
    # $object1->name2() is the "name2" state
    $object1 => [ 'name1', 'name2' ],
    # $object2->name1() is the "name3" state
    # $object2->name2() is the "name3" state
    $object2 => [ 'name3', 'name4' ],
    \@start_args,             # ARG0..ARGn for the _start state
  );

  # New constructor:
  create POE::Session(
    # ARG0..ARGn for the session's _start handler
    args => \@args,
    inline_states  => { state1 => \&handler1,
                        state2 => \&handler2,
                        ...
                      },
    object_states  => [ $objref1 => \@methods1,
                        $objref2 => { state_name_1 => 'method_name_1',
                                      state_name_2 => 'method_name_2',
                                    },
                        ...
                      ],
    package_states => [ $package1 => \@function_names_1,
                        $package2 => { state_name_1 => 'method_name_1',
                                       state_name_2 => 'method_name_2',
                                     },
                        ...
                      ],
    options => \%options,
  );

  # Set or clear some session options:
  $session->option( trace => 1, default => 1 );

=head1 DESCRIPTION

(Note: Session constructors were changed in version 0.06.  Processes
no longer support multiple kernels.  This made the $kernel parameter
to session constructors obsolete, so it was removed.)

POE::Session is a generic state machine class.  Session instances are
driven by state transition events, dispatched by POE::Kernel.

Sessions are POE's basic, self-contained units of program execution.
They are equivalent to operating system processes or threads.  As part
of their creation, sessions register themselves with the process'
Kernel instance.  The kernel will keep track of their resources, and
perform garbage collection at appropriate times.

=head1 EXPORTED CONSTANTS

POE::Session exports constants for states' parameters.  The constants
are discussed down in the STATE PARAMETERS section.

=head1 PUBLIC METHODS

=over 4

=item *

new

POE::Session::new() is the original, highly overloaded constructor
style.  It creates a new POE::Session instance, populated with states
given as its parameters.

A reference to the new session will be given to the process' Kernel
instance.  The kernel will manage the session and its resources, and
it expects perl to destroy the session when it releases its reference.

The constructor will also return a reference to the new session.  This
reference may be used directly, but keeping a copy of it will prevent
perl from garbage collecting the session when the kernel is done with
it.  Some uses for the session reference include posting "bootstrap"
events to the session or manipulating the session's options with its
option() method.

Some people consider the new() constructor awkward, or "action at a
distance".  POE provides a semantically "sweeter" Kernel method,
POE::Kernel::session_create() for these people.  Please note, however,
that session_create is depreciated as of version 0.06_09, since
POE::Session has become a proper object.

POE::Session::new() accepts pairs of parameters, with one exception.
The first parameter in the pair determines the pair's type.  The pairs
may be used interchangeably:

Inline states are described by a scalar and a coderef.  The scalar is
a string containing the state's name, which is also the name of the
event that will trigger the state.  The coderef is the Perl subroutine
that will be called to handle the event.

  new POE::Session( event_name => \&state_handler );

Object states are described by an object reference and a reference to
an array of method names.  The named methods will be invoked to handle
similarly named events.

  my $object = new Object;
  new POE::Session( $object => [ qw(method1 method2 method3) ] );

Package states are described by a package name and a reference to an
array of subroutine names.  The subroutines will handle events with
the same names.  If two or more packages are listed in the
constructor, and the packages have matching subroutine names, then the
last one wins.

  new POE::Session( 'Package' => [ 'sub1', 'sub2', 'sub3' ] );

Sessions may use any combination of Inline, Object and Package states:

  my $object = new Object;
  new POE::Session( event_name => \&state_handler,
                    $object   => [ qw(method1 method2 method3) ],
                    'Package' => [ 'sub1', 'sub2', 'sub3' ]
                  );

There is one parameter that isn't part of a pair.  It is a stand-alone
array reference.  The contents of this arrayref are sent as arguments
to the session's B<_start> state.

=item *

create

POE::Session::create() is a new constructor style.  It does not use
parameter overloading and DWIM to discern different session types.  It
also supports the ability to set options in the constructor, unlike
POE::Session::new().

Please see the SYNOPSIS for create() usage.

=item *

option

POE::Session::option() stores, fetches or removes a session's option.
Options are similar to environment variables.

The option() method's behavior changed in version 0.06_09.  It now
supports fetching option values without changing or deleting the
option.

  $session->option( 'name1' );         # Fetches option 'name1'
  $session->option( name2 => undef );  # Deletes option 'name2'
  $session->option( name3 => 1,        # Sets name3...
                    name4 => 2         # ... and name4.
                  );

Actually, option() always returns the values of the options its
passed.  If more than one option is supplied in the parameters, then
option() returns a reference to a hash containing names and previous
values.  If a single option is specified, then option() returns its
value as a scalar.

The option() method can only accept more than one option name while
storing or deleting.  POE::Session::option() only changes the options
that are present as parameters.  Unspecified options are left alone.

For example:

  $session->option( trace => 1, default => 0 );

Logical values may be sent as either 1, 0, 'on', 'off', 'yes', 'no',
'true' or 'false'.  Stick with 1 and 0, though, because somebody
somewhere won't like the value translation and will request that it be
removed.

These are the options that POE currently uses internally.  Others may
be added later.

=over 2

=item *

trace

Accepts a logical true/false value.  This option enables or disables a
trace of events as they're dispatched to states.

=item *

default

Accepts a logical true/false value.  When the "default" option is
enabled, POE will warn and confess about events that arrive but can't
be dispatched.  Note: The "default" option will not do anything if the
session has a B<_default> state, because then every event can be
dispatched.

=back

=item *

ID

POE::Session::ID() returns this session's unique ID, as maintained by
POE::Kernel.  It's a shortcut for $kernel->ID_session_to_id($session).

=back

=head1 STATE PARAMETERS

State parameters changed in version 0.06.  Before 0.06, inline
handlers received different parameters than object and package
handlers.  The call signatures have been unified in version 0.06.
This breaks programs written with POE 0.05 or earlier.  Thankfully,
there aren't many.

To prevent future breakage, POE::Session now exports constants for
parameters' offsets into @_.  Programs that use the constants are
guaranteed not to break whenever states' call signatures change.  Or,
if parameters are removed, programs will break at compile time rather
than mysteriously failing at runtime.

Parameters may be used discretely:

  $_[KERNEL]->yield('next_state');

If several parameters are needed multiple times, it may be easier (and
faster) to assign them to lexicals all at once with an array slice:

  my ($kernel, $operation, $errnum, $errstr) =
     @_[KERNEL, ARG0, ARG1, ARG2];

The parameter constants are:

=over 4

=item *

OBJECT

The value in $_[OBJECT] is dependent on how the state was defined.  It
is undef for inline states.  For object states, it contains a
reference to the object that owns the method being called.  For
package states, it contains the name of the package the subroutine
exists in.

=item *

KERNEL

$_[KERNEL] is a reference to the kernel that is managing this session.
It exists for times when $poe_kernel isn't available.  $_[KERNEL] is
recommended over $poe_kernel in states.  They may be different at some
point.

=item *

SESSION

$_[SESSION] is a reference to the current POE session.  It is included
mainly as a parameter to POE::Kernel methods, and for manipulating
session options.

=item *

HEAP

$_[HEAP] is a reference to a hash set aside for each session to store
its global data.  Information stored in the heap will be persistent
between states, for the life of the session.

POE will destroy the heap when its session stops, but it will not walk
the heap and make sure that circular references are broken.
Developers are expected to do any special heap cleanup in the
session's B<_stop> state.

Support for using $_[HEAP] (formerly known as $me or $namespace) as an
alias for $_[SESSION] in Kernel method calls is depreciated, starting
in version 0.06.  It will be removed after version 0.07.

=item *

STATE

$_[STATE] is the name of the state being invoked.  In most cases, this
will be the name of the event that caused this handler to be called.
In some cases though, most notably with B<_default> and B<_signal>,
the state being invoked may not match the event being dispatched.
(Predictably enough, it will be _default or _signal).  You can find
out the original event name for B<_default> (see the B<_default>
event's description).  The B<_signal> event includes the signal name
that caused it to be posted.

=item *

SENDER

$_[SENDER] is a reference to the session that sent the event.  It is
suitable as a destination for responses.  Please be careful about
deadlocks is using POE::Kernel::call() in both directions.

=item *

ARG0..ARG9

@_[ARG0..ARG9] are the first ten elements of @args, as passed to the
POE::Kernel post(), call(), yield(), alarm() and delay() methods.  If
more than ten items are needed, they may be referenced as
$_[ARG9+1..], but it would be more efficient to pass them all as an
array reference in $_[ARG0].

Another way to grab the arguments, no matter how many there are, is:

  my @args = @_[ARG0..$#_];

=back

=head1 CUSTOM EVENTS AND PARAMETERS

Events that aren't prefixed with leading underscores may have been
defined by the state machines themselves or by Wheel instances the
machines are using.

In almost all these cases, the event name should be mapped to a state
in the POE::Session constructor.  Finding the event's source may be
more difficult.  It could come from a Wheel in the same session, or
one of the &kernel calls.  In the case of inter-session communication,
it may even come from outside the session.

=head1 PREDEFINED EVENTS AND PARAMETERS

POE reserves some event names for internal and standard use.  All its
predefined events begin with an underscore, and future ones will too.
It may be wise to avoid leading underscores in your own event names.

Every predefined event is accompanied by the standard OBJECT, KERNEL,
SESSION, HEAP, STATE and SENDER parameters.

=over 4

=item *

_start

Sessions can't start running until the kernel knows they exist.  After
the kernel registers a session, it sends a B<_start> event to let it
know it's okay to begin.  POE requires every state machine to have a
special B<_start> state.  Otherwise, how would they know when to
start?

SENDER contains a reference to the new session's parent session.

ARG0..ARG9 contain parameters as they were given to the session's
constructor.  See POE::Session::new() and POE::Session::create() for
more information.

=item *

_stop

Sessions receive B<_stop> events when it is time for them to stop.
B<_stop> is dispatched to sessions just before the kernel destroys
them.  The B<_stop> state commonly contains special destructor code,
possibly to clean up things that the kernel doesn't know about.

Sessions stop when they run out of pending state transition events and
don't hold resources to create new ones.  Event-generating resources
include selects (filehandle monitors), child sessions, and aliases.

The kernel's run() method will return if all its sessions stop.

SENDER is the session that posted the B<_stop> event.  In the case of
resource starvation, this is the KERNEL.

ARG0..ARG9 are empty in the case of resource starvation.

=item *

_signal

POE sets handlers for most of the signals in %SIG.  The only
exceptions are things which might exist in %SIG but probably
shouldn't.  POE will not register signal handlers for SIGRTMIN, for
example, because doing that breaks Perl on some HP-UX systems.

Signals are propagated to child sessions first.  Since every session
is a descendent of the kernel, posting signals to the kernel
guarantees that every session receives them.

POE does not yet magically solve Perl's problems with signals.
Namely, perl tends to dump core if it keeps receiving signals.  That
has a detrimental effect on programs that expect long uptimes.

There are a few kinds of signals.  The kernel processes each kind
differently:

SIGPIPE causes a B<_signal> event to be posted directly to the session
that is running when the signal was received.  ARG0 contains the
signal name, as it appears in %SIG.

The handler for SIGCHLD and SIGCLD calls wait() to acquire the dying
child's process ID and result code.  If the child PID is valid, a
B<_signal> event will be posted to all sessions.  ARG0 will contain
CHLD regardless of the actual signal name.  ARG1 contains the child
PID, and ARG2 contains the contents of $? just after the wait() call.

All other signals cause a B<_signal> event to be posted to all
sessions.  ARG0 contains the signal name as it appears in %SIG.

SIGWINCH is ignored.  Resizing an xterm causes a bunch of these,
quickly killing perl.

=item *

_garbage_collect

The B<_garbage_collect> event tells the kernel to check a session's
resources and stop it if none are left.  It never is dispatched to a
session.  This was added to delay garbage collection checking for new
sessions.  This delayed garbage collection gives parent sessions a
chance to interact with their newly-created children.

=item *

_parent

The B<_parent> event lets child sessions know that they are about to
be orphaned and adopted.  It tells each child session who their old
parent was and who their new parent is.

SENDER should always equal KERNEL.  If not, the event was spoofed by
another session.  ARG0 is the session's old parent; ARG1 is the
session's new one.

=item *

_child

The B<_child> event is sent to parent sessions when they acquire or
lose child sessions.  B<_child> is dispatched to parents after the
children receive B<_start> or before they receive B<_stop>.

SENDER should always equal KERNEL.  If not, the event was spoofed by
another session.

ARG0 indicates what is happening to the child.  It is 'gain' if the
session is a grandchild being given by a dying child.  It is 'lose' if
the session is itself a dying child.  It is 'create' if the child was
created by the current session.

ARG1 is a reference to the child session.  It will still be valid,
even if the child is in its death throes.

ARG2 is only valid when ARG0 is 'create'.  It contains the return
value of the child's B<_start> state.  See ABOUT STATES' RETURN VALUES
for more information about states' return values.

=item *

Select Events

Select events are generated by POE::Kernel when selected file handles
become active.  They have no default names.

ARG0 is the file handle that had activity.

=item *

_default

The B<_default> state is invoked whenever a session receives an event
for which it does not have a registered state.  If the session doesn't
have a B<_default> state, then the event will be discarded.  If the
session's B<default> option is true, then POE will carp and confess
about the discarded event.

ARG0 holds the original event's name.  ARG1 holds a reference to the
original event's parameters.

If B<_default> catches a B<_signal> event, its return value will be
used to determine if the signal was handled.  This may make some
programs difficult to stop.  Please see the description for the
B<_signal> event for more information.

The B<_default> state can be used to catch misspelled events, but
$session->option('default',1) may be better.

=back

=head1 ABOUT STATES' RETURN VALUES

States are evaluated in a scalar context.  States that must return
more than one value should return an arrayref instead.

Signal handlers tell POE whether or not a signal was handled by
returning a logical true or false value.  See the description for the
B<_signal> state for more information.

POE::Kernel::call() will return whatever a called state returns.  See
the description of POE::Kernel::call() for more information.

If a state returns a reference to an object in the POE namespace (or
any namespace starting with POE::), then that reference is immediately
stringified.  This is done to prevent "blessing bleed" (see the
Changes file) from interfering with POE's and Perl's garbage
collection.  The code that checks for POE objects does not look inside
data passed by reference-- it's just there to catch accidents, like:

  sub _stop {
    delete $_[HEAP]->{'readwrite wheel'};
    # reference to the readwrite wheel is implicitly returned
  }

That accidentally returns a reference to a POE::Wheel::ReadWrite
object.  If the reference was not stringified, it would delay the
wheel's destruction until after the session stopped.  The wheel would
try to remove its states from the nonexistent session, and the program
would crash.

=head1 SEE ALSO

POE; POE::Kernel

=head1 BUGS

The documentation for POE::Session::create() is fairly nonexistent.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
