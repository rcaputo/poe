#!/usr/bin/perl -w
# $Id$

# Rerun t/04_selects.t but with IO::Poll instead.

use strict;
use lib qw(./mylib ../mylib ../lib ./lib);
use TestSetup;

BEGIN {
  eval 'use IO::Poll';
  test_setup(0, "IO::Poll is needed for these tests")
    if length($@) or not exists $INC{'IO/Poll.pm'};
  test_setup(0, "IO::Poll 0.05 or newer is needed for these tests")
    if $IO::Poll::VERSION < 0.05;
}

require 't/04_selects.t';

exit;
