# $Id$

# The data necessary to manage tagged extra/external reference counts
# on sessions, and the accessors to get at them sanely from other
# files.

package POE::Resources::Extrefs;

use vars qw($VERSION);
$VERSION = (qw($Revision$))[1];

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

### The count of all extra references used in the system.

my %kr_extra_refs;
#  ( $session =>
#    { $tag => $count,
#       ...,
#     },
#     ...,
#   );

### End-run leak checking.

sub _data_extref_finalize {
  my $finalized_ok = 1;
  foreach my $session (keys %kr_extra_refs) {
    $finalized_ok = 0;
    warn "!!! Leaked extref: $session\n";
    foreach my $tag (keys %{$kr_extra_refs{$session}}) {
      warn "!!!\t`$tag' = $kr_extra_refs{$session}->{$tag}\n";
    }
  }
  return $finalized_ok;
}

# Increment a session's tagged reference count.  If this is the first
# time the tag is used in the session, then increment the session's
# reference count as well.  Returns the tag's new reference count.
#
# -><- Allows incrementing reference counts on sessions that don't
# exist, but the public interface catches that.

sub _data_extref_inc {
  my ($self, $session, $tag) = @_;
  my $refcount = ++$kr_extra_refs{$session}->{$tag};

  $self->_data_ses_refcount_inc($session) if $refcount == 1;

  if (TRACE_REFCNT) {
    warn( "<rc> incremented extref ``$tag'' (now $refcount) for ",
          $self->_data_alias_loggable($session)
        );
  }

  return $refcount;
}

# Decrement a session's tagged reference count, removing it outright
# if the count reaches zero.  Return the new reference count or undef
# if the tag doesn't exist.
#
# -><- Allows negative reference counts, and the resulting hilarity.
# Hopefully the public interface won't allow it.

sub _data_extref_dec {
  my ($self, $session, $tag) = @_;

  if (ASSERT_DATA) {
    unless (exists $kr_extra_refs{$session}->{$tag}) {
      confess( "<dt> decrementing extref for nonexistent tag ``$tag'' in ",
               $self->_data_alias_loggable($session)
             );
    }
  }

  my $refcount = --$kr_extra_refs{$session}->{$tag};

  if (TRACE_REFCNT) {
    warn( "<rc> decremented extref ``$tag'' (now $refcount) for ",
          $self->_data_alias_loggable($session)
        );
  }

  $self->_data_extref_remove($session, $tag) unless $refcount;
  return $refcount;
}

### Remove an extra reference from a session, regardless of its count.

sub _data_extref_remove {
  my ($self, $session, $tag) = @_;

  if (ASSERT_DATA) {
    unless (exists $kr_extra_refs{$session}->{$tag}) {
      confess( "<dt> decrementing extref for nonexistent tag ``$tag'' in ",
               $self->_data_alias_loggable($session)
             );
    }
  }

  delete $kr_extra_refs{$session}->{$tag};
  $self->_data_ses_refcount_dec($session);
  unless (keys %{$kr_extra_refs{$session}}) {
    delete $kr_extra_refs{$session};
  }
}

### Clear all the extra references from a session.

sub _data_extref_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_extra_refs{$session}; # avoid autoviv
  foreach (keys %{$kr_extra_refs{$session}}) {
    $self->_data_extref_remove($session, $_);
  }

  if (ASSERT_DATA) {
    if (exists $kr_extra_refs{$session}) {
      confess( "<dt> extref clear did not remove session ",
               $self->_data_alias_loggable($session)
             );
    }
  }
}

# Fetch the number of sessions with extra references held in the
# entire system.

sub _data_extref_count {
  return scalar keys %kr_extra_refs;
}

# Fetch whether a session has extra references.

sub _data_extref_count_ses {
  my ($self, $session) = @_;
  return 0 unless exists $kr_extra_refs{$session};
  return scalar keys %{$kr_extra_refs{$session}};
}

1;

__END__

=head1 NAME

POE::Resources::Extrefs - tagged "extra" ref. count management for POE::Kernel

=head1 SYNOPSIS

Used internally by POE::Kernel.  Better documentation will be
forthcoming.

=head1 DESCRIPTION

This module encapsulates and provides accessors for POE::Kernel's data
structures that manage tagged reference counts.  It is used internally
by POE::Kernel and has no public interface.

=head1 SEE ALSO

See L<POE::Kernel> for documentation on tagged reference counts.

=head1 BUGS

There is no mechanism in place to prevent extra reference count names
from clashing.

Probably others.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
