# $Id$

# Manage session data structures on behalf of POE::Kernel.

package POE::Resources::Sessions;

use vars qw($VERSION);
$VERSION = (qw($Revision$))[1];

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;
### Session structure.

my %kr_sessions;
#  { $session =>
#    [ $blessed_session,         SS_SESSION
#      $total_reference_count,   SS_REFCOUNT
#      $parent_session,          SS_PARENT
#      { $child_session => $blessed_ref,     SS_CHILDREN
#        ...,
#      },
#      { $process_id => $placeholder_value,  SS_PROCESSES
#        ...,
#      },
#      $unique_session_id,       SS_ID
#    ],
#    ...,
#  };

sub SS_SESSION    () { 0 }
sub SS_REFCOUNT   () { 1 }
sub SS_PARENT     () { 2 }
sub SS_CHILDREN   () { 3 }
sub SS_PROCESSES  () { 4 }
sub SS_ID         () { 5 }

sub _data_ses_preload {
   $POE::Kernel::poe_kernel->[KR_SESSIONS] = \%kr_sessions;
}

use POE::API::ResLoader \&_data_ses_preload;

### End-run leak checking.

sub _data_ses_finalize {
  my $finalized_ok = 1;

  while (my ($ses, $ses_rec) = each(%kr_sessions)) {
    $finalized_ok = 0;

    _warn(
      "!!! Leaked session: $ses\n",
      "!!!\trefcnt = $ses_rec->[SS_REFCOUNT]\n",
      "!!!\tparent = $ses_rec->[SS_PARENT]\n",
      "!!!\tchilds = ", join("; ", keys(%{$ses_rec->[SS_CHILDREN]})), "\n",
      "!!!\tprocs  = ", join("; ", keys(%{$ses_rec->[SS_PROCESSES]})),"\n",
    );
  }

  return $finalized_ok;
}

### Enter a new session into the back-end stuff.

sub _data_ses_allocate {
  my ($self, $session, $sid, $parent) = @_;

  $kr_sessions{$session} =
    [ $session,  # SS_SESSION
      0,         # SS_REFCOUNT
      $parent,   # SS_PARENT
      { },       # SS_CHILDREN
      { },       # SS_PROCESSES
      $sid,      # SS_ID
    ];

  # For the ID to session reference lookup.
  $self->_data_sid_set($sid, $session);

  # Manage parent/child relationship.
  if (defined $parent) {
    if (ASSERT_DATA) {
      unless (exists $kr_sessions{$parent}) {
        _trap "parent $parent does not exist";
      }
    }

    if (TRACE_SESSIONS) {
      _warn(
        "<ss> ",
        $self->_data_alias_loggable($session), " has parent ",
        $self->_data_alias_loggable($parent)
      );
    }

    $kr_sessions{$parent}->[SS_CHILDREN]->{$session} = $session;
    $self->_data_ses_refcount_inc($parent);
  }
}

# Release a session's resources, and remove it.  This doesn't do
# garbage collection for the session itself because that should
# already have happened.
#
# -><- This is yet another place where resources will need to register
# a function.  Every resource's _data_???_clear_session is called
# here.

sub _data_ses_free {
  my ($self, $session) = @_;

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> freeing ",
      $self->_data_alias_loggable($session)
    );
  }

  # Manage parent/child relationships.

  my $parent = $kr_sessions{$session}->[SS_PARENT];
  my @children = $self->_data_ses_get_children($session);

  if (defined $parent) {
    if (ASSERT_DATA) {
      if ($parent == $session) {
        _trap "session is its own parent";
      }
      unless ($self->_data_ses_is_child($parent, $session)) {
        _trap(
          $self->_data_alias_loggable($session), " isn't a child of ",
          $self->_data_alias_loggable($parent), " (it's a child of ",
          $self->_data_alias_loggable($self->_data_ses_get_parent($session)),
          ")"
        );
      }
      unless (exists $kr_sessions{$parent}) {
        _trap "internal inconsistency ($parent)";
      }
    }

    # Remove the departing session from its parent.

    _trap "internal inconsistency ($parent/$session)"
      unless delete $kr_sessions{$parent}->[SS_CHILDREN]->{$session};
    undef $kr_sessions{$session}->[SS_PARENT];

    if (TRACE_SESSIONS) {
      _cluck(
        "<ss> removed ",
        $self->_data_alias_loggable($session), " from ",
        $self->_data_alias_loggable($parent)
      );
    }

    $self->_data_ses_refcount_dec($parent);

    # Move the departing session's children to its parent.

    foreach (@children) {
      $self->_data_ses_move_child($_, $parent)
    }
  }
  elsif (ASSERT_DATA) {
    _trap "no parent to give children to" if @children;
  }

  # Things which do not hold reference counts.

  $self->_data_sid_clear($session);            # Remove from SID tables.
  $self->_data_sig_clear_session($session);    # Remove all leftover signals.

  # Things which dohold reference counts.

  $self->_data_alias_clear_session($session);  # Remove all leftover aliases.
  $self->_data_extref_clear_session($session); # Remove all leftover extrefs.
  $self->_data_handle_clear_session($session); # Remove all leftover handles.
  $self->_data_ev_clear_session($session);     # Remove all leftover events.

  # Remove the session itself.

  delete $kr_sessions{$session};

  # GC the parent, if there is one.
  if (defined $parent) {
    $self->_data_ses_collect_garbage($parent);
  }

  # Stop the main loop if everything is gone.
  unless (keys %kr_sessions) {
    $self->loop_halt();
  }
}

### Move a session to a new parent.

sub _data_ses_move_child {
  my ($self, $session, $new_parent) = @_;

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> moving ",
      $self->_data_alias_loggable($session), " to ",
      $self->_data_alias_loggable($new_parent)
    );
  }

  if (ASSERT_DATA) {
    _trap() unless exists $kr_sessions{$session};
    _trap() unless exists $kr_sessions{$new_parent};
  }

  my $old_parent = $self->_data_ses_get_parent($session);

  if (ASSERT_DATA) {
    _trap() unless exists $kr_sessions{$old_parent};
  }

  # Remove the session from its old parent.
  delete $kr_sessions{$old_parent}->[SS_CHILDREN]->{$session};

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> removed ",
      $self->_data_alias_loggable($session), " from ",
      $self->_data_alias_loggable($old_parent)
    );
  }

  $self->_data_ses_refcount_dec($old_parent);

  # Change the session's parent.
  $kr_sessions{$session}->[SS_PARENT] = $new_parent;

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> changed parent of ",
      $self->_data_alias_loggable($session), " to ",
      $self->_data_alias_loggable($new_parent)
    );
  }

  # Add the current session to the new parent's children.
  $kr_sessions{$new_parent}->[SS_CHILDREN]->{$session} = $session;

  if (TRACE_SESSIONS) {
    _warn(
      "<ss> added ",
      $self->_data_alias_loggable($session), " as child of ",
      $self->_data_alias_loggable($new_parent)
    );
  }

  $self->_data_ses_refcount_inc($new_parent);

  # We do not call _data_ses_collect_garbage() here.  This function is
  # called in batch for a departing session, to move its children to
  # its parent.  The GC test would be superfluous here.  Rather, it's
  # up to the caller to do the proper GC test after moving things
  # around.
}

### Get a session's parent.

sub _data_ses_get_parent {
  my ($self, $session) = @_;
  if (ASSERT_DATA) {
    _trap("retrieving parent of a nonexistent session")
      unless exists $kr_sessions{$session};
  }
  return $kr_sessions{$session}->[SS_PARENT];
}

### Get a session's children.

sub _data_ses_get_children {
  my ($self, $session) = @_;
  if (ASSERT_DATA) {
    _trap("retrieving children of a nonexistent session")
      unless exists $kr_sessions{$session};
  }
  return values %{$kr_sessions{$session}->[SS_CHILDREN]};
}

### Is a session a child of another?

sub _data_ses_is_child {
  my ($self, $parent, $child) = @_;
  if (ASSERT_DATA) {
    _trap("testing is-child of a nonexistent parent session")
      unless exists $kr_sessions{$parent};
  }
  return exists $kr_sessions{$parent}->[SS_CHILDREN]->{$child};
}

### Determine whether a session exists.  We should only need to verify
### this for sessions provided by the outside.  Internally, our code
### should be so clean it's not necessary.

sub _data_ses_exists {
  my ($self, $session) = @_;
  return exists $kr_sessions{$session};
}

### Resolve a session into its reference.

sub _data_ses_resolve {
  my ($self, $session) = @_;
  return undef unless exists $kr_sessions{$session}; # Prevents autoviv.
  return $kr_sessions{$session}->[SS_SESSION];
}

### Resolve a session ID into its reference.

sub _data_ses_resolve_to_id {
  my ($self, $session) = @_;
  return undef unless exists $kr_sessions{$session}; # Prevents autoviv.
  return $kr_sessions{$session}->[SS_ID];
}

### Decrement a session's main reference count.  This is called by
### each watcher when the last thing it watches for the session goes
### away.  In other words, a session's reference count should only
### enumerate the different types of things being watched; not the
### number of each.

sub _data_ses_refcount_dec {
  my ($self, $session) = @_;

  if (TRACE_REFCNT) {
    _warn(
      "<rc> decrementing refcount for ",
      $self->_data_alias_loggable($session)
    );
  }

  # -><- Why do we return if the session does not exist, but then confess
  # that there is a problem if the session does not exist?  One of
  # these must go!
  return unless exists $kr_sessions{$session};

  if (ASSERT_DATA) {
    _trap() unless exists $kr_sessions{$session};
  }

  $kr_sessions{$session}->[SS_REFCOUNT]--;

  if (ASSERT_DATA and $kr_sessions{$session}->[SS_REFCOUNT] < 0) {
    _trap(
      $self->_data_alias_loggable($session),
     " reference count went below zero"
   );
  }
}

### Increment a session's main reference count.

sub _data_ses_refcount_inc {
  my ($self, $session) = @_;

  if (TRACE_REFCNT) {
    _warn(
      "<rc> incrementing refcount for ",
      $self->_data_alias_loggable($session)
    );
  }

  if (ASSERT_DATA) {
    _trap "incrementing refcount for nonexistent session"
      unless exists $kr_sessions{$session};
  }

  $kr_sessions{$session}->[SS_REFCOUNT]++;
}

# Query a session's reference count.  Added for testing purposes.

sub _data_ses_refcount {
  my ($self, $session) = @_;
  return $kr_sessions{$session}->[SS_REFCOUNT];
}

### Determine whether a session is ready to be garbage collected.
### Free the session if it is.

sub _data_ses_collect_garbage {
  my ($self, $session) = @_;

  if (TRACE_REFCNT) {
    _warn(
      "<rc> testing for idle ",
      $self->_data_alias_loggable($session)
    );
  }

  # The next line is necessary for some strange reason.  This feels
  # like a kludge, but I'm currently not smart enough to figure out
  # what it's working around.

  if (ASSERT_DATA) {
    _trap() unless exists $kr_sessions{$session};
  }

  if (TRACE_REFCNT) {
    my $ss = $kr_sessions{$session};
    _warn(
      "<rc> +----- GC test for ", $self->_data_alias_loggable($session),
      " ($session) -----\n",
      "<rc> | total refcnt  : ", $ss->[SS_REFCOUNT], "\n",
      "<rc> | event count   : ", $self->_data_ev_get_count_to($session), "\n",
      "<rc> | post count    : ", $self->_data_ev_get_count_from($session), "\n",
      "<rc> | child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n",
      "<rc> | handles in use: ", $self->_data_handle_count_ses($session), "\n",
      "<rc> | aliases in use: ", $self->_data_alias_count_ses($session), "\n",
      "<rc> | extra refs    : ", $self->_data_extref_count_ses($session), "\n",
      "<rc> +---------------------------------------------------\n",
    );
    unless ($ss->[SS_REFCOUNT]) {
      _warn(
        "<rc> | ", $self->_data_alias_loggable($session),
        " is garbage; stopping it...\n",
        "<rc> +---------------------------------------------------\n",
      );
    }
  }

  if (ASSERT_DATA) {
    my $ss = $kr_sessions{$session};
    my $calc_ref =
      ( $self->_data_ev_get_count_to($session) +
        $self->_data_ev_get_count_from($session) +
        scalar(keys(%{$ss->[SS_CHILDREN]})) +
        $self->_data_handle_count_ses($session) +
        $self->_data_extref_count_ses($session) +
        $self->_data_alias_count_ses($session)
      );

    # The calculated reference count really ought to match the one
    # POE's been keeping track of all along.

    _trap(
      "<dt> ", $self->_data_alias_loggable($session),
       " has a reference count inconsistency",
       " (calc=$calc_ref; actual=$ss->[SS_REFCOUNT])\n"
     ) if $calc_ref != $ss->[SS_REFCOUNT];
  }

  return if $kr_sessions{$session}->[SS_REFCOUNT];

  $self->_data_ses_stop($session);
}

### Return the number of sessions we know about.

sub _data_ses_count {
  return scalar keys %kr_sessions;
}

### Close down a session by force.

# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

sub _data_ses_stop {
  my ($self, $session) = @_;

  if (TRACE_SESSIONS) {
    _warn("<ss> stopping ", $self->_data_alias_loggable($session));
  }

  if (ASSERT_DATA) {
    _trap unless exists $kr_sessions{$session};
  }

  $self->_dispatch_event
    ( $session, $self->get_active_session(),
      EN_STOP, ET_STOP, [],
      __FILE__, __LINE__, time(), -__LINE__
    );
}

1;

__END__

=head1 NAME

POE::Resources::Sessions - manage session data structures for POE::Kernel

=head1 SYNOPSIS

Used internally by POE::Kernel.  Better documentation will be
forthcoming.

=head1 DESCRIPTION

This module encapsulates and provides accessors for POE::Kernel's data
structures that manage sessions themselves.  It is used internally by
POE::Kernel and has no public interface.

=head1 SEE ALSO

See L<POE::Kernel> and L<POE::Session> for documentation on sessions.

=head1 BUGS

Probably.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
