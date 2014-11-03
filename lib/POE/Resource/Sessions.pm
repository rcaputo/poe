# Manage session data structures on behalf of POE::Kernel.

package POE::Resource::Sessions;

use vars qw($VERSION);
$VERSION = '1.366'; # NOTE - Should be #.### (three decimal places)

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

# Map stringy sessions to their references for _data_ses_resolve.
my %kr_session_refs;
# { $session_ref => $blessed, ... }

### Session structure.
my %kr_sessions;
#  { $session_id =>
#    [ $blessed_session,         SS_SESSION
#      $total_reference_count,   SS_REFCOUNT
#      $parent_session,          SS_PARENT
#      { $child_session_id => $blessed_ref,  SS_CHILDREN
#        ...,
#      },
#      { $process_id => $placeholder_value,  SS_PROCESSES
#        ...,
#      },
#    ],
#    ...,
#  };

sub SS_SESSION    () { 0 }
sub SS_REFCOUNT   () { 1 }
sub SS_PARENT     () { 2 }
sub SS_CHILDREN   () { 3 }
sub SS_PROCESSES  () { 4 }

BEGIN { $POE::Kernel::poe_kernel->[KR_SESSIONS] = \%kr_sessions; }

sub _data_ses_relocate_kernel_id {
  my ($self, $old_id, $new_id) = @_;

  while (my ($sid, $ses_rec) = each %kr_sessions) {
    my $children = $ses_rec->[SS_CHILDREN];
    $children->{$new_id} = delete $children->{$old_id}
      if exists $children->{$old_id};
  }

  $kr_sessions{$new_id} = delete $kr_sessions{$old_id}
    if exists $kr_sessions{$old_id};
}

### End-run leak checking.

sub _data_ses_clone {
  %kr_session_refs = ();
  foreach my $ses_ref (map { $_->[SS_SESSION] } values %kr_sessions) {
    $kr_session_refs{$ses_ref} = $ses_ref;
  }
}

sub _data_ses_finalize {
  my $finalized_ok = 1;

  while (my ($sid, $ses_rec) = each %kr_sessions) {
    $finalized_ok = 0;
    _warn(
      "!!! Leaked session: $sid\n",
      "!!!\trefcnt = $ses_rec->[SS_REFCOUNT]\n",
      "!!!\tparent = $ses_rec->[SS_PARENT]\n",
      "!!!\tchilds = ", join("; ", keys(%{$ses_rec->[SS_CHILDREN]})), "\n",
      "!!!\tprocs  = ", join("; ", keys(%{$ses_rec->[SS_PROCESSES]})),"\n",
    );
  }

  while (my ($stringy, $blessed) = each %kr_session_refs) {
    $finalized_ok = 0;
    _warn "!!! Leaked stringy session $stringy = $blessed\n";
    _warn "!!!\tBad clone detected, while we're at it.\n" if (
      $stringy ne "$blessed"
    );
  }

  return $finalized_ok;
}

### Enter a new session into the back-end stuff.

my %kr_marked_for_gc;
my @kr_marked_for_gc;

sub _data_ses_allocate {
  my ($self, $session, $sid, $parent_id) = @_;

  my $parent;
  if (defined $parent_id) {
    _trap "parent session $parent_id does not exist" unless (
      exists $kr_sessions{$parent_id}
    );

    $parent = $kr_sessions{$parent_id}[SS_SESSION];

    _trap "session $session is already allocated" if exists $kr_sessions{$sid};
  }

  TRACE_REFCNT and _warn "<rc> allocating $session";

  $kr_sessions{$sid} =
    [ $session,   # SS_SESSION
      0,          # SS_REFCOUNT
      $parent,    # SS_PARENT
      { },        # SS_CHILDREN
      { },        # SS_PROCESSES
    ];

  # For the ID to session reference lookup.
  $self->_data_sid_set($sid, $session);

  # For the stringy to blessed session reference lookup.
  $kr_session_refs{$session} = $session;

  # Manage parent/child relationship.
  if (defined $parent_id) {
    if (TRACE_SESSIONS) {
      _warn(
        "<ss> ",
        $self->_data_alias_loggable($sid), " has parent ",
        $self->_data_alias_loggable($parent_id)
      );
    }

    $kr_sessions{$parent_id}->[SS_CHILDREN]->{$sid} = $session;
    $self->_data_ses_refcount_inc($parent_id);
  }

  TRACE_REFCNT and _warn "<rc> $session marked for gc";
  unless ($sid eq $self->ID) {
    push @kr_marked_for_gc, $sid;
    $kr_marked_for_gc{$sid} = $sid;
  }
}

# Release a session's resources, and remove it.  This doesn't do
# garbage collection for the session itself because that should
# already have happened.
#
# TODO This is yet another place where resources will need to register
# a function.  Every resource's _data_???_clear_session is called
# here.

sub _data_ses_free {
  my ($self, $sid) = @_;

  TRACE_REFCNT and do {
    _warn "<rc> freeing session $sid";
    _trap("!!! free defunct session $sid?!\n") unless (
      $self->_data_ses_exists($sid)
    );
  };

  if (TRACE_SESSIONS) {
    _warn "<ss> freeing ", $self->_data_alias_loggable($sid);
  }

  # Manage parent/child relationships.

  my $parent   = $kr_sessions{$sid}->[SS_PARENT];
  my @children = $self->_data_ses_get_children($sid);

  if (defined $parent) {
    my $parent_id = $parent->ID;

    if (ASSERT_DATA) {
      _trap "session is its own parent" if $parent_id eq $sid;
      _trap "session's parent ($parent_id) doesn't exist"
        unless exists $kr_sessions{$parent_id};

      unless ($self->_data_ses_is_child($parent_id, $sid)) {
        _trap(
          $self->_data_alias_loggable($sid), " isn't a child of ",
          $self->_data_alias_loggable($parent_id), " (it's a child of ",
          $self->_data_alias_loggable($self->_data_ses_get_parent($sid)->ID),
          ")"
        );
      }
    }

    # Remove the departing session from its parent.

    _trap "internal inconsistency ($parent_id/$sid)"
      unless delete $kr_sessions{$parent_id}->[SS_CHILDREN]->{$sid};

    $kr_sessions{$sid}->[SS_PARENT] = undef;

    if (TRACE_SESSIONS) {
      _cluck(
        "<ss> removed ",
        $self->_data_alias_loggable($sid), " from ",
        $self->_data_alias_loggable($parent_id)
      );
    }

    $self->_data_ses_refcount_dec($parent_id);

    # Move the departing session's children to its parent.

    foreach (@children) {
      $self->_data_ses_move_child($_->ID, $parent_id)
    }
  }
  elsif (ASSERT_DATA) {
    _trap "no parent to give children to" if @children;
  }

  my $session = $kr_sessions{$sid}[SS_SESSION];

  # Things which do not hold reference counts.

  $self->_data_sid_clear($sid);                # Remove from SID tables.
  $self->_data_sig_clear_session($sid);        # Remove all leftover signals.

  # Things which do hold reference counts.

  $self->_data_alias_clear_session($sid);      # Remove all leftover aliases.
  $self->_data_extref_clear_session($sid);     # Remove all leftover extrefs.
  $self->_data_handle_clear_session($sid);     # Remove all leftover handles.

  $self->_data_ev_clear_session($sid);         # Remove all leftover events.

  # Remove the session itself.

  delete $kr_marked_for_gc{$sid};
  delete $kr_sessions{$sid};
  delete $kr_session_refs{$session};
}

### Move a session to a new parent.

sub _data_ses_move_child {
  my ($self, $sid, $new_parent_id) = @_;

  if (ASSERT_DATA) {
    _trap("moving nonexistent child to another parent")
      unless exists $kr_sessions{$sid};
    _trap("moving child to a nonexistent parent")
      unless exists $kr_sessions{$new_parent_id};
  }

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> moving ",
      $self->_data_alias_loggable($sid), " to ",
      $self->_data_alias_loggable($new_parent_id)
    );
  }

  my $old_parent_id = $self->_data_ses_get_parent($sid)->ID;

  if (ASSERT_DATA) {
    _trap("moving child from a nonexistent parent")
      unless exists $kr_sessions{$old_parent_id};
  }

  # Remove the session from its old parent.
  delete $kr_sessions{$old_parent_id}->[SS_CHILDREN]->{$sid};

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> removed ",
      $self->_data_alias_loggable($sid), " from ",
      $self->_data_alias_loggable($old_parent_id)
    );
  }

  $self->_data_ses_refcount_dec($old_parent_id);

  # Change the session's parent.
  $kr_sessions{$sid}->[SS_PARENT] = $kr_sessions{$new_parent_id}[SS_SESSION];

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> changed parent of ",
      $self->_data_alias_loggable($sid), " to ",
      $self->_data_alias_loggable($new_parent_id)
    );
  }

  # Add the current session to the new parent's children.
  $kr_sessions{$new_parent_id}->[SS_CHILDREN]->{$sid} = (
    $kr_sessions{$sid}[SS_SESSION]
  );

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> added ",
      $self->_data_alias_loggable($sid), " as child of ",
      $self->_data_alias_loggable($new_parent_id)
    );
  }

  $self->_data_ses_refcount_inc($new_parent_id);

  # We do not call _data_ses_collect_garbage() here.  This function is
  # called in batch for a departing session, to move its children to
  # its parent.  The GC test would be superfluous here.  Rather, it's
  # up to the caller to do the proper GC test after moving things
  # around.
}

### Get a session's parent.

sub _data_ses_get_parent {
  my ($self, $sid) = @_;
  if (ASSERT_DATA || ASSERT_USAGE) {
    _trap("undefined session ID") unless defined $sid;
    _trap("retrieving parent of a nonexistent session")
      unless exists $kr_sessions{$sid};
  }
  return $kr_sessions{$sid}->[SS_PARENT];
}

### Get a session's children.

sub _data_ses_get_children {
  my ($self, $sid) = @_;
  if (ASSERT_DATA) {
    _trap("retrieving children of a nonexistent session")
      unless exists $kr_sessions{$sid};
  }
  return values %{$kr_sessions{$sid}->[SS_CHILDREN]};
}

### Is a session a child of another?

sub _data_ses_is_child {
  my ($self, $parent_id, $child_id) = @_;
  if (ASSERT_DATA) {
    _trap("testing is-child of a nonexistent parent session")
      unless exists $kr_sessions{$parent_id};
  }
  return(
    exists $kr_sessions{$parent_id} &&
    exists $kr_sessions{$parent_id}->[SS_CHILDREN]->{$child_id}
  );
}

### Determine whether a session exists.  We should only need to verify
### this for sessions provided by the outside.  Internally, our code
### should be so clean it's not necessary.

sub _data_ses_exists {
  my ($self, $sid) = @_;
  return exists $kr_sessions{$sid};
}

### Resolve a session into its reference.

sub _data_ses_resolve {
  my ($self, $session) = @_;
  return undef unless exists $kr_session_refs{$session}; # Prevents autoviv.
  return $kr_session_refs{$session};
}

### Resolve a session ID into its reference.

sub _data_ses_resolve_to_id {
  my ($self, $session) = @_;
  $session = $self->_data_ses_resolve($session);
  return undef unless defined $session;
  return $session->ID;
}

### Sweep the GC marks.

sub _data_ses_gc_sweep {
  my $self = shift;

  TRACE_REFCNT and _warn "<rc> trying sweep";
  while (@kr_marked_for_gc) {
    my %temp_marked = %kr_marked_for_gc;
    %kr_marked_for_gc = ();

    my @todo = reverse @kr_marked_for_gc;
    @kr_marked_for_gc = ();

    # Never GC the POE::Kernel singleton.
    delete $temp_marked{$self->ID};

    foreach my $sid (@todo) {
      next unless delete $temp_marked{$sid};
      $self->_data_ses_stop($sid);
    }
  }
}

### Decrement a session's main reference count.  This is called by
### each watcher when the last thing it watches for the session goes
### away.  In other words, a session's reference count should only
### enumerate the different types of things being watched; not the
### number of each.

sub _data_ses_refcount_dec {
  my ($self, $sid) = @_;

  if (ASSERT_DATA) {
    _trap("decrementing refcount of a nonexistent session")
      unless exists $kr_sessions{$sid};
  }

  if (TRACE_REFCNT) {
    _cluck(
      "<rc> decrementing refcount for ",
      $self->_data_alias_loggable($sid)
    );
  }

  if (--$kr_sessions{$sid}->[SS_REFCOUNT] < 1) {
    TRACE_REFCNT and _warn "<rc> session $sid marked for gc";
    unless ($sid eq $self->ID) {
      push @kr_marked_for_gc, $sid;
      $kr_marked_for_gc{$sid} = $sid;
    }
  }

  $self->_data_ses_dump_refcounts($sid) if TRACE_REFCNT;

  if (ASSERT_DATA and $kr_sessions{$sid}->[SS_REFCOUNT] < 0) {
    _trap(
      $self->_data_alias_loggable($sid),
     " reference count went below zero"
   );
  }
}

### Increment a session's main reference count.

sub _data_ses_refcount_inc {
  my ($self, $sid) = @_;

  if (ASSERT_DATA) {
    _trap("incrementing refcount for nonexistent session")
      unless exists $kr_sessions{$sid};
  }

  if (TRACE_REFCNT) {
    _cluck(
      "<rc> incrementing refcount for ",
      $self->_data_alias_loggable($sid)
    );
  }

  if (++$kr_sessions{$sid}->[SS_REFCOUNT] > 0) {
    TRACE_REFCNT and _warn "<rc> session $sid unmarked for gc";
    delete $kr_marked_for_gc{$sid};
  }
  elsif (TRACE_REFCNT) {
    _warn(
      "??? session $sid refcount = $kr_sessions{$sid}->[SS_REFCOUNT]"
    );
  }

  $self->_data_ses_dump_refcounts($sid) if TRACE_REFCNT;
}

sub _data_ses_dump_refcounts {
  my ($self, $sid) = @_;

  my $ss = $kr_sessions{$sid};

  _warn(
    "<rc> +----- GC test for ", $self->_data_alias_loggable($sid), "-----\n",
    "<rc> | total refcnt  : ", $ss->[SS_REFCOUNT], "\n",
    "<rc> | event count   : ", $self->_data_ev_get_count_to($sid), "\n",
    "<rc> | post count    : ", $self->_data_ev_get_count_from($sid), "\n",
    "<rc> | child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n",
    "<rc> | handles in use: ", $self->_data_handle_count_ses($sid), "\n",
    "<rc> | aliases in use: ", $self->_data_alias_count_ses($sid), "\n",
    "<rc> | extra refs    : ", $self->_data_extref_count_ses($sid), "\n",
    "<rc> | pid count     : ", $self->_data_sig_session_awaits_pids($sid), "\n",
    "<rc> +---------------------------------------------------\n",
  );

  unless ($ss->[SS_REFCOUNT] and $self->_data_sig_session_awaits_pids($sid)) {
    _warn(
      "<rc> | ", $self->_data_alias_loggable($sid),
      " is eligible for garbage collection.\n",
      "<rc> +---------------------------------------------------\n",
    );
  }

  _carp "<rc> | called";
}

# Query a session's reference count.  Added for testing purposes.

sub _data_ses_refcount {
  my ($self, $sid) = @_;
  return $kr_sessions{$sid}->[SS_REFCOUNT];
}

### Compatibility function to do a GC sweep on attempted garbage
### collection.  The tests still try to call this.

sub _data_ses_collect_garbage {
  my ($self, $sid) = @_;
  # TODO - Deprecation warning.
  $self->_data_ses_gc_sweep();
}

### Return the number of sessions we know about.

sub _data_ses_count {
  return scalar keys %kr_sessions;
}

### Close down a session by force.

# Stop a session, dispatching _stop, _parent, and _child as necessary.
#
# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

my %already_stopping;

sub _data_ses_stop {
  my ($self, $sid) = @_;

  # Don't stop a session that's already in the throes of stopping.
  # This can happen with exceptions, during die() in _stop.  It can
  # probably be removed if exceptions are.

  return if exists $already_stopping{$sid};
  $already_stopping{$sid} = 1;

  TRACE_REFCNT and _warn "<rc> stopping session $sid";

  if (ASSERT_DATA) {
    _trap("stopping a nonexistent session") unless exists $kr_sessions{$sid};
  }

  if (TRACE_SESSIONS) {
    _warn("<ss> stopping ", $self->_data_alias_loggable($sid));
  }

  # Maintain referential integrity between parents and children.
  # First move the children of the stopping session up to its parent.
  my $parent = $self->_data_ses_get_parent($sid);

  foreach my $child ($self->_data_ses_get_children($sid)) {
    $self->_dispatch_event(
      $parent, $self,
      EN_CHILD, ET_CHILD, [ CHILD_GAIN, $child ],
      __FILE__, __LINE__, undef, monotime(), -__LINE__
    );
    $self->_dispatch_event(
      $child, $self,
      EN_PARENT, ET_PARENT,
      [ $self->_data_ses_get_parent($child->ID), $parent, ],
      __FILE__, __LINE__, undef, monotime(), -__LINE__
    );
  }

  # Referential integrity has been dealt with.  Now notify the session
  # that it has been stopped.

  my $session = $kr_sessions{$sid}[SS_SESSION];
  my $stop_return = $self->_dispatch_event(
    $session, $self->get_active_session(),
    EN_STOP, ET_STOP, [],
    __FILE__, __LINE__, undef, monotime(), -__LINE__
  );

  # If the departing session has a parent, notify it that the session
  # is being lost.

  if (defined $parent) {
    $self->_dispatch_event(
      $parent, $self,
      EN_CHILD, ET_CHILD, [ CHILD_LOSE, $session, $stop_return ],
      __FILE__, __LINE__, undef, monotime(), -__LINE__
    );
  }

  # Deallocate the session.

  $self->_data_ses_free($sid);

  # Stop the main loop if everything is gone.
  # XXX - Under Tk this is called twice.  Why?  WHY is it called twice?
  unless (keys %kr_sessions) {
    $self->loop_halt();
  }

  delete $already_stopping{$sid};
}

1;

__END__

=head1 NAME

POE::Resource::Sessions - internal session manager for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::Sessions is a mix-in class for POE::Kernel.  It
provides the internal features that manage sessions, regardless of the
session type.  It is used internally by POE::Kernel. so it has no
public interface.

=head1 SEE ALSO

See L<POE::Session> and L<POE::NFA> for one type of session.  CPAN
also have others.

See L<POE::Kernel/Sessions> for a discussion about POE::Kernel
sessions.

See L<POE::Kernel/Session Lifespans> to learn why sessions run, and
how to stop them.

See L<POE::Kernel/Session Management> for information about managing
sessions in your applications, and the events that occur when sessions
come and go.

See L<POE::Kernel/Session Helper Methods> for friend methods between
POE::Kernel and POE::Session classes.

See L<POE::Kernel/Resources> for public information about POE
resources.

See L<POE::Resource> for general discussion about resources and the
classes that manage them.

=head1 BUGS

None known.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
