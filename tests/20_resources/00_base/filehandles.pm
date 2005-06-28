# $Id$

use strict;

use lib qw(./mylib ./lib);

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
sub HSS_ARGS    () { POE::Kernel::HSS_ARGS    }

sub SH_HANDLE    () { POE::Kernel::SH_HANDLE    }
sub SH_REFCOUNT  () { POE::Kernel::SH_REFCOUNT  }
sub SH_MODECOUNT () { POE::Kernel::SH_MODECOUNT }

use Test::More tests => 139;

# Get a baseline reference count for the session, to use as
# comparison.
my $base_refcount = $poe_kernel->_data_ses_refcount($poe_kernel);

# We need some file handles to work with.
my ($a_read, $a_write, $b_read, $b_write) = POE::Pipe::TwoWay->new("inet");
ok(defined($a_read), "created a two-way pipe");

# Add a filehandle in read mode.

$poe_kernel->_data_handle_add($a_read, MODE_RD, $poe_kernel, "event-rd", []);

# Verify reference counts.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1,
  "first read add: session reference count"
);

{
  my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_read)
  );
  ok( $tot == 1, "first read add: fd total refcount" );
  ok( $rd  == 1, "first read add: fd read refcount" );
  ok( $wr  == 0, "first read add: fd write refcount" );
  ok( $ex  == 0, "first read add: fd expedite refcount" );
}

{
  my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_read)
  );
  ok( $rd == 0, "first read add: event read refcount" );
  ok( $wr == 0, "first read add: event write refcount" );
  ok( $ex == 0, "first read add: event expedite refcount" );
}

# Verify the handle's state.

{
  my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok( $r_act == HS_RUNNING, "first read add: read actual state" );
  ok( $r_req == HS_RUNNING, "first read add: read requested state" );
  ok( $w_act == HS_PAUSED,  "first read add: write actual state" );
  ok( $w_req == HS_PAUSED,  "first read add: write requested state" );
  ok( $e_act == HS_PAUSED,  "first read add: expedite actual state" );
  ok( $e_req == HS_PAUSED,  "first read add: expedite requested state" );
}

# Verify the handle's sessions.

{
  my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($a_read));

  is_deeply(
    $ses_r, {
      $poe_kernel => {
        $a_read => [
          $a_read,      # HSS_HANDLE
          $poe_kernel,  # HSS_SESSION
          "event-rd",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "first read add: fileno read session"
  );

  is_deeply(
    $ses_w, {
    },
    "first read add: fileno write session"
  );

  is_deeply(
    $ses_e, {
    },
    "first read add: fileno expedite session"
  );
}

# Verify the handle structure.

{
  my %handles = $poe_kernel->_data_handle_handles();

  is_deeply(
    \%handles,
    {
      $poe_kernel => {
        $a_read => [
          $a_read,      # SH_HANDLE
          1,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            0,            # SH_MODECOUNT MODE_WR
            0,            # SH_MODECOUNT MODE_EX
          ],
        ],
      },
    },
    "first read add: session to handles map"
  );
}

# Add a second handle in read mode.

$poe_kernel->_data_handle_add($b_read, MODE_RD, $poe_kernel, "event-rd", []);

# Verify reference counts.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "second read add: session reference count"
);

{
  my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($b_read)
  );
  ok( $tot == 1, "second read add: fd total refcount" );
  ok( $rd  == 1, "second read add: fd read refcount" );
  ok( $wr  == 0, "second read add: fd write refcount" );
  ok( $ex  == 0, "second read add: fd expedite refcount" );
}

{
  my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($b_read)
  );
  ok( $rd == 0, "second read add: event read refcount" );
  ok( $wr == 0, "second read add: event write refcount" );
  ok( $ex == 0, "second read add: event expedite refcount" );
}

# Verify the handle's state.

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($b_read));

  ok( $r_act == HS_RUNNING, "second read add: read actual state" );
  ok( $r_req == HS_RUNNING, "second read add: read requested state" );
  ok( $w_act == HS_PAUSED,  "second read add: write actual state" );
  ok( $w_req == HS_PAUSED,  "second read add: write requested state" );
  ok( $e_act == HS_PAUSED,  "second read add: expedite actual state" );
  ok( $e_req == HS_PAUSED,  "second read add: expedite requested state" );
}

# Verify the handle's sessions.

{ my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($b_read));

  is_deeply(
    $ses_r, {
      $poe_kernel => {
        $b_read => [
          $b_read,      # HSS_HANDLE
          $poe_kernel,  # HSS_SESSION
          "event-rd",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "second read add: fileno read session"
  );

  is_deeply(
    $ses_w, {
    },
    "second read add: fileno write session"
  );

  is_deeply(
    $ses_e, {
    },
    "second read add: fileno expedite session"
  );
}

# Verify the handle structure.

{
  my %handles = $poe_kernel->_data_handle_handles();

  is_deeply(
    \%handles,
    {
      $poe_kernel => {
        $a_read => [
          $a_read,      # SH_HANDLE
          1,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,          #   MODE_RD
            0,          #   MODE_WR
            0,          #   MODE_EX
          ],
        ],
        $b_read => [
          $b_read,      # SH_HANDLE
          1,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,          #   MODE_RD
            0,          #   MODE_WR
            0,          #   MODE_EX
          ],
        ],
      },
    },
    "second read add: session to handles map"
  );
}

# Add a third filehandle in write mode.

$poe_kernel->_data_handle_add($a_write, MODE_WR, $poe_kernel, "event-wr", []);

# Verify reference counts.  Total reference count doesn't go up
# because this is a duplicate fileno of a previous one.
# -><- May not be true on all systems!  Argh!

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "third write add: session reference count"
);

{
  my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_write)
  );
  ok( $tot == 2, "third write add: fd total refcount" );
  ok( $rd  == 1, "third write add: fd read refcount" );
  ok( $wr  == 1, "third write add: fd write refcount" );
  ok( $ex  == 0, "third write add: fd expedite refcount" );
}

{
  my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_write)
  );
  ok( $rd == 0, "third write add: event read refcount" );
  ok( $wr == 0, "third write add: event write refcount" );
  ok( $ex == 0, "third write add: event expedite refcount" );
}

# Verify the handle's state.

{
  my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_write));

  ok( $r_act == HS_RUNNING, "third write add: read actual state" );
  ok( $r_req == HS_RUNNING, "third write add: read requested state" );
  ok( $w_act == HS_RUNNING, "third write add: write actual state" );
  ok( $w_req == HS_RUNNING, "third write add: write requested state" );
  ok( $e_act == HS_PAUSED,  "third write add: expedited actual state" );
  ok( $e_req == HS_PAUSED,  "third write add: expedited requested state" );
}

# Verify the handle's sessions.

{
  my ($ses_r, $ses_w, $ses_e) = $poe_kernel->_data_handle_fno_sessions(
    fileno($a_write)
  );

  is_deeply(
    $ses_r, {
      $poe_kernel => {
        $a_read => [
          $a_read,      # HSS_HANDLE
          $poe_kernel,  # HSS_SESSION
          "event-rd",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "third write add: fileno read session"
  );

  is_deeply(
    $ses_w, {
      $poe_kernel => {
        $a_write => [
          $a_write,     # HSS_HANDLE
          $poe_kernel,  # HSS_STATE
          "event-wr",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "third write add: fileno write session"
  );

  is_deeply(
    $ses_e, {
    },
    "third write add: fileno expedite session"
  );
}

# Verify the handle structure.

{
  my %handles = $poe_kernel->_data_handle_handles();

  is_deeply(
    \%handles,
    {
      $poe_kernel => {
        $b_read => [
          $b_read,      # SH_HANDLE
          1,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            0,            # SH_MODECOUNT MODE_WR
            0,            # SH_MODECOUNT MODE_EX
          ],
        ],
        $a_read => [
          $a_read,      # SH_HANDLE
          2,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            1,            # SH_MODECOUNT MODE_WR
            0,            # SH_MODECOUNT MODE_EX
          ],
        ],
      },
    },
    "third write add: session to handles map"
  );
}

# Add a fourth filehandle in exception mode.

$poe_kernel->_data_handle_add($b_write, MODE_EX, $poe_kernel, "event-ex", []);

# Verify reference counts.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "fourth expedite add: session reference count"
);

{
  my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($b_write)
  );
  ok( $tot == 2, "fourth expedite add: fd total refcount" );
  ok( $rd  == 1, "fourth expedite add: fd read refcount" );
  ok( $wr  == 0, "fourth expedite add: fd write refcount" );
  ok( $ex  == 1, "fourth expedite add: fd expedite refcount" );
}

{
  my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($b_write)
  );
  ok( $rd == 0, "fourth expedite add: event read refcount" );
  ok( $wr == 0, "fourth expedite add: event write refcount" );
  ok( $ex == 0, "fourth expedite add: event expedite refcount" );
}

# Verify the handle's state.

{
  my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($b_write));

  ok( $r_act == HS_RUNNING, "fourth expedite add: read actual state" );
  ok( $r_req == HS_RUNNING, "fourth expedite add: read requested state" );
  ok( $w_act == HS_PAUSED,  "fourth expedite add: write actual state" );
  ok( $w_req == HS_PAUSED,  "fourth expedite add: write requested state" );
  ok( $e_act == HS_RUNNING, "fourth expedite add: expedite actual state" );
  ok( $e_req == HS_RUNNING, "fourth expedite add: expedite requested state" );
}

# Verify the handle's sessions.

{
  my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($b_write));

  is_deeply(
    $ses_r, {
      $poe_kernel => {
        $b_write => [
          $b_write,     # HSS_HANDLE
          $poe_kernel,  # HSS_SESSION
          "event-rd",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "fourth expedite add: fileno read session"
  );

  is_deeply(
    $ses_w, {
    },
    "fourth expedite add: fileno write session"
  );

  is_deeply(
    $ses_e, {
      $poe_kernel => {
        $b_write => [
          $b_write,     # HSS_HANDLE
          $poe_kernel,  # HSS_SESSION
          "event-ex",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "fourth expedite add: fileno expedite session"
  );
}

# Verify the handle structure.

{
  my %handles = $poe_kernel->_data_handle_handles();

  is_deeply(
    \%handles,
    {
      $poe_kernel => {
        $b_read => [
          $b_read,      # SH_HANDLE
          2,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            0,            # SH_MODECOUNT MODE_WR
            1,            # SH_MODECOUNT MODE_EX
          ],
        ],
        $a_read => [
          $a_read,      # SH_HANDLE
          2,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            1,            # SH_MODECOUNT MODE_WR
            0,            # SH_MODECOUNT MODE_EX
          ],
        ],
      },
    },
    "fourth expedite add: session to handles map"
  );
}

# Test various handles.
ok(
  $poe_kernel->_data_handle_is_good($a_read,  MODE_RD),
  "a_read in read mode"
);
ok(
  $poe_kernel->_data_handle_is_good($a_read,  MODE_WR),
  "a_read in write mode"
);
ok(
  !$poe_kernel->_data_handle_is_good($a_read,  MODE_EX),
  "a_read in expedite mode"
);

ok(
  $poe_kernel->_data_handle_is_good($a_write, MODE_RD),
  "a_write in read mode"
);
ok(
  $poe_kernel->_data_handle_is_good($a_write, MODE_WR),
  "a_write in write mode"
);
ok(
  !$poe_kernel->_data_handle_is_good($a_write, MODE_EX),
  "a_write in expedite mode"
);

ok(
  $poe_kernel->_data_handle_is_good($b_read,  MODE_RD),
  "b_read in read mode"
);
ok(
  !$poe_kernel->_data_handle_is_good($b_read,  MODE_WR),
  "b_read in write mode"
);
ok(
  $poe_kernel->_data_handle_is_good($b_read,  MODE_EX),
  "b_read in expedite mode"
);

ok(
  $poe_kernel->_data_handle_is_good($b_write, MODE_RD),
  "b_write in read mode"
);
ok(
  !$poe_kernel->_data_handle_is_good($b_write, MODE_WR),
  "b_write in write mode"
);
ok(
  $poe_kernel->_data_handle_is_good($b_write, MODE_EX),
  "b_write in expedite mode"
);

# Verify a proper result for an untracked filehandle.
ok(
  !$poe_kernel->_data_handle_is_good(\*STDIN, MODE_RD),
  "untracked handle in read mode"
);
ok(
  !$poe_kernel->_data_handle_is_good(\*STDIN, MODE_WR),
  "untracked handle in write mode"
);
ok(
  !$poe_kernel->_data_handle_is_good(\*STDIN, MODE_EX),
  "untracked handle in expedite mode"
);

# Enqueue events for ready filenos.
$poe_kernel->_data_handle_enqueue_ready(MODE_RD, fileno($a_read));
$poe_kernel->_data_handle_enqueue_ready(MODE_WR, fileno($a_read));

# Enqueuing ready events pauses the actual states of the filehandles,
# but leaves them intact.
{
  my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok($r_act == HS_PAUSED,   "dequeue one: read actual state");
  ok($r_req == HS_RUNNING,  "dequeue one: read requested state");
  ok($w_act == HS_PAUSED,   "dequeue one: write actual state");
  ok($w_req == HS_RUNNING,  "dequeue one: write requested state");
  ok($e_act == HS_PAUSED,   "dequeue one: expedite actual state");
  ok($e_req == HS_PAUSED,   "dequeue one: expedite requested state");
}

# Base refcount increases by two for each enqueued event.
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 6,
  "dequeue one: session reference count"
);

# Pause a handle.  This will prevent it from becoming "running" after
# events are dispatched.
$poe_kernel->_data_handle_pause($a_read, MODE_RD);

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok($r_act == HS_PAUSED,   "pause one: read actual state");
  ok($r_req == HS_PAUSED,   "pause one: read requested state");
  ok($w_act == HS_PAUSED,   "pause one: write actual state");
  ok($w_req == HS_RUNNING,  "pause one: write requested state");
  ok($e_act == HS_PAUSED,   "pause one: expedite actual state");
  ok($e_req == HS_PAUSED,   "pause one: expedite requested state");
}

# Dispatch the event, and verify the session's status.  The sleep()
# call is to simulate slow systems, which always dispatch the events
# because they've taken so long to get here.
sleep(1);
$poe_kernel->_data_ev_dispatch_due();

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok($r_act == HS_PAUSED,    "dispatch one: read actual state");
  ok($r_req == HS_PAUSED,    "dispatch one: read requested state");
  ok($w_act == HS_RUNNING,   "dispatch one: write actual state");
  ok($w_req == HS_RUNNING,   "dispatch one: write requested state");
  ok($e_act == HS_PAUSED,    "dispatch one: expedite actual state");
  ok($e_req == HS_PAUSED,    "dispatch one: expedite requested state");
}

# Resume a handle, and verify its status.  Since there are no
# outstanding events for the handle, change both the requested and
# actual flags.
$poe_kernel->_data_handle_resume($a_read, MODE_RD);

{ my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok($r_act == HS_RUNNING,  "resume one: read actual state");
  ok($r_req == HS_RUNNING,  "resume one: read requested state");
  ok($w_act == HS_RUNNING,  "resume one: write actual state");
  ok($w_req == HS_RUNNING,  "resume one: write requested state");
  ok($e_act == HS_PAUSED,   "resume one: expedite actual state");
  ok($e_req == HS_PAUSED,   "resume one: expedite requested state");
}

# Try out some other handle methods.
ok(
  $poe_kernel->_data_handle_count() == 2,
  "number of handles tracked"
);
ok(
  $poe_kernel->_data_handle_count_ses($poe_kernel) == 2,
  "number of sessions tracking"
);
ok(
  $poe_kernel->_data_handle_count_ses("nonexistent") == 0,
  "number of handles tracked by a nonexistent session"
);

# Remove a filehandle and verify the structures.
$poe_kernel->_data_handle_remove($a_read, MODE_RD, $poe_kernel);

# Verify reference counts.
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "first remove: session reference count"
);

{
  my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
    fileno($a_read)
  );
  ok($tot == 1, "first remove: fd total refcount");
  ok($rd  == 0, "first remove: fd read refcount");
  ok($wr  == 1, "first remove: fd write refcount");
  ok($ex  == 0, "first remove: fd expedite refcount");
}

{
  my ($rd, $wr, $ex) = $poe_kernel->_data_handle_fno_evcounts(
    fileno($a_read)
  );
  ok($rd == 0, "first remove: event read refcount");
  ok($wr == 0, "first remove: event write refcount");
  ok($ex == 0, "first remove: event expeite refcount");
}

# Verify the handle's state.

{
  my ($r_act, $r_req, $w_act, $w_req, $e_act, $e_req) =
    $poe_kernel->_data_handle_fno_states(fileno($a_read));

  ok($r_act == HS_STOPPED, "first remove: read actual state");
  ok($r_req == HS_STOPPED, "first remove: read requested state");
  ok($w_act == HS_RUNNING, "first remove: write actual state");
  ok($w_req == HS_RUNNING, "first remove: write requested state");
  ok($e_act == HS_PAUSED,  "first remove: expedite actual state");
  ok($e_req == HS_PAUSED,  "first remove: expedite requested state");
}

# Verify the handle's sessions.

{
  my ($ses_r, $ses_w, $ses_e) = $poe_kernel->_data_handle_fno_sessions(
    fileno($a_read)
  );

  is_deeply(
    $ses_r, {
    },
    "first remove: fileno read session"
  );

  is_deeply(
    $ses_w, {
      $poe_kernel => {
        $a_write => [
          $a_write,     # HSS_HANDLE
          $poe_kernel,  # HSS_STATE
          "event-wr",   # HSS_STATE
          [ ],          # HSS_ARGS
        ]
      }
    },
    "first remove: fileno write session"
  );

  is_deeply(
    $ses_e, {
    },
    "first remove: fileno expedite session"
  );
}

# Verify the handle structure.

{
  my %handles = $poe_kernel->_data_handle_handles();

  is_deeply(
    \%handles,
    {
      $poe_kernel => {
        $b_read => [
          $b_read,      # SH_HANDLE
          2,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            1,            # SH_MODECOUNT MODE_RD
            0,            # SH_MODECOUNT MODE_WR
            1,            # SH_MODECOUNT MODE_EX
          ],
        ],
        $a_read => [
          $a_read,      # SH_HANDLE
          1,            # SH_REFCOUNT
          [             # SH_MODECOUNT
            0,            # SH_MODECOUNT MODE_RD
            1,            # SH_MODECOUNT MODE_WR
            0,            # SH_MODECOUNT MODE_EX
          ],
        ],
      },
    },
    "first remove: session to handles map"
  );
}

# Remove a filehandle and verify the structures.
$poe_kernel->_data_handle_remove($a_write, MODE_WR, $poe_kernel);

# Verify reference counts.
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1,
  "second remove: session reference count"
);
ok(
  !$poe_kernel->_data_handle_is_good($a_write, MODE_WR),
  "second remove: handle removed fully"
);

# Remove a nonexistent filehandle and verify the structures.  We just
# make sure the reference count matches the previous one.
$poe_kernel->_data_handle_remove(\*STDIN, MODE_RD, $poe_kernel);
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1,
  "nonexistent remove: session reference count"
);

# Remove all handles for the session.  And verify the structures.
$poe_kernel->_data_handle_clear_session($poe_kernel);
ok(
  !$poe_kernel->_data_handle_is_good($b_write, MODE_EX),
  "final remove all: session reference count"
);

# Make sure everything shuts down cleanly.
ok(
  $poe_kernel->_data_handle_finalize(),
  "filehandle subsystem finalization"
);

1;
