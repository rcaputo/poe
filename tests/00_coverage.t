#!/usr/bin/perl -w
# $Id$

# This test merely loads as many modules as possible so that the
# coverage tester will see them.  It's performs a similar function as
# the FreeBSD LINT kernel configuration.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(12);

sub load_optional_module {
  my ($test_number, $module) = @_;
  eval "use $module";
  my $reason = $@;
  $reason =~ s/[\x0a\x0d]+/ \/ /g;
  $reason =~ tr[ ][ ]s;
  print( "ok $test_number",
         ( (length $reason) ? " # skipped: $reason" : '' ),
         "\n"
       );
}

sub load_required_module {
  my ($test_number, $module) = @_;
  eval "use $module";
  my $reason = $@;
  $reason =~ s/[\x0a\x0d]+/ \/ /g;
  $reason =~ tr[ ][ ]s;
  if (length $reason) {
    print "not ok $test_number # $reason\n";
  }
  else {
    print "ok $test_number\n";
  }
}

# Required modules first.

&load_required_module( 1, 'POE'); # includes POE::Kernel and POE::Session
&load_required_module( 2, 'POE::Filter::Line');
&load_required_module( 3, 'POE::Filter::Stream');
&load_required_module( 4, 'POE::Wheel::ReadWrite');
&load_required_module( 5, 'POE::Wheel::SocketFactory');

# Optional modules now.

&load_optional_module( 6, 'POE::Component::Server::TCP');
&load_optional_module( 7, 'POE::Filter::HTTPD');
&load_optional_module( 8, 'POE::Filter::Reference');
&load_optional_module( 9, 'POE::Wheel::FollowTail');
&load_optional_module(10, 'POE::Wheel::ListenAccept');
&load_optional_module(11, 'POE::Filter::Block');

# And one to grow on.

print "ok 12\n";

exit;
