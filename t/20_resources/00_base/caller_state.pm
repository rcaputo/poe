#!/usr/bin/perl -w

# Test that caller_state returnes expected results

use strict;

use lib qw(./mylib ../mylib);
use Test::More tests => 6;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN { use_ok("POE") } # 1

BEGIN { $^W = 1 };

POE::Session->create(
  inline_states => {
    _start       => sub {
    $_[KERNEL]->post($_[SESSION],'check_1');
    # set our callback and postback
    $_[HEAP]->{postback} = $_[SESSION]->postback("check_4");
    $_[HEAP]->{callback} = $_[SESSION]->callback("check_5");
    },
    check_1 => sub {
    if ($_[CALLER_STATE] eq '_start') {
      pass("called from _start"); # 2
    } else {
      diag("post failed: caller state is $_[CALLER_STATE] (should be _start)");
      fail("called from _start");
      delete $_[HEAP]->{callback};
      delete $_[HEAP]->{postback};
      return;
    }
    $_[KERNEL]->yield("check_2");
    },
  check_2 => sub {
    if ($_[CALLER_STATE] eq 'check_1') {
      pass("called from check_1"); # 3
    } else {
      diag("yield failed: caller state is $_[CALLER_STATE] (should be check_1)");
      fail("called from check_1");
      delete $_[HEAP]->{callback};
      delete $_[HEAP]->{postback};
      return;
    }
    # since we are calling check_3, and the postback calls check_4
    # the callback there will see it as if this session called it
    $_[KERNEL]->call($_[SESSION], "check_3");
  },
  check_3 => sub {
    if ($_[CALLER_STATE] eq 'check_2') {
      pass("called from check_2"); # 4
    } else {
      diag("call failed: caller state is $_[CALLER_STATE] (should be check_2)");
      fail("called from check_2");
      return;
    }
    my $postback = delete $_[HEAP]->{postback};
    $postback->();
  },
  check_4 => sub {
    # this _should_ look like it comes from check_2 because of the call()
    if ($_[CALLER_STATE] eq 'check_2') {
      pass("called from check_2 (again)"); # 5
    } else {
      diag("postback failed: caller state is $_[CALLER_STATE] (should be check_2)");
      fail("called from check_2");
    }
    my $callback = delete $_[HEAP]->{callback};
    $callback->();
  },
  check_5 => sub {
    if ($_[CALLER_STATE] eq 'check_4') {
      pass("called from check_4"); # 6
    } else {
      diag("callback failed: caller state is $_[CALLER_STATE] (should be check_4)");
      fail("called from check_4");
    }  
  },
  _stop => sub { }
  }
);

POE::Kernel->run();

1;
