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
