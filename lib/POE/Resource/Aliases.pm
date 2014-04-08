# Manage the POE::Kernel data structures necessary to keep track of
# session aliases.

package POE::Resource::Aliases;

use warnings;
use strict;


use vars qw($VERSION);
$VERSION = '1.358'; # NOTE - Should be #.### (three decimal places)


use constant {
  MEMB_ALIAS_TO_SESSION => 0,
  MEMB_SID_ALIASES      => 1,
};


sub new {
  my ($class) = @_;

  return bless [
    { }, # MEMB_ALIAS_TO_SESSION
    { }, # MEMB_SID_ALIASES
  ], $class;
}


sub reset_id {
  my ($self, $old_id, $new_id) = @_;

  return unless exists $self->[MEMB_SID_ALIASES]{$old_id};
  $self->[MEMB_SID_ALIASES]{$new_id} = delete(
    $self->[MEMB_SID_ALIASES]{$old_id}
  );
}


sub finalize {
  my ($self) = @_;

  my $finalized_ok = 1;
  while (my ($alias, $ses) = each(%{ $self->[MEMB_ALIAS_TO_SESSION] })) {
    POE::Kernel::_warn("!!! Leaked alias: $alias = $ses\n");
    $finalized_ok = 0;
  }

  while (my ($ses_id, $alias_rec) = each(%{ $self->[MEMB_SID_ALIASES] })) {
    my @aliases = keys(%$alias_rec);
    POE::Kernel::_warn(
      "!!! Leaked alias cross-reference: $ses_id (@aliases)\n"
    );
    $finalized_ok = 0;
  }

  return $finalized_ok;
}


# Add an alias to a session.
#
# TODO This has a potential problem: setting the same alias twice on a
# session will increase the session's reference count twice.  Removing
# the alias will only decrement it once.  That potentially causes
# reference counts that never go away.  The public interface for this
# function, alias_set(), does not allow this to occur.  We should add
# a test to make sure it never does.
#
# TODO It is possible to add aliases to sessions that do not exist.
# The public alias_set() function prevents this from happening.

sub add {
  my ($self, $session, $alias) = @_;
  my $sid = $session->ID();
  $POE::Kernel::poe_kernel->_data_ses_refcount_inc($sid);
  $self->[MEMB_ALIAS_TO_SESSION]{$alias} = $session;
  $self->[MEMB_SID_ALIASES]{$sid}{$alias} = $session;
}


# Remove an alias from a session.
#
# TODO Happily allows the removal of aliases from sessions that don't
# exist.  This will cause problems with reference counting.

sub remove {
  my ($self, $session, $alias) = @_;
  my $sid = $session->ID();
  delete $self->[MEMB_ALIAS_TO_SESSION]{$alias};
  delete $self->[MEMB_SID_ALIASES]{$sid}{$alias};
  delete $self->[MEMB_SID_ALIASES]{$sid} unless (
    scalar keys %{ $self->[MEMB_SID_ALIASES]{$sid} }
  );

  $POE::Kernel::poe_kernel->_data_ses_refcount_dec($sid);
}


### Clear all the aliases from a session.

sub clear_session {
  my ($self, $sid) = @_;
  return unless exists $self->[MEMB_SID_ALIASES]{$sid}; # avoid autoviv
  while (my ($alias, $ses_ref) = each %{ $self->[MEMB_ALIAS_TO_SESSION] }) {
    $self->remove($ses_ref, $alias);
  }
  delete $self->[MEMB_SID_ALIASES]{$sid};
}


sub resolve {
  my ($self, $alias) = @_;
  return(
    (exists $self->[MEMB_ALIAS_TO_SESSION]{$alias})
    ? $self->[MEMB_ALIAS_TO_SESSION]{$alias}
    : undef
  );
}


sub get_sid_aliases {
  my ($self, $sid) = @_;

  return () unless exists $self->[MEMB_SID_ALIASES]{$sid};

  # Sorted for determinism.
  # TODO - Not everyone needs them sorted.
  # TODO - Probably should delegate the sort to the users who do.
  return sort keys %{$self->[MEMB_SID_ALIASES]{$sid}};
}


sub count_for_session {
  my ($self, $sid) = @_;
  return 0 unless exists $self->[MEMB_SID_ALIASES]{$sid};
  return scalar keys %{$self->[MEMB_SID_ALIASES]{$sid}};
}


sub loggable_sid {
  my ($self, $sid) = @_;
  my @aliases = $self->get_sid_aliases($sid);
  "session $sid" . (
    (@aliases)
    ? ( " (" . join(", ", @aliases). ")" )
    : ""
  );
}


1;

__END__

=head1 NAME

POE::Resource::Aliases - internal session alias manager for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::Aliases is a mix-in class for POE::Kernel.  It provides
the features to manage session aliases.  It is used internally by
POE::Kernel, so it has no public interface.

=head1 SEE ALSO

See L<POE::Kernel/Session Identifiers (IDs and Aliases)> for the
public alias API.

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
