package POE::Resources;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

my @resources = qw(
  POE::XS::Resource::Aliases
  POE::XS::Resource::Events
  POE::XS::Resource::Extrefs
  POE::XS::Resource::FileHandles
  POE::XS::Resource::SIDs
  POE::XS::Resource::Sessions
  POE::XS::Resource::Signals
  POE::XS::Resource::Statistics
  POE::XS::Resource::Controls
);

sub initialize {
  my $package = (caller())[0];

  foreach my $resource (@resources) {
    eval "package $package; use $resource";
    if ($@) {
      # Retry the resource, removing XS:: if it couldn't be loaded.
      # If there's no XS:: to be removed, fall through and die.
      redo if $@ =~ /Can't locate.*?in \@INC/ and $resource =~ s/::XS::/::/;
      die;
    }
  }
}

1;

__END__

=head1 NAME

POE::Resources - loader of POE resources

=head1 SYNOPSIS

  POE::Resources->initialize(); # intended to be used within the kernel

=head1 DESCRIPTION

Internally POE's kernel is split up into the different resources that it
manages.  Each resource may be handled by a pure perl module, or by an
XS module.  This module is used internally by the kernel to load the
correct modules.

For each resource type, initialize first tries to load C<POE::XS::Resource::*>
and then falls back to C<POE::Resource::*>.

=head1 SEE ALSO

L<POE::Resource>

=head1 AUTHORS & LICENSING

Please see L<POE> for more information about its authors,
contributors, and POE's licensing.

=cut
