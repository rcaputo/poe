#!perl -w -I..
# $Id$

# Part 2 of 2 for the Filter::Reference test.  This program
# sends references to a running copy of refserver.perl.

# Contributed by Artur Bergman <artur@vogon-solutions.com>

use strict;
use IO::Socket;

BEGIN {
  eval {
    require Storable;
    import Storable qw(freeze thaw);
  };
  if ($@ ne '') {
    eval {
      require FreezeThaw;
      import FreezeThaw qw(freeze thaw);
    };
  }
  if ($@ ne '') {
    die "Filter::Reference requires Storable or FreezeThaw";
  }
}

my $socket = new IO::Socket::INET(PeerAddr => '127.0.0.1:31338', # eleet++
				  Reuse => '1',
				  Proto => 'tcp',
				 );

sub refsend {
  my $ref = shift;
  my $req = freeze($ref);
  print $socket (sprintf "%05d", length($req)).$req;
}
                                        # hash
{
  my $request =
    bless { site => 'wdb',
            id => '1',
          }, 'kristoffer';
  &refsend($request);
}
                                        # array
{
  my $request =
    bless [ qw(these are elements of a test array) ], 'eberhard';
  &refsend($request);
}
                                        # scalar
{
  my $scalar = 'this is a scalar';
  my $request =
    bless \$scalar, 'roch';
  &refsend($request);
}
