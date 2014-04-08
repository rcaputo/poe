# The data necessary to manage tagged extra/external reference counts
# on sessions, and the accessors to get at them sanely from other
# files.

package POE::Resource::Extrefs;

use warnings;
use strict;


use vars qw($VERSION);
$VERSION = '1.358'; # NOTE - Should be #.### (three decimal places)


use constant {
  MEMB_REFERENCES => 0,

  TRACE_REFCNT => POE::Kernel::TRACE_REFCNT(),
  ASSERT_DATA => POE::Kernel::ASSERT_DATA(),
};


sub new {
  my ($class) = @_;

  return bless [
    { },   # MEMB_REFERENCES
  ], $class;
}


### End-run leak checking.

sub finalize {
  my ($self) = @_;

  my $finalized_ok = 1;
  foreach my $session_id (keys %{ $self->[MEMB_REFERENCES] }) {
    $finalized_ok = 0;
    POE::Kernel::_warn("!!! Leaked extref: $session_id\n");
    foreach my $tag (keys %{$self->[MEMB_REFERENCES]{$session_id}} ) {
      POE::Kernel::_warn(
        "!!!\t`$tag' = $self->[MEMB_REFERENCES]{$session_id}->{$tag}\n"
      );
    }
  }

  return $finalized_ok;
}


# Increment a session's tagged reference count.  If this is the first
# time the tag is used in the session, then increment the session's
# reference count as well.  Returns the tag's new reference count.
#
# Allows incrementing reference counts on sessions that don't exist,
# but the public interface catches that.
#
# TODO Need to track extref ownership for signal-based session
# termination.  One problem seen is that signals terminate sessions
# out of order.  Owners think extra refcounts exist for sessions that
# are no longer around.  Ownership trees give us a few benefits: We
# can make sure sessions destruct in a cleaner order.  We can detect
# refcount loops and possibly prevent that.

sub increment {
  my ($self, $sid, $tag) = @_;

  my $new_refcount = ++$self->[MEMB_REFERENCES]{$sid}{$tag};
  POE::Kernel->_data_ses_refcount_inc($sid) if $new_refcount == 1;

  if (TRACE_REFCNT) {
    POE::Kernel::_warn(
      "<rc> incremented extref ``$tag'' (now $new_refcount) for ",
      $POE::Kernel::poe_kernel->[POE::Kernel::KR_ALIASES()]->loggable_sid($sid)
    );
  }

  return $new_refcount;
}


# Decrement a session's tagged reference count, removing it outright
# if the count reaches zero.  Return the new reference count or undef
# if the tag doesn't exist.
#
# TODO Allows negative reference counts, and the resulting hilarity.
# Hopefully the public interface won't allow it.

sub decrement {
  my ($self, $sid, $tag) = @_;

  if (ASSERT_DATA) {
    # Prevents autoviv.
    POE::Kernel::_trap("<dt> decrementing extref for session without any")
      unless exists $self->[MEMB_REFERENCES]{$sid};

    unless (exists $self->[MEMB_REFERENCES]{$sid}{$tag}) {
      POE::Kernel::_trap(
        "<dt> decrementing extref for nonexistent tag ``$tag'' in ",
        $POE::Kernel::poe_kernel->[POE::Kernel::KR_ALIASES()]->loggable_sid(
          $sid
        )
      );
    }
  }

  my $refcount = --$self->[MEMB_REFERENCES]{$sid}{$tag};

  if (TRACE_REFCNT) {
    POE::Kernel::_warn(
      "<rc> decremented extref ``$tag'' (now $refcount) for ",
      $POE::Kernel::poe_kernel->[POE::Kernel::KR_ALIASES()]->loggable_sid($sid)
    );
  }

  $self->remove($sid, $tag) unless $refcount;
  return $refcount;
}


### Remove an extra reference from a session, regardless of its count.

sub remove {
  my ($self, $sid, $tag) = @_;

  if (ASSERT_DATA) {
    # Prevents autoviv.
    POE::Kernel::_trap("<dt> removing extref from session without any") unless (
      exists $self->[MEMB_REFERENCES]{$sid}
    );

    unless (exists $self->[MEMB_REFERENCES]{$sid}{$tag}) {
      POE::Kernel::_trap(
        "<dt> removing extref for nonexistent tag ``$tag'' in ",
        $POE::Kernel::poe_kernel->[POE::Kernel::KR_ALIASES()]->loggable_sid(
          $sid
        )
      );
    }
  }

  delete $self->[MEMB_REFERENCES]{$sid}{$tag};
  delete $self->[MEMB_REFERENCES]{$sid} unless (
    scalar keys %{$self->[MEMB_REFERENCES]{$sid}}
  );

  POE::Kernel->_data_ses_refcount_dec($sid);
}


### Clear all the extra references from a session.

sub clear_session {
  my ($self, $sid) = @_;

  return unless exists $self->[MEMB_REFERENCES]{$sid}; # avoid autoviv

  foreach (keys %{$self->[MEMB_REFERENCES]{$sid}}) {
    $self->remove($sid, $_);
  }

  if (ASSERT_DATA) {
    if (exists $self->[MEMB_REFERENCES]{$sid}) {
      POE::Kernel::_trap(
        "<dt> extref clear did not remove session ",
        $POE::Kernel::poe_kernel->[POE::Kernel::KR_ALIASES()]->loggable_sid(
          $sid
        )
      );
    }
  }
}


# A POE::Kernel session ID must be unique, even in an instance created
# by fork().

sub reset_id {
  my ($self, $old_id, $new_id) = @_;

  if (ASSERT_DATA) {
    POE::Kernel::_trap("unknown old SID '$old_id'") unless (
      exists $self->[MEMB_REFERENCES]{$old_id}
    );
    POE::Kernel::_trap("new SID '$new_id' already taken'") if (
      exists $self->[MEMB_REFERENCES]{$new_id}
    );
  }

  $self->[MEMB_REFERENCES]{$new_id} = delete $self->[MEMB_REFERENCES]{$old_id};
}


# Fetch the number of sessions with extra references held in the
# entire system.

sub count_sessions {
  my ($self) = @_;
  return scalar keys %{ $self->[MEMB_REFERENCES] };
}


# Fetch whether a session has extra references.

sub count_session_refs {
  my ($self, $sid) = @_;

  return 0 unless exists $self->[MEMB_REFERENCES]{$sid};
  return scalar keys %{$self->[MEMB_REFERENCES]{$sid}};
}

1;

__END__

=head1 NAME

POE::Resource::Extrefs - POE::Kernel internal extra references manager

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::Extrefs manages extra reference counts for POE::Kernel.
It provides the features to manage session reference counts, in
particular the ones that applications may use.  POE::Resource::Extrefs
is used internally by POE::Kernel, so it has no public interface.

=head1 SEE ALSO

See L<POE::Kernel/Public Reference Counters> for the public extref
API.

See L<POE::Kernel/Resources> for public information about POE
resources.

See L<POE::Resource> for general discussion about resources and the
classes that manage them.

=head1 BUGS

Reference counters have no ownership information, so one entity's
reference counts may conflict with another's.  This is usually not a
problem if all entities behave.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Edit.
