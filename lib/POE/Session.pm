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
            $self->register_state($method, $package, $state);
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
        $POE::Kernel::poe_kernel->post( {% fetch_id $self %},
                                        $event, \@etc, \@_
                                      );
      },
      'POE::Session::Postback'
    );
  $postback_parent_id{$postback} = {% fetch_id $self %};
  $POE::Kernel::poe_kernel->refcount_increment( $self, 'postback' );
  $postback;
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - POE State Machine Instance

=head1 SYNOPSIS

  # POE::Session has two different constructors.  This is the classic
  # session constructor.

  POE::Session->new(

    # Inline states map names to plain coderefs.
    state_one => \&coderef_one,
    state_two => sub { ... },

    # Plain object and package states map names to identically named
    # methods.  For example, $object_one->state_three() is called to
    # handle 'state_three'.
    $object_one  => [ 'state_three', 'state_four',  'state_five'  ],
    $package_one => [ 'state_six',   'state_seven', 'state_eight' ],

    # Aliased object and package states map state names to differently
    # named methods.  For example, $package_two->method_ten() is
    # called to handle 'state_ten'.
    $object_two  => { state_nine => 'method_nine' },
    $package_two => { state_ten  => 'method_ten' },

    # A list reference in place of a state name indicates arguments to
    # pass to the session's _start state in ARG0..ARGn.  This can
    # occur anywhere in the constructor's parameters.
    \@start_args,
  );

  # This is a newer constructor that requires more explicit
  # parameters:

  POE::Session->create(

    # If the 'args' parameter contains a list reference, then its
    # contents are passed to the session's _start state in ARG0..ARGn.
    # Otherwise args' value is passed to _start in ARG0.
    args => \@args,

    # These inline states are equivalent to the POE::Session->new
    # synopsis.
    inline_states =>
      { state_one => \&coderef_one,
        state_two => sub { ... },
      },

    # These plain and aliased object states match the ones shown in
    # POE::Session-new's synopsis.  Note, though, that the right side
    # of the => operator is a list reference; not a hash reference.
    # Hashes would ruin the objects' blessing.
    object_states =>
    [ $object_one => [ 'state_three', 'state_four', 'state_five' ],
      $object_two => { state_nine => 'method_nine' },
    ],

    # These plain and aliased package states match the ones shown in
    # POE::Session->new's synopsis.  The right side of the => operator
    # is a list reference for consistency with object_states.
    package_states =>
    [ $package_one => [ 'state_six', 'state_seven', 'state_eight' },
      $package_two => { state_ten => 'method_ten' },
    ],

    # The create constructor has one feature over new.  It allows
    # session options to be set at creation time.  options' value is a
    # hash reference of option names and initial values.
    options => \%options,
  );

  # Set or clear some session options:
  $session->option( trace => 1, default => 1 );

  # Fetch this session's ID:
  print $session->ID;

  # Create a postback for use where external libraries expect
  # callbacks.  This is an experimental feature.  There is no
  # guarantee that it will work, nor is it guaranteed to exist in the
  # future.

  $postback_coderef = $session->postback( $state_name, @state_args );

=head1 DESCRIPTION

This description is out of date as of version 0.1001, but the synopsis
is accurate.  The description will be fixed shortly.

(Note: Session constructors were changed in version 0.06.  Processes
no longer support multiple kernels.  This made the $kernel parameter
to session constructors obsolete, so it was removed.)

POE::Session is a generic state machine instance.  Session instances
are driven by state transition events, dispatched by POE::Kernel.

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

... or...

  &something($_) foreach (@_[ARG0..$#_]);

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
know it's okay to begin.  POE requires every session to have a special
B<_start> state.  Otherwise, how would they know when to start?

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
has a detrimental effect on programs that expect long uptimes, to say
the least.

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

Signal handlers' return values tell POE whether signals have been
handled.  Returning true tells POE the signal was absorbed; returning
false tells POE it wasn't.  This is only a factor with so-called
"terminal" signals, which are explained in the POE::Kernel manpage.
Basically: Sessions that don't handle terminal signals are stopped.

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

Be careful: The B<_default> handler will catch signals, and its return
value will be used as an indicator of whether signals have been
handled.  It's easy to create programs that must be kill -KILL'ed this
way.

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

=head1 DEBUGGING FLAGS

These flags were made public in 0.0906.  If they are pre-defined by
the first package that uses POE::Session (or POE, since that includes
POE::Session by default), then the pre-definition will take precedence
over POE::Session's definition.  In this way, it is possible to use
POE::Session's internal debugging code without finding Session.pm and
editing it.

Debugging flags are meant to be constants.  They should be prototyped
as such, and they must be declared in the POE::Session package.

Sample usage:

  # Display information about Session object destruction.
  sub POE::Session::DEB_DESTROY () { 1 }
  use POE;
  ...

=over 4

=item *

DEB_DESTROY

When enabled, POE::Session will display some information about the
session's internal data at DESTROY time.

=back

=head1 SEE ALSO

POE; POE::Kernel

=head1 BUGS

The documentation for POE::Session::create() is fairly nonexistent.

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage.

=cut
