#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

use POE::API::ResLoader;

{ my $called_initializer = 0;
  POE::API::ResLoader->import( sub { $called_initializer++ } );
  ok($called_initializer == 1, "called initializer");
}

{ my $called_initializer = 0;
  POE::API::ResLoader->import( { }, sub { $called_initializer++ } );
  ok($called_initializer == 0, "didn't call second import parameter");
}

exit 0;
