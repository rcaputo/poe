# Session IDs: The data to maintain them, and accessors to get at them
# sanely from other files.

package POE::Resource::SIDs;

use warnings;
use strict;


use vars qw($VERSION);
$VERSION = '1.358'; # NOTE - Should be #.### (three decimal places)


use constant {
  MEMB_SESSIONS => 0,
  MEMB_SEQUENCE => 1,

  ASSERT_DATA   => POE::Kernel::ASSERT_DATA(),
};


sub new {
  my ($class) = @_;

  return bless [
    { }, # MEMB_SESSIONS
    0,   # MEMB_SEQUENCE
  ], $class;
}


sub finalize {
  my ($self) = @_;

  my $finalized_ok = 1;
  while (my ($sid, $ses) = each(%{ $self->[MEMB_SESSIONS] })) {
    POE::Kernel::_warn("!!! Leaked session ID: $sid = $ses\n");
    $finalized_ok = 0;
  }

  return $finalized_ok;
}


sub allocate {
  my ($self) = @_;

  my $seq = $self->[MEMB_SEQUENCE];
  1 while exists $self->[MEMB_SESSIONS]{++$seq};
  $self->[MEMB_SEQUENCE] = $seq;

  return $seq;
}


sub set {
  my ($self, $sid, $session) = @_;
  $self->[MEMB_SESSIONS]{$sid} = $session;
}


sub clear_session {
  my ($self, $sid) = @_;

  return delete $self->[MEMB_SESSIONS]{$sid} unless ASSERT_DATA;

  my $removed = delete $self->[MEMB_SESSIONS]{$sid};
  POE::Kernel::_trap("unknown SID '$sid'") unless defined $removed;
  $removed;
}


sub resolve {
  my ($self, $sid) = @_;
  return(
    exists($self->[MEMB_SESSIONS]{$sid})
    ? $self->[MEMB_SESSIONS]{$sid}
    : undef
  );
}


sub reset_id {
  my ($self, $old_id, $new_id) = @_;

  if (ASSERT_DATA) {
    POE::Kernel::_trap("unknown old SID '$old_id'") unless (
      exists $self->[MEMB_SESSIONS]{$old_id}
    );
    POE::Kernel::_trap("new SID '$new_id' already taken'") if (
      exists $self->[MEMB_SESSIONS]{$new_id}
    );
  }

  $self->[MEMB_SESSIONS]{$new_id} = delete $self->[MEMB_SESSIONS]{$old_id};
}


1;

__END__

=head1 NAME

POE::Resource::SIDs - Helper class to manage session IDs for POE::Kernel

=head1 SYNOPSIS

There is no public API.

=head1 DESCRIPTION

POE uses POE::Resource::SIDs internally to manage session IDs.

=head1 SEE ALSO

See L<POE::Kernel/Session Identifiers (IDs and Aliases)> for more
information about session IDs.

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
