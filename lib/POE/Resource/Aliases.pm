# Manage the POE::Kernel data structures necessary to keep track of
# session aliases.

package POE::Resource::Aliases;

use vars qw($VERSION);
$VERSION = '1.312'; # NOTE - Should be #.### (three decimal places)

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

### The table of session aliases, and the sessions they refer to.

my %kr_aliases;
#  ( $alias => $session_ref,
#    ...,
#  );

my %kr_ses_to_alias;
#  ( $session_id =>
#    { $alias => $session_ref,
#      ...,
#    },
#    ...,
#  );

sub _data_alias_initialize {
  $poe_kernel->[KR_ALIASES] = \%kr_aliases;
}

sub _data_alias_relocate_kernel_id {
  my ($self, $old_id, $new_id) = @_;
  return unless exists $kr_ses_to_alias{$old_id};
  $kr_ses_to_alias{$new_id} = delete $kr_ses_to_alias{$old_id};
}

### End-run leak checking.  Returns true if finalization was ok, or
### false if it failed.

sub _data_alias_finalize {
  my $finalized_ok = 1;
  while (my ($alias, $ses) = each(%kr_aliases)) {
    _warn "!!! Leaked alias: $alias = $ses\n";
    $finalized_ok = 0;
  }
  while (my ($ses_id, $alias_rec) = each(%kr_ses_to_alias)) {
    my @aliases = keys(%$alias_rec);
    _warn "!!! Leaked alias cross-reference: $ses_id (@aliases)\n";
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

sub _data_alias_add {
  my ($self, $session, $alias) = @_;
  $self->_data_ses_refcount_inc($session->ID);
  $kr_aliases{$alias} = $session;
  $kr_ses_to_alias{$session->ID}->{$alias} = $session;
}

# Remove an alias from a session.
#
# TODO Happily allows the removal of aliases from sessions that don't
# exist.  This will cause problems with reference counting.

sub _data_alias_remove {
  my ($self, $session, $alias) = @_;
  delete $kr_aliases{$alias};
  delete $kr_ses_to_alias{$session->ID}->{$alias};
  $self->_data_ses_refcount_dec($session->ID);
}

### Clear all the aliases from a session.

sub _data_alias_clear_session {
  my ($self, $sid) = @_;
  return unless exists $kr_ses_to_alias{$sid}; # avoid autoviv
  while (my ($alias, $ses_ref) = each %{$kr_ses_to_alias{$sid}}) {
    $self->_data_alias_remove($ses_ref, $alias);
  }
  delete $kr_ses_to_alias{$sid};
}

### Resolve an alias.  Just an alias.

sub _data_alias_resolve {
  my ($self, $alias) = @_;
  return undef unless exists $kr_aliases{$alias};
  return $kr_aliases{$alias};
}

### Return a list of aliases for a session.

sub _data_alias_list {
  my ($self, $sid) = @_;
  return () unless exists $kr_ses_to_alias{$sid};
  return sort keys %{$kr_ses_to_alias{$sid}};
}

### Return the number of aliases for a session.

sub _data_alias_count_ses {
  my ($self, $sid) = @_;
  return 0 unless exists $kr_ses_to_alias{$sid};
  return scalar keys %{$kr_ses_to_alias{$sid}};
}

### Return a session's ID in a form suitable for logging.

sub _data_alias_loggable {
  my ($self, $sid) = @_;
  "session $sid" . (
    (exists $kr_ses_to_alias{$sid})
    ? ( " (" . join(", ", $self->_data_alias_list($sid)) . ")" )
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

See L<POE::Kernel/Resources> for for public information about POE
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
