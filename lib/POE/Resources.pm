package POE::Resources;

use strict;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

my @resources = qw(
  POE::XS::Resource::Aliases
  POE::XS::Resource::Events
  POE::XS::Resource::Extrefs
  POE::XS::Resource::FileHandles
  POE::XS::Resource::SIDs
  POE::XS::Resource::Sessions
  POE::XS::Resource::Signals
  POE::XS::Resource::Statistics
);

sub initialize {
  my $package = (caller())[0];

  foreach my $resource (@resources) {
    eval "package $package; use $resource";
    if ($@) {
      redo if $@ =~ /^Can't locate/ and $resource =~ s/::XS::/::/;
      die;
    }
  }
}

1;
