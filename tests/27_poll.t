#!/usr/bin/perl -w
# $Id$

# Rerun t/04_selects.t but with IO::Poll instead.

use strict;
use lib qw(./lib ../lib);
use TestSetup;

BEGIN {
  eval 'use IO::Poll';
  &test_setup(0, "need IO::Poll to test POE's support for that module")
    if length($@) or not exists $INC{'IO/Poll.pm'};
}

require 't/04_selects.t';

exit;
