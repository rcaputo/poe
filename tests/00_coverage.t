#!/usr/bin/perl -w
# $Id$

# This test merely loads as many modules as possible so that the
# coverage tester will see them.  It's performs a similar function as
# the FreeBSD LINT kernel configuration.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(20);

sub load_optional_module {
  my ($test_number, $module) = @_;
  stderr_pause();
  eval "package Test::Number_$test_number; use $module";
  stderr_resume();
  my $reason = $@;
  $reason =~ s/[\x0a\x0d]+/ \/ /g;
  $reason =~ tr[ ][ ]s;

  # Make skip messages look more proper.
  if ($reason =~ /Can\'t locate (.*?) in \@INC/) {
    $reason = "$1 is needed for this test.";
  }
  elsif ($reason =~ /(\S+) not implemented on this architecture/) {
    $reason = "$^O does not support $1.";
  }
  elsif ($reason =~ /Can\'t find a valid termcap file/) {
    $reason = "Term::Cap did not find a valid termcap file.";
  }
  elsif ($reason =~ /^[^\/]*does not[^\/]*?support[^\/]*/) {
    $reason =~ s/\s*\/.+$//g;
  }
  elsif ($reason =~ /Unable to get Terminal Size/i) {
    $reason =~ s/\. at.*//;
  }

  print( "ok $test_number",
         ( (length $reason) ? " # skipped: $reason" : '' ),
         "\n"
       );
}

sub load_required_module {
  my ($test_number, $module) = @_;
  eval "package Test::Number_$test_number; use $module";
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

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

&load_required_module( 1, 'POE'); # includes POE::Kernel and POE::Session

# Avoid two warnings.  First, that run() wasn't called; second, that
# $POE::Kernel::poe_kernel was only used once.
$POE::Kernel::poe_kernel->run();
$POE::Kernel::poe_kernel->run();

&load_required_module( 2, 'POE::NFA');
&load_required_module( 3, 'POE::Filter::Line');
&load_required_module( 4, 'POE::Filter::Stream');
&load_required_module( 5, 'POE::Wheel::ReadWrite');
&load_required_module( 6, 'POE::Wheel::SocketFactory');

# Optional modules now.

&load_optional_module( 7, 'POE::Component::Server::TCP');
&load_optional_module( 8, 'POE::Filter::HTTPD');
&load_optional_module( 9, 'POE::Filter::Reference');
&load_optional_module(10, 'POE::Wheel::FollowTail');
&load_optional_module(11, 'POE::Wheel::ListenAccept');
&load_optional_module(12, 'POE::Wheel::ReadLine');
&load_optional_module(13, 'POE::Wheel::Run');
&load_optional_module(14, 'POE::Wheel::Curses');
&load_optional_module(15, 'POE::Filter::Block');

# Seriously optional modules.

&load_optional_module(16, 'POE::Component');
&load_optional_module(17, 'POE::Driver');
&load_optional_module(18, 'POE::Wheel');
&load_optional_module(19, 'POE::Filter');

# And one to grow on.

print "ok 20\n";

exit;
