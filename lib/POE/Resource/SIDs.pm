# Session IDs: The data to maintain them, and accessors to get at them
# sanely from other files.

package POE::Resource::SIDs;

use vars qw($VERSION);
$VERSION = '1.299'; # NOTE - Should be #.### (three decimal places)

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

### Map session IDs to sessions.  Map sessions to session IDs.
### Maintain a sequence number for determining the next session ID.

my %kr_session_ids;
#  ( $session_id => $session_reference,
#    ...,
#  );

my $kr_sid_seq = 0;

sub _data_sid_initialize {
  $poe_kernel->[KR_SESSION_IDS] = \%kr_session_ids;
  $poe_kernel->[KR_SID_SEQ] = \$kr_sid_seq;
}

sub _data_sid_relocate_kernel_id {
  my ($self, $old_id, $new_id) = @_;
  $kr_session_ids{$new_id} = delete $kr_session_ids{$old_id}
    if exists $kr_session_ids{$old_id};
}

### End-run leak checking.

sub _data_sid_finalize {
  my $finalized_ok = 1;
  while (my ($sid, $ses) = each(%kr_session_ids)) {
    _warn "!!! Leaked session ID: $sid = $ses\n";
    $finalized_ok = 0;
  }
  return $finalized_ok;
}

### Allocate a new session ID.

sub _data_sid_allocate {
  my $self = shift;
  1 while exists $kr_session_ids{++$kr_sid_seq};
  return $kr_sid_seq;
}

### Set a session ID.

sub _data_sid_set {
  my ($self, $sid, $session) = @_;
  $kr_session_ids{$sid} = $session;
}

### Clear a session ID.

sub _data_sid_clear {
  my ($self, $sid) = @_;

  return delete $kr_session_ids{$sid} unless ASSERT_DATA;

  my $removed = delete $kr_session_ids{$sid};
  _trap("unknown SID '$sid'") unless defined $removed;
  $removed;
}

### Resolve a session ID into its session.

sub _data_sid_resolve {
  my ($self, $sid) = @_;
  return $kr_session_ids{$sid};
}

1;

__END__

=head1 NAME

POE::Resource::SIDs - internal session ID manager for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE::Resource::SIDs is a mix-in class for POE::Kernel.  It provides
the features necessary to manage session IDs.  It is used internally
by POE::Kernel, so it has no public interface.

=head1 SEE ALSO

See L<POE::Kernel/Session Identifiers (IDs and Aliases)> for more
information about session IDs.

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
