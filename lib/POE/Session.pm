# $Id$

package POE::Session;

use strict;
use Carp;
use POSIX qw(ENOSYS);

use POE::Preprocessor;

enum SE_NAMESPACE SE_OPTIONS SE_STATES

# I had made these constant subs, but you can't use constant subs as
# hash keys, so they're POE::Preprocessor constants.  Blargh!

const CREATE_ARGS     'args'
const CREATE_OPTIONS  'options'
const CREATE_INLINES  'inline_states'
const CREATE_PACKAGES 'package_states'
const CREATE_OBJECTS  'object_states'

const OPT_TRACE   'trace'
const OPT_DEBUG   'debug'
const OPT_DEFAULT 'default'

const EN_START   '_start'
const EN_DEFAULT '_default'

# Define some debugging flags for subsystems, unless someone already
# has defined them.
BEGIN {
  defined &DEB_DESTROY or eval 'sub DEB_DESTROY () { 0 }';
}

#------------------------------------------------------------------------------

macro make_session {
  my $self =
    bless [ { }, # SE_NAMESPACE
            { }, # SE_OPTIONS
            { }, # SE_STATES
          ], $type;
}

macro validate_kernel {
  croak "$type requires a working Kernel"
    unless defined $POE::Kernel::poe_kernel;
}

macro validate_state {
  carp "redefining state($name) for session(", {% fetch_id $self %}, ")"
    if ( (exists $self->[SE_OPTIONS]->{OPT_DEBUG}) &&
         (exists $self->[SE_STATES]->{$name})
       );
}

macro fetch_id (<whence>) {
  $POE::Kernel::poe_kernel->ID_session_to_id(<whence>)
}

macro verify_start_state {
  # Verfiy that the session has a special start state, otherwise how
  # do we know what to do?  Don't even bother registering the session
  # if the start state doesn't exist.

  if (exists $self->[SE_STATES]->{EN_START}) {
    $POE::Kernel::poe_kernel->session_alloc($self, @args);
  }
  else {
    carp "discarding session ", {% fetch_id $self %}, " - no '_start' state";
    $self = undef;
  }
}

# MACROS END <-- search tag for editing

#------------------------------------------------------------------------------
# Export constants into calling packages.  This is evil; perhaps
# EXPORT_OK instead?

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

use Exporter;
@POE::Session::ISA = qw(Exporter);
@POE::Session::EXPORT = qw( OBJECT SESSION KERNEL HEAP STATE SENDER
                            ARG0 ARG1 ARG2 ARG3 ARG4 ARG5 ARG6 ARG7 ARG8 ARG9
                          );

#------------------------------------------------------------------------------
# Classic style constructor.  This is unofficially depreciated in
# favor of the create() constructor.  Its DWIM nature does things
# people don't mean, so create() is a little more explicit.

sub new {
  my ($type, @states) = @_;

  my @args;

  croak "sessions no longer require a kernel reference as the first parameter"
    if ((@states > 1) && (ref($states[0]) eq 'POE::Kernel'));

  {% validate_kernel %}
  {% make_session %}

  # Scan all arguments.  It mainly expects them to be in pairs, except
  # for some, uh, exceptions.

  while (@states) {

    # If the first of a hypothetical pair of arguments is an array
    # reference, then this arrayref is the _start state's arguments.
    # Pull them out and look for another pair.

    if (ref($states[0]) eq 'ARRAY') {
      if (@args) {
        croak "$type must only have one block of arguments";
      }
      push @args, @{$states[0]};
      shift @states;
      next;
    }

    # If there is a pair of arguments (or more), then we can continue.
    # Otherwise this is done.

    if (@states >= 2) {

      # Pull the argument pair off the constructor parameters.

      my ($first, $second) = splice(@states, 0, 2);

      # Check for common problems.

      unless ((defined $first) && (length $first)) {
        carp "depreciated: using an undefined state name";
      }

      if (ref($first) eq 'CODE') {
        croak "using a code reference as an state name is not allowed";
      }

      # Try to determine what sort of state it is.  A lot of WIM is D
      # here.  It was nifty at the time, but it's gotten a little
      # scary as POE has evolved.

      # The first parameter has no blessing, so it's either a plain
      # inline state or a package state.

      if (ref($first) eq '') {

        # The second parameter is a coderef, so it's a plain old
        # inline state.

        if (ref($second) eq 'CODE') {
          $self->register_state($first, $second);
          next;
        }

        # If the second parameter in the pair is a list reference,
        # then this is a package state invocation.  Explode the list
        # reference into separate state registrations.  Each state is
        # a package method with the same name.

        elsif (ref($second) eq 'ARRAY') {
          foreach my $method (@$second) {
            $self->register_state($method, $first, $method);
          }

          next;
        }

        # If the second parameter in the pair is a hash reference,
        # then this is a mapped package state invocation.  Explode the
        # hash reference into separate state registrations.  Each
        # state is mapped to a package method with a separate
        # (although not guaranteed to be different) name.

        elsif (ref($second) eq 'HASH') {
          while (my ($first_name, $method_name) = each %$second) {
            $self->register_state($first_name, $first, $method_name);
          }
          next;
        }

        # Something unexpected happened.

        else {
          croak( "can't determine what you're doing with '$first'; ",
                 "perhaps you should use POE::Session->create"
               );
        }
      }

      # Otherwise the first parameter is a blessed something, and
      # these will be object states.  The second parameter is a plain
      # scalar of some sort, so we'll register the state directly.

      if (ref($second) eq '') {
        $self->register_state($second, $first, $second);
        next;
      }

      # The second parameter is a list reference; we'll explode it
      # into several state registrations, each mapping the state name
      # to a similarly named object method.

      if (ref($second) eq 'ARRAY') {
        foreach my $method (@$second) {
          $self->register_state($method, $first, $method);
        }
        next;
      }

      # The second parameter is a hash reference; we'll explode it
      # into several aliased state registrations, each mapping a state
      # name to a separately (though not guaranteed to be differently)
      # named object method.

      if (ref($second) eq 'HASH') {
        while (my ($first_name, $method_name) = each %$second) {
          $self->register_state($first_name, $first, $method_name);
        }
        next;
      }

      # Something unexpected happened.

      croak( "can't determine what you're doing with '$second'; ",
             "perhaps you should use POE::Session->create"
           );
    }

    # There are fewer than 2 parameters left.

    else {
      last;
    }
  }

  # If any parameters are left, then there's a syntax error in the
  # constructor parameter list.

  if (@states) {
    croak "odd number of parameters in POE::Session->new call";
  }

  {% verify_start_state %}

  $self;
}

#------------------------------------------------------------------------------
# New style constructor.  This uses less DWIM and more DWIS, and it's
# more comfortable for some folks; especially the ones who don't quite
# know WTM.

sub create {
  my ($type, @params) = @_;
  my @args;

  # We treat the parameter list strictly as a hash.  Rather than dying
  # here with a Perl error, we'll catch it and blame it on the user.

  if (@params & 1) {
    croak "odd number of states/handlers (missing one or the other?)";
  }
  my %params = @params;

  {% validate_kernel %}
  {% make_session %}

  # Process _start arguments.  We try to do the right things with what
  # we're given.  If the arguments are a list reference, map its items
  # to ARG0..ARGn; otherwise make whatever the heck it is be ARG0.

  if (exists $params{CREATE_ARGS}) {
    if (ref($params{CREATE_ARGS}) eq 'ARRAY') {
      push @args, @{$params{CREATE_ARGS}};
    }
    else {
      push @args, $params{CREATE_ARGS};
    }
    delete $params{CREATE_ARGS};
  }

  # Process session options here.  Several options may be set.

  if (exists $params{CREATE_OPTIONS}) {
    if (ref($params{CREATE_OPTIONS}) eq 'HASH') {
      $self->[SE_OPTIONS] = $params{CREATE_OPTIONS};
    }
    else {
      croak "options for $type constructor is expected to be a HASH reference";
    }
    delete $params{CREATE_OPTIONS};
  }

  # Get down to the business of defining states.

  while (my ($param_name, $param_value) = each %params) {

    # Inline states are expected to be state-name/coderef pairs.

    if ($param_name eq CREATE_INLINES) {
      croak "$param_name does not refer to a hash"
        unless (ref($param_value) eq 'HASH');

      while (my ($state, $handler) = each(%$param_value)) {
        croak "inline state '$state' needs a CODE reference"
          unless (ref($handler) eq 'CODE');
        $self->register_state($state, $handler);
      }
    }

    # Package states are expected to be package-name/list-or-hashref
    # pairs.  If the second part of the pair is a listref, then the
    # package methods are expected to be named after the states
    # they'll handle.  If it's a hashref, then the keys are state
    # names and the values are package methods that implement them.

    elsif ($param_name eq CREATE_PACKAGES) {
      croak "$param_name does not refer to an array"
        unless (ref($param_value) eq 'ARRAY');
      croak "the array for $param_name has an odd number of elements"
        if (@$param_value & 1);

      while (my ($package, $handlers) = splice(@$param_value, 0, 2)) {

        # -><- What do we do if the package name has some sort of
        # blessing?  Do we use the blessed thingy's package, or do we
        # maybe complain because the user might have wanted to make
        # object states instead?

        # An array of handlers.  The array's items are passed through
        # as both state names and package method names.

        if (ref($handlers) eq 'ARRAY') {
          foreach my $method (@$handlers) {
            $self->register_state($method, $package, $method);
          }
        }

        # A hash of handlers.  Hash keys are state names; values are
        # package methods to implement them.

        elsif (ref($handlers) eq 'HASH') {
          while (my ($state, $method) = each %$handlers) {
            $self->register_state($state, $package, $method);
          }
        }

        else {
          croak "states for '$package' needs to be a hash or array ref";
        }
      }
    }

    # Object states are expected to be object-reference/
    # list-or-hashref pairs.  They must be passed to &create in a list
    # reference instead of a hash reference because making object
    # references into hash keys loses their blessings.

    elsif ($param_name eq CREATE_OBJECTS) {
      croak "$param_name does not refer to an array"
        unless (ref($param_value) eq 'ARRAY');
      croak "the array for $param_name has an odd number of elements"
        if (@$param_value & 1);

      while (@$param_value) {
        my ($object, $handlers) = splice @$param_value => 0, 2;

        # Verify that the object is an object.  This may catch simple
        # mistakes; or it may be overkill since it already checks that
        # $param_value is a listref.

        carp "'$object' is not an object" unless ref($object);

        # An array of handlers.  The array's items are passed through
        # as both state names and object method names.

        if (ref($handlers) eq 'ARRAY') {
          foreach my $method (@$handlers) {
            $self->register_state($method, $object, $method);
          }
        }

        # A hash of handlers.  Hash keys are state names; values are
        # package methods to implement them.

        elsif (ref($handlers) eq 'HASH') {
          while (my ($state, $method) = each %$handlers) {
            $self->register_state($state, $object, $method);
          }
        }

        else {
          croak "states for '$object' needs to be a hash or array ref";
        }

      }
    }

    else {
      croak "unknown $type parameter: $param_name";
    }
  }

  {% verify_start_state %}

  $self;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;

  # Session's data structures are destroyed through Perl's usual
  # garbage collection.  DEB_DESTROY here just shows what's in the
  # session before the destruction finishes.

  DEB_DESTROY and do {
    print "----- Session $self Leak Check -----\n";
    print "-- Namespace (HEAP):\n";
    foreach (sort keys (%{$self->[SE_NAMESPACE]})) {
      print "   $_ = ", $self->[SE_NAMESPACE]->{$_}, "\n";
    }
    print "-- Options:\n";
    foreach (sort keys (%{$self->[SE_OPTIONS]})) {
      print "   $_ = ", $self->[SE_OPTIONS]->{$_}, "\n";
    }
    print "-- States:\n";
    foreach (sort keys (%{$self->[SE_STATES]})) {
      print "   $_ = ", $self->[SE_STATES]->{$_}, "\n";
    }
  };
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $source_session, $state, $etc, $file, $line) = @_;

  # Trace the state invocation if tracing is enabled.

  if (exists($self->[SE_OPTIONS]->{OPT_TRACE})) {
    warn {% fetch_id $self %}, " -> $state\n";
  }

  # The desired destination state doesn't exist in this session.
  # Attempt to redirect the state transition to _default.

  unless (exists $self->[SE_STATES]->{$state}) {

    # There's no _default either; redirection's not happening today.
    # Drop the state transition event on the floor, and optionally
    # make some noise about it.

    unless (exists $self->[SE_STATES]->{EN_DEFAULT}) {
      $! = ENOSYS;
      if (exists $self->[SE_OPTIONS]->{OPT_DEFAULT}) {
        warn( "a '$state' state was sent from $file at $line to session ",
              {% fetch_id $self %}, ", but session ", {% fetch_id $self %},
              " has neither that state nor a _default state to handle it\n"
            );
      }
      return undef;
    }

    # If we get this far, then there's a _default state to redirect
    # the transition to.  Trace the redirection.

    if (exists($self->[SE_OPTIONS]->{OPT_TRACE})) {
      warn {% fetch_id $self %}, " -> $state redirected to _default\n";
    }

    # Transmogrify the original state transition into a corresponding
    # _default invocation.

    $etc   = [ $state, $etc ];
    $state = EN_DEFAULT;
  }

  # If we get this far, then the state can be invoked.  So invoke it
  # already!

  # Inline states are invoked this way.

  if (ref($self->[SE_STATES]->{$state}) eq 'CODE') {
    return &{$self->[SE_STATES]->{$state}}
      ( undef,                          # object
        $self,                          # session
        $POE::Kernel::poe_kernel,       # kernel
        $self->[SE_NAMESPACE],          # heap
        $state,                         # state
        $source_session,                # sender
        @$etc                           # args
      );
  }

  # Package and object states are invoked this way.

  my ($object, $method) = @{$self->[SE_STATES]->{$state}};
  return
    $object->$method                    # package/object (implied)
      ( $self,                          # session
        $POE::Kernel::poe_kernel,       # kernel
        $self->[SE_NAMESPACE],          # heap
        $state,                         # state
        $source_session,                # sender
        @$etc                           # args
      );
}

#------------------------------------------------------------------------------
# Add, remove or replace states in the session.

sub register_state {
  my ($self, $name, $handler, $method) = @_;
  $method = $name unless defined $method;

  # There is a handler, so try to define the state.  This replaces an
  # existing state.

  if ($handler) {

    # Coderef handlers are inline states.

    if (ref($handler) eq 'CODE') {
      {% validate_state %}
      $self->[SE_STATES]->{$name} = $handler;
    }

    # Non-coderef handlers may be package or object states.  See if
    # the method belongs to the handler.

    elsif ($handler->can($method)) {
      {% validate_state %}
      $self->[SE_STATES]->{$name} = [ $handler, $method ];
    }

    # Something's wrong.  This code also seems wrong, since
    # ref($handler) can't be 'CODE'.

    else {
      if ( (ref($handler) eq 'CODE') and
           exists($self->[SE_OPTIONS]->{OPT_TRACE})
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
    delete $self->[SE_STATES]->{$name};
  }
}

#------------------------------------------------------------------------------
# Return the session's ID.  This is a thunk into POE::Kernel, where
# the session ID really lies.

sub ID {
  {% fetch_id shift %}
}

#------------------------------------------------------------------------------
# Set or fetch session options.

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

      $return_values{$flag} = $self->[SE_OPTIONS]->{$flag};
      $self->[SE_OPTIONS]->{$flag} = $value;
    }

    # Remove the option if the value is undefined.

    else {
      $return_values{$flag} = delete $self->[SE_OPTIONS]->{$flag};
    }
  }

  # If only one option is left, then there's no value to set, so we
  # fetch its value.

  if (@_) {
    my $flag = lc(shift);
    $return_values{$flag} =
      ( exists($self->[SE_OPTIONS]->{$flag})
        ? $self->[SE_OPTIONS]->{$flag}
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

sub POE::Session::Postback::DESTROY {
  my $self = shift;
  my $parent_id = delete $postback_parent_id{$self};
  $POE::Kernel::poe_kernel->refcount_decrement( $parent_id, 'postback' );
}

# Create a postback closure, maintaining referential integrity in the
# process.  The next step is to give it to something that expects to
# be handed a callback.

sub postback {
  my ($self, $event, @etc) = @_;

  my $postback = bless
    ( sub {
        my $id = {% fetch_id $self %};
        $POE::Kernel::poe_kernel->post( $id, $event, \@etc, [ @_ ] );
      },
      'POE::Session::Postback'
    );

  $postback_parent_id{$postback} = {% fetch_id $self %};
  $POE::Kernel::poe_kernel->refcount_increment( {% fetch_id $self %},
                                                'postback'
                                              );
  $postback;
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - a POE thread of execution

=head1 SYNOPSIS

The POE manpage includes and describes a sample program.

  # Import POE::Session constants.
  use POE::Session;

POE::Session has two different constructors.  The older one, new(), is
quite DWIMmy.  This was clever to begin with, but it has impeded
understanding and maintainability as time has passed, and now it's
somewhat depreciated.  The newer constructor, create(), is very DWIS,
which enables it to validate its parameters better and accept more of
them.  The create() constructor is therefore recommended over new().

  # This is the older, more DWIMmy session constructor.
  POE::Session->new(

    # These are called inline states because they originally were
    # defined using inline coderefs.
    state_one => \&coderef_one,
    state_two => sub { ... },

    # Plain object and package states map state names to identical
    # method names.  For example, $object_one->state_three() is called
    # to handle 'state_three':
    $object_one  => [ 'state_three', 'state_four',  'state_five'  ],
    $package_one => [ 'state_six',   'state_seven', 'state_eight' ],

    # Mapped object and package states may have different method names
    # for their state names.  For example, $package_two->method_ten()
    # is called to handle 'state_ten'.  Mapped states are defined by
    # hashrefs, which in turn define the relationships between state
    # names and their handlers' methods.
    $object_two  => { state_nine => 'method_nine', ... },
    $package_two => { state_ten  => 'method_ten', ... },

    # A list reference by itself indicates arguments to pass to the
    # session's _start state.  This can occur anywhere in the
    # constructor's parameters.
    \@start_args,
  );

  # This is the newer, more explicit constructor.
  POE::Session->create(

    # The list 'args' refers to is passed as arguments to the
    # session's special _start state.
    args => [ argument_zero, argument_one, ... ],

    # "Inline" states are named as such because they can (and
    # originally were) defined with inline anonymous coderefs.
    inline_states =>
      { state_one => \&coderef_one,
        state_two => sub { ... },
      },

    # These plain and aliased object states match the ones shown in
    # POE::Session->new's synopsis.  Note, though, that the right side
    # of the => operator is a list reference; not a hash reference.
    # 'object_states' is associated with a list reference so that
    # object references aren't stringified when they would become hash
    # keys.
    object_states =>
    [ $object_one => [ 'state_three', 'state_four', 'state_five' ],
      $object_two => { state_nine => 'method_nine' },
    ],

    # These plain and aliased package states match the ones shown in
    # POE::Session->new's synopsis.  'package_states' is associated
    # with a list reference for consistency with 'object_states'.
    package_states =>
    [ $package_one => [ 'state_six', 'state_seven', 'state_eight' },
      $package_two => { state_ten => 'method_ten' },
    ],

    # create() has one feature over new(), which is somewhat
    # depreciated and falling behind in features.  create() allows
    # session options to be set at creation time.  'options' refers to
    # a hash containing option names and initial values.
    options => \%options,
  );

Other methods:

  # Retrieve a session's unique identifier.
  $session_id = $session->ID;

  # Set or clear session options.
  $session->option( trace => 1, default => 1 );
  $session->option( trace );

  # Create a postback.  This is an anonymous coderef that posts an
  # event back to the current session when called.  It's part of POE's
  # cooperation interface to other event loops and resource watchers.
  $postback_coderef = $session->postback( $state_name, @state_args );
  &{ $postback_coderef }( @additional_args );

=head1 DESCRIPTION

POE::Session is a framework that binds discrete states into machines.
It accepts states as constructor parameters, wraps them up, and
notifies POE::Kernel that it's ready to begin.  The Kernel registers
the it for resource management, then invokes its special _start state
to let it know it's cleared for take-off.

As sessions run, they post their state transitions through the
Kernel's FIFO event queue.  The Kernel dispatches the transitions back
to sessions in turn, and the sessions invoke the appropriate states to
handle them.  When several sessions do this, their state invocations
are interleaved, and cooperative multitasking ensues.  This is much
more stable than the current state of Perl's threads, and it lends
itself to cleaner and more efficient design for certain classes of
programs.

=head2 Resource Tracking

Sessions have POE::Kernel and other event loops watch for resources on
their behalf.  They do this by asking them to invoke their states when
resources become active: "Be a dear and let me know when someone
clicks on this widget.  Thanks so much!"  In the meantime, they can
continue running other states or just do nothing with such staggering
efficiency that B<other> sessions can run B<their> states.

Some resources need to be serviced right away or they'll faithfully
continue reporting their readiness.  Filehandles are like this.  The
states that service this sort of resource are called right away,
bypassing the Kernel's FIFO.  Otherwise the time spent between
enqueuing and dispatching the "Hi, love; your resource is ready."
event will also be spent by POE enqueuing several copies of it.
That's bad form.  States that service friendlier resources, such as
signals, are notified through the FIFO.

External libraries' resource watchers usually expect to call a coderef
when a resource becomes ready.  POE::Session's postback() method
provides a coderef for them that, when called, posts notice of the
event through the Kernel's FIFO.  This allows POE to use every event
watcher currently known without requiring special code for each.  It
should also support future event watchers without requiring extra
code, so sessions can take advantage of them as soon as they're
available.

Most importantly, since POE::Kernel keeps track of everything sessions
do, it knows when they've run out of them.  Rather than let defunct
sessions forever consume memory without ever doing another thing, the
Kernel invokes their _stop states as if to say "Please switch off the
lights and lock up; it's time to go." and then destroys them.

Likewise, if a session stops on its own and there still are opened
resource watchers, the Kernel can close them.  POE excels at
long-running services, and resource leaks shall not be tolerated.

=head2 Job Control and Family Values

Sessions are resources too, but they are watched automatically
throughout their lifetimes.  The Kernel can do this since it's keenly
aware of their arrivals and departures.  It has to be since it's
managing resources for them.

Sessions spawn children by creating new sessions.  It's that simple.
New sessions' _parent states are invoked to tell them who their
parents are.  Likewise, their parents' _child states are invoked to
let them know when child sessions come and go.  These are very handy
for job control.

=head2 State Types

POE::Session can wrap three sorts of state.  Each has a name that
strives to describe exactly what it does, but they still need detailed
explanations, so here we go.

=over 2

=item * Inline states

Inline states are merely coderefs.  They originally were defined with
inline anonymous coderefs, like so:

  POE::Session->create(
    inline_states =>
    { state_name_one => sub { print "state one"; },
      state_name_two => sub { print "state two"; },
    }
  );

This can be taken to the extreme, defining enormous state machines in
a single POE::Session constructor.  Some people consider this
delightfully Java-esque while others hate it to death.  Luckily for
the latter people, named coderefs are also possible:

  sub state_code_one { print "state one"; }
  sub state_code_two { print "state two"; }

  POE::Session->create(
    inline_states =>
    { state_name_one => \&state_code_one,
      state_name_two => \&state_code_two,
    }
  );

=item * Object states

Then came states that could be implemented as object methods.  I
believe Artur asked for these to interface POE with objects he'd
already written.  In this case, every state is mapped to method call:

  POE::Session->create(
    object_states =>
    [ $object => [ 'state_name_one', 'state_name_two' ]
    ]
  );

It's important to note that while inline_states maps to a hash
reference, object_states maps to a list reference.  $object would have
lost its blessing had object_states mapped to a hashref, and invoking
its methods would be difficult.

Sessions can bind methods from multiple objects, too:

  POE::Session->create(
    object_states =>
    [ $object_1 => [ 'state_name_one',   'state_name_two'  ],
      $object_2 => [ 'state_name_three', 'state_name_four' ],
    ]
  );

Abigail then insisted that the hard link between state and method
names be broken.  She uses the common convention of leading
underscores denoting private symbols.  This conflicted with POE
wanting to invoke _start and similarly named object methods.  So
mapped states were born:

  POE::Session->create(
    object_states =>
    [ $object_1 => { state_one => 'method_one', state_two => 'method_two' },
      $object_2 => { state_six => 'method_six', state_ten => 'method_ten' },
    ]
  );

=item * Package states

States are little more than functions, which in turn can be organized
into packages for convenient maintenance and use.  Package methods are
invoked the same as object methods, so it was easy to support them
once object states were implemented.

  POE::Session->create(
    package_states =>
    [ Package_One => [ 'state_name_one',   'state_name_two'  ],
      Package_Two => [ 'state_name_three', 'state_name_four' ],
    ]
  );

You may have noticed that package_states maps to a list reference when
it could just as well have mapped to a hash reference.  This was done
for nothing more than consistency with object states.

Mapped package states are also possible:

  POE::Session->create(
    package_states =>
    [ Package_One => { state_one => 'method_one', state_two => 'method_two' },
      Package_Two => { state_six => 'method_six', state_ten => 'method_ten' },
    ]
  );

=head1 POE::Session Exports

Each session maintains its state machine's runtime context.  Every
state receives its context as several standard parameters.  These
parameters tell the state about its Kernel, its Session, the
transition, and itself.  Any number of states' own parameters may
exist after them.

The parameters' offsets into @_ were once defined, but changing them
would break existing code.  POE::Session now defines symbolic
constants for states' parameters, and their values are guaranteed to
reflect the correct offsets into @_ no matter how its order changes.

These are the values that make up a session's runtime context, along
with the symbolic constants that define their places in a state's
parameter list.

=over 2

=item ARG0
=item ARG1
=item ARG2
=item ARG3
=item ARG4
=item ARG5
=item ARG6
=item ARG7
=item ARG8
=item ARG9

These are the first ten of the state's own parameters.  The state's
parameters are guaranteed to exist at the end of @_, so it's possible
to pull variable numbers of them off the call stack with this:

  my @args = @_[ARG0..$#_];

These values correspond to PARAMETER_LIST in many of POE::Kernel's
methods.  In the following example, the words "zero" through "four"
will be passed into "some_state" as @_[ARG0..ARG4].

  $_[KERNEL]->yield( some_state => qw( zero one two three four ) );

=item HEAP

Every session includes a hash for storing arbitrary data.  This hash
is called a heap because it was modelled after process heaps.  Each
session has only one heap, and its data persists for the session's
lifetime.  States that store their persistent data in the heap will
always be saving it with the correct session, helping to ensure their
re-entrancy with a minimum of work.

  sub _start {
    $_[HEAP]->{start_time} = time();
  }

  sub _stop {
    my $elapsed_runtime = time() - $_[HEAP]->{start_time};
    print 'Session ', $_[SESSION]->ID, " elapsed runtime: $elapsed_runtime\n";
  }

=item KERNEL

States quite often must call Kernel methods.  They receive a reference
to the Kernel in $_[KERNEL] to assist them in this endeavor.  This
example uses $_[KERNEL] post a delayed event:

  $_[KERNEL]->delay( time_is_up => 10 );

=item OBJECT

Perl passes an extra parameter to object and package methods.  This
parameter contains the object reference or package name in which the
method is being invoked.  POE::Session exports this parameter's offset
(which is always 0, by the way, but let's pretend it sometimes isn't)
in the OBJECT constant.

In this example, the ui_update_everything state multiplexes a single
notification into several calls to the same object's methods.

  sub ui_update_everything {
    my $object = $_[OBJECT];
    $object->update_menu();
    $object->update_main_window();
    $object->update_status_line();
  }

Inline states are implemented as plain coderefs, and Perl doesn't pass
them any extra information, so $_[OBJECT] is always undef for them.

=item SENDER

Every state is run in response to an event.  These events can be
posted state transitions or immediate resource service callbacks.  The
Kernel includes a reference to the thing that generated the event
regardless of its delivery method, and that reference is contained in
$_[SENDER].

The SENDER can be used to verify that an event came from where it
ought to.  It can also be used as a return address so that responses
can be posted back to sessions that sent queries.

This example shows both common uses.  It posts a copy of an event back
to its sender unless the sender happens to be itself.  The condition
is important in preventing infinite loops.

  sub echo_event {
    $_[KERNEL]->post( $_[SENDER], $_[STATE], @_[ARG0..$#_] )
      unless $_[SENDER] == $_[SESSION];
  }

=item SESSION

The SESSION parameter contains a reference to the current session.
This provides states with access to their session's methods.

  sub enable_trace {
    $_[SESSION]->option( trace => 1 );
    print "Session ", $_[SESSION]->ID, ": dispatch trace is now on.\n";
  }

=item STATE

A single state can have several different names.  For example:

  POE::Session->create(
    inline_states =>
    { one => \&some_state,
      two => \&some_state,
      six => \&some_state,
      ten => \&some_state,
    }
  );

Sometimes it's useful for the state to know which name it was invoked
by.  The $_[STATE] parameter contains just that.

  sub some_state {
    print( "some_state in session ", $_[SESSION]-ID,
           " was invoked as ", $_[STATE], "\n"
         );
  }

$_[STATE] is often used by the _default state, which by default can be
invoked as almost anything.

=back

=head1 POE::Session's Predefined States

POE defines some states with standard functions.  They all begin with
a single leading underscore, and any new ones will also follow this
convention.  It's therefore recommended not to use a single leading
underscore in custom state names, since there's a small but positive
probability of colliding with future standard events.

Predefined states generally have serious side effects.  The _start
state, for example, performs much of the task of setting up a session.
Posting a redundant _start state transition will dutifully attempt to
allocate a session that already exists, which will in turn do
terrible, horrible things to the Kernel's internal data.  Such things
would normally be outlawed outright, but the extra overhead to check
for them hasn't yet been deemed worthwhile.  Please be careful!

Here now are the predefined standard states, why they're invoked, and
what their parameters mean.

=over 2

=item _child

The _child state is invoked to notify a parent session when a new
child arrives or an old one departs.  Also see the _child state for
more information.

$_[ARG0] contains a string describing what the child is doing:

=over 2

=item 'create'

The child session has just been created.  The current session is its
original parent.

=item 'gain'

Another session has stopped, and we have just inherited this child
from it.

=item 'lose'

The child session has stopped, and we are losing it.

=back

$_[ARG1] is a reference to the child in question.  It will still be
valid even if the child is in its death throes, but it won't last long
enough to receive posted events.

$_[ARG2] is only valid when a new session has been created ($_[ARG0]
is 'create').  It contains the new child session's _start state's
return value.

=item _default

It's not illegal to dispatch an event that a session cannot handle.
If such a thing occurs, the session's _default state is invoke
instead.  If no _default state exists, then the event is discarded
quietly.  While this is considered a feature, some people may be vexed
by misspelled state names.  See POE::Session's option() method for
information about catching typos.

Strange state parameters change slightly when they invoke _default.
The original state's name is preserved in $_[ARG0] while its arguments
are preserved in $_[ARG1].  Everything else remains the same.

Beware!  _default states can accidentally make programs that will only
be stopped by SIGKILL.  This happens because _default will catch
signals when a signal handler isn't defined.  Please read about signal
handlers along with POE::Kernel's signal watchers for information on
avoiding this unfortunate problem.

=item _parent

The _parent state is invoked to notify a child session when it's being
passed from one parent to another.  $_[ARG0] contains the session's
previous parent, and $_[ARG1] contains its new one.

The _child state is the other side of this coin.

=item _signal

The _signal state is a session's default signal handler.  Every signal
that isn't mapped to a specific state will be delivered to this one.
If _signal doesn't exist but _default does, then _default gets it
instead.  See the _default state's description for a reason why this
may not be desirable.  If both _signal and _default are missing, then
the signal is discarded unhandled.

POE::Kernel's sig() method can map a specific signal to another state.
The other state is called instead of _signal, unless B<it> isn't
there; then _default gets a chance to handle it, etc.

$_[ARG0] contains the signal's name, as used by Perl's %SIG hash.

A signal handler state's return value is significant.  Please read
more about signal watchers and in the POE::Kernel manpage.

=item _start

The Kernel invokes a session's _start state once the session has been
registered and is ready to begin running.  Sessions that have no
_start states are never started.  In fact, creating such silly
sessions is illegal since POE wouldn't know how to start them.

$_[SENDER] contains a reference to the new session's parent session.
Sessions created before $poe_kernel->run() is called will have
$_[KERNEL] for a parent.

@_[ARG0..$#_] contain the arugments passed into the Session's
constructor.  See the documentation for POE::Session->new() and
POE::Session->create() for more information.

=item _stop

The Kernel invokes a session's _stop state when it realizes the
session has run out of things to do.  It then destroys the session
once the _stop state returns.  A session's _stop state usually
contains special destructor code, possibly to clean up things that the
kernel can't.

This state receives nothing special in @_[ARG0..$#_].

=back

=head2 States' Return Values

States always are evaluated in a scalar context.  States that must
return more than one value should return them in an array or hash
reference.

The values signal handling states return are significant and are
covered along with signal watchers in the POE::Kernel manpage.

States are prohibited from returning references to objects in the POE
namespace.  It's too easy to do this accidentally, and it has often
confounded Perl's garbage collection in the past.

=head1 PUBLIC METHODS

=over 2

=item ID

Returns the POE::Session instance's unique identifier.  This is a
number that starts with 1 and counts up forever, or until something
causes the number to wrap.  It's theoretically possible that session
IDs may collide after at 4.29 billion sessions have been created.

=item create LOTS_OF_STUFF

Bundles some states together into a single machine, then starts it
running.

LOTS_OF_STUFF looks like a hash of parameter name/value pairs, but
it's really just a list.  It's preferred over the older, more DWIMmy
new() constructor because each kind of parameter is explicitly named,
and it can therefore unambiguously figure out what it is a program is
trying to do.

=over 2

=item args => LISTREF

Defines the arguments to give to the machine's _start state.  They're
passed in as @_[ARG0..$#_].

  args => [ 'arg0', 'arg1', 'etc.' ],

=item inline_states => HASHREF

Defines inline coderefs that make up some or all of the session's
states.

  inline_states =>
  { _start => sub { print "arg0=$_[ARG0], arg1=$_[ARG1], etc.=$_[ARG2]\n"; }
    _stop  => \&stop_state
  },

=item object_states => LISTREF

Defines object methods that make up some or all of the session's
states.

LISTREF is a list of parameter pairs.  The first member of each pair
is an object reference.  The second member is either a list reference
or hash reference.  When it's a list reference, the referenced list
contains methods from the referenced object.  The methods define
states with the same names.  When it's a hash reference, the
referenced hash contains state/method pairs which map state names to
methods that may have different names.

Perhaps some examples are in order!  This one defines two states,
state_one and state_two, which are implemented as $object->state_one()
and $object->state_two().

  object_states =>
  [ $object => [ 'state_one', 'state_two' ],
  ],

This second example defines two other states, state_five and
state_six, which are implemented as $object->do_five() and
$object->do_six().

  object_states =>
  [ $object => { state_five => 'do_five',
                 state_six  => 'do_six',
               },
  ],

It's a lot simpler to do than to describe.

=item options => HASHREF

Sets one or more initial session options before starting it.  Please
see the POE::Session option() method for a list of available session
options and what they do.

  option => { trace => 1, debug => 1 },

=item package_states => LISTREF

Defines package methods that make up some or all of the session's
states.

LISTREF is virtually identical to the one for object_states, so I'll
just skip to the examples.  Check out object_states' description if
you'd like more details, replacing "object" and "object reference"
with "package" and "package name", respectively.

So, here's a package_states invocation that defines two states,
state_one and state_two, which are implemented as Package->state_one()
and Package->state_two.

  package_states =>
  [ Package => [ 'state_one', 'state_two' ],
  ],

And here's an invocation that defines two other states, state_five and
state_six, to Package->do_five() and Package->do_six().

  package_states =>
  [ Package => { state_five => 'do_five',
                 state_six  => 'do_six',
               },
  ],

Easy-peasy!

=back

=item new LOTS_OF_STUFF

POE::Session's new() constructor is slighly depreciated in favor of
the newer create() constructor.  A detailed description of
POE::Session->new() is not forthcoming, but POE::Session's SYNOPSIS
briefly touches upon its use.

=item option OPTION_NAME

=item option OPTION_NAME, OPTION_VALUE

=item option NAME_VALUE_PAIR_LIST

Sets and/or retrieves options' values.

The first form returns the value of a single option, OPTION_NAME.

  my $trace_value = $_[SESSION]->option( 'trace' );

The second form sets OPTION_NAME to OPTION_VALUE, returning the
B<previous> value of OPTION_NAME.

  my $old_trace_value = $_[SESSION]->option( trace => $new_trace_value );

The final form sets several options, returning a hashref containing
their name/value pairs.

  my $old_values = $_[SESSION]->option(
    trace => $new_trace_value,
    debug => $new_debug_value,
  );
  print "Old option values:\n";
  while (my ($option, $value) = each %$old_values) {
    print "$option = $value\n";
  }

=item postback EVENT_NAME, PARAMETER_LIST

Creates an anonymous coderef which, when called, posts EVENT_NAME back
to the session.  Postbacks will keep sessions alive until they're
destroyed.

The EVENT_NAME event will include two parameters.  $_[ARG0] will
contain a reference to the PARAMETER_LIST passed to postback().
$_[ARG1] will hold a reference to the parameters given to the coderef
when it's called.

This example creates a Tk button that posts an "ev_counters_begin"
event at a session whenever it's pressed.

  $poe_tk_main_window->Button
    ( -text => 'Begin Slow and Fast Alarm Counters',
      -command => $session->postback( 'ev_counters_begin' )
    )->pack;

It can also be used to post events from Event watchers' callbacks.
This one posts back "ev_flavor" with $_[ARG0] holding [ 'vanilla' ]
and $_[ARG1] containing a reference to whatever parameters
Event->flawor gives its callback.

  Event->flavor
    ( cb   => $session->postback( 'ev_flavor', 'vanilla' ),
      desc => 'post ev_flavor when Event->flavor occurs',
    );

=back

=head1 SEE ALSO

The POE manpage contains holstic POE information, including an up to
date list of the modules comprising it.

=head1 BUGS

There is a chance that session IDs may collide after Perl's integer
value wraps.  This can occur after as few as 4.29 billion sessions.

If you find another, tell the author!

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage for authors and licenses.

=cut
