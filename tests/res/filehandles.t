#!/usr/bin/perl -w
# $Id$

use strict;

use lib qw(./mylib ../mylib . ..);
use TestSetup;

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

use POE;
use POE::Pipe::TwoWay;

# Bring in some constants to save us some typing.
sub MODE_RD () { POE::Kernel::MODE_RD }
sub MODE_WR () { POE::Kernel::MODE_WR }
sub MODE_EX () { POE::Kernel::MODE_EX }

sub HS_RUNNING () { POE::Kernel::HS_RUNNING }
sub HS_PAUSED  () { POE::Kernel::HS_PAUSED  }
sub HS_STOPPED () { POE::Kernel::HS_STOPPED }

sub HSS_HANDLE  () { POE::Kernel::HSS_HANDLE  }
sub HSS_SESSION () { POE::Kernel::HSS_SESSION }
sub HSS_STATE   () { POE::Kernel::HSS_STATE   }

sub SH_HANDLE    () { POE::Kernel::SH_HANDLE    }
sub SH_REFCOUNT  () { POE::Kernel::SH_REFCOUNT  }
sub SH_MODECOUNT () { POE::Kernel::SH_MODECOUNT }

test_setup(208);

# Get a baseline reference count for the session, to use as
# comparison.
my $base_refcount = $poe_kernel->_data_ses_refcount($poe_kernel);

# We need some file handles to work with.
my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new("inet");
ok_if(1, defined $a_read);

# Add a filehandle in read mode.

$poe_kernel->_data_handle_add($a_read, MODE_RD, $poe_kernel, "event-rd");

# Verify reference counts.

ok_if(2, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1);

{ my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_read)
  );
  ok_if(3, $tot == 1);
  ok_if(4, $rd  == 1);
  ok_if(5, $wr  == 0);
  ok_if(6, $ex  == 0);
}

{ my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_read)
  );
  ok_if(7, $rd == 0);
  ok_if(8, $wr == 0);
  ok_if(9, $ex == 0);
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(10, $r_act == HS_RUNNING);
  ok_if(11, $r_req == HS_RUNNING);
  ok_if(12, $w_act == HS_PAUSED);
  ok_if(13, $w_req == HS_PAUSED);
  ok_if(14, $e_act == HS_PAUSED);
  ok_if(15, $e_req == HS_PAUSED);
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($a_read));

  ok_if(16, scalar keys %$ses_r == 1);
  ok_if(17, scalar keys %$ses_w == 0);
  ok_if(18, scalar keys %$ses_e == 0);

  ok_if(19, exists $ses_r->{$poe_kernel});
  ok_if(20, scalar keys %{$ses_r->{$poe_kernel}} == 1);
  ok_if(21, exists $ses_r->{$poe_kernel}{$a_read});
  ok_if(22, $ses_r->{$poe_kernel}{$a_read}[HSS_HANDLE] == $a_read);
  ok_if(23, $ses_r->{$poe_kernel}{$a_read}[HSS_SESSION] == $poe_kernel);
  ok_if(24, $ses_r->{$poe_kernel}{$a_read}[HSS_STATE] eq "event-rd");
}

# Verify the handle structure.

{ my %handles = $poe_kernel->_data_handle_handles();

  ok_if(25, keys(%handles) == 1);
  ok_if(26, exists $handles{$poe_kernel});
  ok_if(27, keys(%{$handles{$poe_kernel}}) == 1);
  ok_if(28, exists $handles{$poe_kernel}{$a_read});
  ok_if(29, $handles{$poe_kernel}{$a_read}[SH_HANDLE] == $a_read);
  ok_if(30, $handles{$poe_kernel}{$a_read}[SH_REFCOUNT] == 1);
  ok_if(31, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_RD] == 1);
  ok_if(32, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_WR] == 0);
  ok_if(33, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_EX] == 0);
}

# Add a second handle in read mode.

$poe_kernel->_data_handle_add($b_read, MODE_RD, $poe_kernel, "event-rd");

# Verify reference counts.

ok_if(34, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2);

{ my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($b_read)
  );
  ok_if(35, $tot == 1);
  ok_if(36, $rd  == 1);
  ok_if(37, $wr  == 0);
  ok_if(38, $ex  == 0);
}

{ my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($b_read)
  );
  ok_if(39, $rd == 0);
  ok_if(40, $wr == 0);
  ok_if(41, $ex == 0);
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($b_read));

  ok_if(42, $r_act == HS_RUNNING);
  ok_if(43, $r_req == HS_RUNNING);
  ok_if(44, $w_act == HS_PAUSED);
  ok_if(45, $w_req == HS_PAUSED);
  ok_if(46, $e_act == HS_PAUSED);
  ok_if(47, $e_req == HS_PAUSED);
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($b_read));

  ok_if(48, scalar keys %$ses_r == 1);
  ok_if(49, scalar keys %$ses_w == 0);
  ok_if(50, scalar keys %$ses_e == 0);

  ok_if(51, exists $ses_r->{$poe_kernel});
  ok_if(52, scalar keys %{$ses_r->{$poe_kernel}} == 1);
  ok_if(53, exists $ses_r->{$poe_kernel}{$b_read});
  ok_if(54, $ses_r->{$poe_kernel}{$b_read}[HSS_HANDLE] == $b_read);
  ok_if(55, $ses_r->{$poe_kernel}{$b_read}[HSS_SESSION] == $poe_kernel);
  ok_if(56, $ses_r->{$poe_kernel}{$b_read}[HSS_STATE] eq "event-rd");
}

# Verify the handle structure.

{ my %handles = $poe_kernel->_data_handle_handles();

  ok_if(57, keys(%handles) == 1);
  ok_if(58, exists $handles{$poe_kernel});
  ok_if(59, keys(%{$handles{$poe_kernel}}) == 2);

  # Verify that a_read was not touched.
  ok_if(60, exists $handles{$poe_kernel}{$a_read});
  ok_if(61, $handles{$poe_kernel}{$a_read}[SH_HANDLE] == $a_read);
  ok_if(62, $handles{$poe_kernel}{$a_read}[SH_REFCOUNT] == 1);
  ok_if(63, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_RD] == 1);
  ok_if(64, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_WR] == 0);
  ok_if(65, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_EX] == 0);

  # Verify that b_read was registered correctly.
  ok_if(66, exists $handles{$poe_kernel}{$b_read});
  ok_if(67, $handles{$poe_kernel}{$b_read}[SH_HANDLE] == $b_read);
  ok_if(68, $handles{$poe_kernel}{$b_read}[SH_REFCOUNT] == 1);
  ok_if(69, $handles{$poe_kernel}{$b_read}[SH_MODECOUNT][MODE_RD] == 1);
  ok_if(70, $handles{$poe_kernel}{$b_read}[SH_MODECOUNT][MODE_WR] == 0);
  ok_if(71, $handles{$poe_kernel}{$b_read}[SH_MODECOUNT][MODE_EX] == 0);
}

# Add a third filehandle in write mode.

$poe_kernel->_data_handle_add($a_write, MODE_WR, $poe_kernel, "event-wr");

# Verify reference counts.  Total reference count doesn't go up
# because this is a duplicate fileno of a previous one.  -><- May not
# be true on all systems!  Argh!

ok_if(72, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2);

{ my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_write)
  );
  ok_if(73, $tot == 2);
  ok_if(74, $rd  == 1);
  ok_if(75, $wr  == 1);
  ok_if(76, $ex  == 0);
}

{ my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_write)
  );
  ok_if(77, $rd == 0);
  ok_if(78, $wr == 0);
  ok_if(79, $ex == 0);
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_write));

  ok_if(80, $r_act == HS_RUNNING);
  ok_if(81, $r_req == HS_RUNNING);
  ok_if(82, $w_act == HS_RUNNING);
  ok_if(83, $w_req == HS_RUNNING);
  ok_if(84, $e_act == HS_PAUSED);
  ok_if(85, $e_req == HS_PAUSED);
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($a_write));

  ok_if(86, scalar keys %$ses_r == 1);
  ok_if(87, scalar keys %$ses_w == 1);
  ok_if(88, scalar keys %$ses_e == 0);

  ok_if(89, exists $ses_w->{$poe_kernel});
  ok_if(90, scalar keys %{$ses_w->{$poe_kernel}} == 1);
  ok_if(91, exists $ses_w->{$poe_kernel}{$a_write});
  ok_if(92, $ses_w->{$poe_kernel}{$a_write}[HSS_HANDLE] == $a_write);
  ok_if(93, $ses_w->{$poe_kernel}{$a_write}[HSS_SESSION] == $poe_kernel);
  ok_if(94, $ses_w->{$poe_kernel}{$a_write}[HSS_STATE] eq "event-wr");
}

# Verify the handle structure.

{ my %handles = $poe_kernel->_data_handle_handles();

  ok_if(95, keys(%handles) == 1);
  ok_if(96, exists $handles{$poe_kernel});
  ok_if(97, keys(%{$handles{$poe_kernel}}) == 2);
  ok_if(98, exists $handles{$poe_kernel}{$a_write});
  ok_if(99, $handles{$poe_kernel}{$a_write}[SH_HANDLE] == $a_write);
  ok_if(100, $handles{$poe_kernel}{$a_write}[SH_REFCOUNT] == 2);
  ok_if(101, $handles{$poe_kernel}{$a_write}[SH_MODECOUNT][MODE_RD] == 1);
  ok_if(102, $handles{$poe_kernel}{$a_write}[SH_MODECOUNT][MODE_WR] == 1);
  ok_if(103, $handles{$poe_kernel}{$a_write}[SH_MODECOUNT][MODE_EX] == 0);
}

# Add a fourth filehandle in exception mode.

$poe_kernel->_data_handle_add($b_write, MODE_EX, $poe_kernel, "event-ex");

# Verify reference counts.

ok_if(104, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2);

{ my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($b_write)
  );
  ok_if(105, $tot == 2);
  ok_if(106, $rd  == 1);
  ok_if(107, $wr  == 0);
  ok_if(108, $ex  == 1);
}

{ my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($b_write)
  );
  ok_if(109, $rd == 0);
  ok_if(110, $wr == 0);
  ok_if(111, $ex == 0);
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($b_write));

  ok_if(112, $r_act == HS_RUNNING);
  ok_if(113, $r_req == HS_RUNNING);
  ok_if(114, $w_act == HS_PAUSED);
  ok_if(115, $w_req == HS_PAUSED);
  ok_if(116, $e_act == HS_RUNNING);
  ok_if(117, $e_req == HS_RUNNING);
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($b_write));

  ok_if(118, scalar keys %$ses_r == 1);
  ok_if(119, scalar keys %$ses_w == 0);
  ok_if(120, scalar keys %$ses_e == 1);

  ok_if(121, exists $ses_e->{$poe_kernel});
  ok_if(122, scalar keys %{$ses_e->{$poe_kernel}} == 1);
  ok_if(123, exists $ses_e->{$poe_kernel}{$b_write});
  ok_if(124, $ses_e->{$poe_kernel}{$b_write}[HSS_HANDLE] == $b_write);
  ok_if(125, $ses_e->{$poe_kernel}{$b_write}[HSS_SESSION] == $poe_kernel);
  ok_if(126, $ses_e->{$poe_kernel}{$b_write}[HSS_STATE] eq "event-ex");
}

# Verify the handle structure.

{ my %handles = $poe_kernel->_data_handle_handles();

  ok_if(127, keys(%handles) == 1);
  ok_if(128, exists $handles{$poe_kernel});
  ok_if(129, keys(%{$handles{$poe_kernel}}) == 2);
  ok_if(130, exists $handles{$poe_kernel}{$b_write});
  ok_if(131, $handles{$poe_kernel}{$b_write}[SH_HANDLE] == $b_write);
  ok_if(132, $handles{$poe_kernel}{$b_write}[SH_REFCOUNT] == 2);
  ok_if(133, $handles{$poe_kernel}{$b_write}[SH_MODECOUNT][MODE_RD] == 1);
  ok_if(134, $handles{$poe_kernel}{$b_write}[SH_MODECOUNT][MODE_WR] == 0);
  ok_if(135, $handles{$poe_kernel}{$b_write}[SH_MODECOUNT][MODE_EX] == 1);
}

# Test various handles.
ok_if(    136, $poe_kernel->_data_handle_is_good($a_read,  MODE_RD));
ok_if(    137, $poe_kernel->_data_handle_is_good($a_read,  MODE_WR));
ok_unless(138, $poe_kernel->_data_handle_is_good($a_read,  MODE_EX));
ok_if(    139, $poe_kernel->_data_handle_is_good($a_write, MODE_RD));
ok_if(    140, $poe_kernel->_data_handle_is_good($a_write, MODE_WR));
ok_unless(141, $poe_kernel->_data_handle_is_good($a_write, MODE_EX));
ok_if(    142, $poe_kernel->_data_handle_is_good($b_read,  MODE_RD));
ok_unless(143, $poe_kernel->_data_handle_is_good($b_read,  MODE_WR));
ok_if(    144, $poe_kernel->_data_handle_is_good($b_read,  MODE_EX));
ok_if(    145, $poe_kernel->_data_handle_is_good($b_write, MODE_RD));
ok_unless(146, $poe_kernel->_data_handle_is_good($b_write, MODE_WR));
ok_if(    147, $poe_kernel->_data_handle_is_good($b_write, MODE_EX));

# Verify a proper result for an untracked filehandle.
ok_unless(148, $poe_kernel->_data_handle_is_good(\*STDIN));

# Enqueue events for ready filenos.
$poe_kernel->_data_handle_enqueue_ready(MODE_RD, fileno($a_read));
$poe_kernel->_data_handle_enqueue_ready(MODE_WR, fileno($a_read));

# Enqueuing ready events pauses the actual states of the filehandles,
# but leaves them intact.
{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(149, $r_act == HS_PAUSED);
  ok_if(150, $r_req == HS_RUNNING);
  ok_if(151, $w_act == HS_PAUSED);
  ok_if(152, $w_req == HS_RUNNING);
  ok_if(153, $e_act == HS_PAUSED);
  ok_if(154, $e_req == HS_PAUSED);
}

# Base refcount increases by two for each enqueued event.
ok_if(155, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 6);

# Pause a handle.  This will prevent it from becoming "running" after
# events are dispatched.
$poe_kernel->_data_handle_pause($a_read, MODE_RD);

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(156, $r_act == HS_PAUSED);
  ok_if(157, $r_req == HS_PAUSED);
  ok_if(158, $w_act == HS_PAUSED);
  ok_if(159, $w_req == HS_RUNNING);
  ok_if(160, $e_act == HS_PAUSED);
  ok_if(161, $e_req == HS_PAUSED);
}

# Dispatch the event, and verify the session's status.  The sleep()
# call is to simulate slow systems, which always dispatch the events
# because they've taken so long to get here.
sleep(1);
$poe_kernel->_data_ev_dispatch_due();

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(162, $r_act == HS_PAUSED);
  ok_if(163, $r_req == HS_PAUSED);
  ok_if(164, $w_act == HS_RUNNING);
  ok_if(165, $w_req == HS_RUNNING);
  ok_if(166, $e_act == HS_PAUSED);
  ok_if(167, $e_req == HS_PAUSED);
}

# Resume a handle, and verify its status.  Since there are no
# outstanding events for the handle, change both the requested and
# actual flags.
$poe_kernel->_data_handle_resume($a_read, MODE_RD);

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(168, $r_act == HS_RUNNING);
  ok_if(169, $r_req == HS_RUNNING);
  ok_if(170, $w_act == HS_RUNNING);
  ok_if(171, $w_req == HS_RUNNING);
  ok_if(172, $e_act == HS_PAUSED);
  ok_if(173, $e_req == HS_PAUSED);
}

# Try out some other handle methods.
ok_if(174, $poe_kernel->_data_handle_count() == 2);
ok_if(175, $poe_kernel->_data_handle_count_ses($poe_kernel) == 2);
ok_if(176, $poe_kernel->_data_handle_count_ses("nonexistent") == 0);

# Remove a filehandle and verify the structures.
$poe_kernel->_data_handle_remove($a_read, MODE_RD, $poe_kernel);

# Verify reference counts.
ok_if(177, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount);

{ my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_read)
  );
  ok_if(178, $tot == 1);
  ok_if(179, $rd  == 0);
  ok_if(180, $wr  == 1);
  ok_if(181, $ex  == 0);
}

{ my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_read)
  );
  ok_if(182, $rd == 0);
  ok_if(183, $wr == 0);
  ok_if(184, $ex == 0);
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok_if(185, $r_act == HS_STOPPED);
  ok_if(186, $r_req == HS_STOPPED);
  ok_if(187, $w_act == HS_RUNNING);
  ok_if(188, $w_req == HS_RUNNING);
  ok_if(189, $e_act == HS_PAUSED);
  ok_if(190, $e_req == HS_PAUSED);
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($a_read));

  ok_if(191, scalar keys %$ses_r == 0);
  ok_if(192, scalar keys %$ses_w == 1);
  ok_if(193, scalar keys %$ses_e == 0);

  ok_unless(194, exists $ses_r->{$poe_kernel});
}

# Verify the handle structure.

{ my %handles = $poe_kernel->_data_handle_handles();

  ok_if(195, keys(%handles) == 1);
  ok_if(196, exists $handles{$poe_kernel});
  ok_if(197, keys(%{$handles{$poe_kernel}}) == 2);
  ok_if(198, exists $handles{$poe_kernel}{$a_read});
  ok_if(199, $handles{$poe_kernel}{$a_read}[SH_HANDLE] == $a_read);
  ok_if(200, $handles{$poe_kernel}{$a_read}[SH_REFCOUNT] == 1);
  ok_if(201, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_RD] == 0);
  ok_if(202, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_WR] == 1);
  ok_if(203, $handles{$poe_kernel}{$a_read}[SH_MODECOUNT][MODE_EX] == 0);
}

# Remove a filehandle and verify the structures.
$poe_kernel->_data_handle_remove($a_write, MODE_WR, $poe_kernel);

# Verify reference counts.
ok_if(204, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount - 1);
ok_unless(205, $poe_kernel->_data_handle_is_good($a_write, MODE_WR));

# Remove a nonexistent filehandle and verify the structures.  We just
# make sure the reference count matches the previous one.
$poe_kernel->_data_handle_remove(\*STDIN, MODE_RD, $poe_kernel);
ok_if(206, $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount - 1);

# Remove all handles for the session.  And verify the structures.
$poe_kernel->_data_handle_clear_session($poe_kernel);
ok_unless(207, $poe_kernel->_data_handle_is_good($b_write, MODE_EX));

# Make sure everything shuts down cleanly.
ok_if(208, $poe_kernel->_data_handle_finalize());

results();
exit 0;
