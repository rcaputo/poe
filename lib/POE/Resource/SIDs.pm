# $Id$

# Session IDs: The data to maintain them, and accessors to get at them
# sanely from other files.

package POE::Resources::SIDs;

use vars qw($VERSION);
$VERSION = (qw($Revision$))[1];

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

### Map session IDs to sessions.  Map sessions to session IDs.
### Maintain a sequence number for determining the next session ID.

my %kr_session_ids;
#  ( $session_id => $session_reference,
#    ...,
#  );

my %kr_session_to_id;
#  ( $session_ref => $session_id,
#    ...,
#  );

my $kr_sid_seq = 1;

sub _data_sid_initialize {
  $poe_kernel->[KR_SESSION_IDS] = \%kr_session_ids;
  $poe_kernel->[KR_SID_SEQ] = \$kr_sid_seq;
}
use POE::API::ResLoader \&_data_sid_initialize;

### End-run leak checking.

sub _data_sid_finalize {
  my $finalized_ok = 1;
  while (my ($sid, $ses) = each(%kr_session_ids)) {
    warn "!!! Leaked session ID: $sid = $ses\n";
    $finalized_ok = 0;
  }
  while (my ($ses, $sid) = each(%kr_session_to_id)) {
    warn "!!! Leak sid cross-reference: $ses = $sid\n";
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
  $kr_session_to_id{$session} = $sid;
}

### Clear a session ID.

sub _data_sid_clear {
  my ($self, $session) = @_;
  my $sid = delete $kr_session_to_id{$session};
  confess "internal inconsistency" unless defined $sid;
  delete $kr_session_ids{$sid};
}

### Resolve a session ID into its session.

sub _data_sid_resolve {
  my ($self, $sid) = @_;
  return $kr_session_ids{$sid};
}

1;

__END__

=head1 NAME

POE::Resources::SIDs - session ID management for POE::Kernel

=head1 SYNOPSIS

Used internally by POE::Kernel.  Better documentation will be
forthcoming.

=head1 DESCRIPTION

This module encapsulates and provides accessors for POE::Kernel's data
structures that manage session IDs.  It is used internally by
POE::Kernel and has no public interface.

=head1 SEE ALSO

See L<POE::Kernel> and L<POE::Session> for documentation about session
IDs.

=head1 BUGS

Probably.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
