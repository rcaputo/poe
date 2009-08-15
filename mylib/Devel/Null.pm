# This `perl -d` debugging module is an ad-hoc custom debugger.  It's
# optional, and it may not even work.

use strict;

package Null; # satisfies 'use'

package DB;
use vars qw($sub);
use Carp;

# This bit traces execution immediately before a given condition.
# It's used to find out where in hell something went wrong.
my @trace = ("no step") x 16;

sub DB {
  my ($package, $file, $line) = caller;

  my $discard = shift @trace;
  push @trace, "step @ $file:$line: ";

  if ( defined($POE::Kernel::poe_kernel)
       and @{$POE::Kernel::poe_kernel->[8]}
       and $POE::Kernel::poe_kernel->[8]->[0]->[2] =~ /\-\</
     ) {
    $| = 1;
    print join("\n", @trace), "\n";
    kill -9, $$;
    exit;
  }

#  print "step @ $file:$line\n";
}

sub sub {
  my ($package, $file, $line) = caller;
#  print "sub $sub @ $file:$line\n";
  no strict 'refs';
  &$sub;
}

1;
