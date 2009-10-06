# vim: ts=2 sw=2 expandtab
use strict;

use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

BEGIN {
  package POE::Kernel;
  use constant TRACE_DEFAULT => exists($INC{'Devel/Cover.pm'});
}

use POE;
use POE::Pipe::TwoWay;
use IO::File;
use Tie::Handle;

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

use Test::More;

unless (-f "run_network_tests") {
  plan skip_all => "Network access (and permission) required to run this test";
}

plan tests => 132;

### Factored out common tests

# 1 subtest
sub verify_handle_structure {
  my ($name, $handle_info) = @_;

  my $expected_handles = {
    $poe_kernel => do {
      my %h;
      for (@$handle_info) {
        my ($fh, $modes) = @$_;

        my $rd = $modes =~ /r/ ? 1 : 0;
        my $wr = $modes =~ /w/ ? 1 : 0;
        my $ex = $modes =~ /x/ ? 1 : 0;
        die "woops: $modes" if $modes =~ /[^rwx]/;

        $h{$fh} = [
          $fh,                # SH_HANDLE
          $rd + $wr + $ex,    # SH_REFCOUNT
          [                   # SH_MODECOUNT
            $rd,              #   MODE_RD
            $wr,              #   MODE_WR
            $ex,              #   MODE_EX
          ],
        ];
      };
      \%h;
    },
  };

  my %handles = $poe_kernel->_data_handle_handles();
  is_deeply(
    \%handles,
    $expected_handles,
    "$name: session to handles map"
  );
}

# 3 subtests
sub verify_handle_sessions {
  my ($name, $fh, $read_event, $write_event, $exp_event) = @_;

  my $make_expected = sub {
    my ($event) = @_;
    return +{} unless defined $event;
    return +{
      $poe_kernel => {
        $fh => [
          $fh,           # HSS_HANDLE
          $poe_kernel,   # HSS_SESSION
          $event,        # HSS_STATE
          [ ],           # HSS_ARGS
        ]
      }
    };
  };

  my ($ses_r, $ses_w, $ses_e) =
    $poe_kernel->_data_handle_fno_sessions(fileno($fh));

  is_deeply(
    $ses_r,
    $make_expected->($read_event),
    "$name: fileno read session"
  );
  is_deeply(
    $ses_w,
    $make_expected->($write_event),
    "$name: fileno write session"
  );
  is_deeply(
    $ses_e,
    $make_expected->($exp_event),
    "$name: fileno expedite session"
  );
}

# 7 subtests
sub verify_handle_refcounts {
  my ($name, $fh, $modes) = @_;

  my $expected_rd = $modes =~ /r/ ? 1 : 0;
  my $expected_wr = $modes =~ /w/ ? 1 : 0;
  my $expected_ex = $modes =~ /x/ ? 1 : 0;
  die "woops: $modes" if $modes =~ /[^rwx]/;

  {
    my ($tot, $rd, $wr, $ex) = $poe_kernel->_data_handle_fno_refcounts(
      fileno($fh)
    );
    is(
      $tot,
      $expected_rd + $expected_wr + $expected_ex,
      "$name: fd total refcount"
    );
    is( $rd, $expected_rd, "$name: fd read refcount" );
    is( $wr, $expected_wr, "$name: fd write refcount" );
    is( $ex, $expected_ex, "$name: fd expedite refcount" );
  }
}

# 6 subtests
sub verify_handle_state {
  my ($name, $fh, $rd_str, $wr_str, $ex_str) = @_;
  # string format: 'AR', A - actual, R - requested

  my $parse_str = sub {
    my ($str) = @_;
    return [ map { +{
        's' => HS_STOPPED,
        'p' => HS_PAUSED,
        'r' => HS_RUNNING }->{$_} }
      split //, $str ];
  };

  my $rd = $parse_str->($rd_str);
  my $wr = $parse_str->($wr_str);
  my $ex = $parse_str->($ex_str);

  my ($r_act, $w_act, $e_act) =
    $poe_kernel->_data_handle_fno_states(fileno($fh));

  ok( $r_act == $$rd[0], "$name: read actual state" );
  ok( $w_act == $$wr[0], "$name: write actual state" );
  ok( $e_act == $$ex[0], "$name: expedite actual state" );
}

### Tests

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
verify_handle_refcounts(
  "first read add", $a_read, "r"
);

# Verify the handle's state.
verify_handle_state(
  "first read add", $a_read,
  "rr", "pp", "pp"
);

# Verify the handle's sessions.
verify_handle_sessions(
  "first read add", $a_read, "event-rd", undef, undef
);

# Verify the handle structure.
verify_handle_structure(
  "first read add",
  [ [$a_read => 'r'] ],
);

# Add a second handle in read mode.

$poe_kernel->_data_handle_add($b_read, MODE_RD, $poe_kernel, "event-rd", []);

# Verify reference counts.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "second read add: session reference count"
);

verify_handle_refcounts(
  "second read add", $b_read, "r"
);

# Verify the handle's state.
verify_handle_state(
  "second read add", $b_read,
  "rr", "pp", "pp"
);

# Verify the handle's sessions.
verify_handle_sessions(
  "second read add", $b_read, "event-rd", undef, undef
);

# Verify the handle structure.
verify_handle_structure(
  "second read add",
  [ [$a_read => 'r'], [$b_read => 'r'] ],
);

# Add a third filehandle in write mode.

$poe_kernel->_data_handle_add($a_write, MODE_WR, $poe_kernel, "event-wr", []);

# Verify reference counts.  Total reference count doesn't go up
# because this is a duplicate fileno of a previous one.
# -><- May not be true on all systems!  Argh!
die "woops, we've assumed that write handles have same fileno as read handles"
  unless fileno($a_write) == fileno($a_read);

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "third write add: session reference count"
);

verify_handle_refcounts(
  "third write add", $a_write, "rw"
);

# Verify the handle's state.
verify_handle_state(
  "third write add", $a_write,
  "rr", "rr", "pp"
);

# Verify the handle's sessions.
verify_handle_sessions(
  "third write add", $a_write, "event-rd", "event-wr", undef
);

# Verify the handle structure.
verify_handle_structure(
  "third write add",
  [ [$a_read => 'rw'], [$b_read => 'r'] ],
);

# Add a fourth filehandle in exception mode.

$poe_kernel->_data_handle_add($b_write, MODE_EX, $poe_kernel, "event-ex", []);

# Verify reference counts.

ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 2,
  "fourth expedite add: session reference count"
);

verify_handle_refcounts(
  "fourth expedite add", $b_write, "rx"
);

# Verify the handle's state.
verify_handle_state(
  "fourth expedite add", $b_write,
  "rr", "pp", "rr"
);

# Verify the handle's sessions.
verify_handle_sessions(
  "fourth expedite add", $b_write, "event-rd", undef, "event-ex"
);

# Verify the handle structure.
verify_handle_structure(
  "third write add",
  [ [$a_read => 'rw'], [$b_read => 'rx'] ],
);

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

# Events are dispatched right away, so the handles need not be paused.
verify_handle_state(
  "dequeue one", $a_read,
  "rr", "rr", "pp"
);

# Base refcount is not increased, because the event is actually
# dispatched right away.
is(
  $poe_kernel->_data_ses_refcount($poe_kernel), $base_refcount + 2,
  "dequeue one: session reference count"
);

# Pause a handle.  This will prevent it from becoming "running" after
# events are dispatched.
$poe_kernel->_data_handle_pause($a_read, MODE_RD);

verify_handle_state(
  "pause one", $a_read,
  "pp", "rr", "pp"
);

# Dispatch the event, and verify the session's status.  The sleep()
# call is to simulate slow systems, which always dispatch the events
# because they've taken so long to get here.
sleep(1);
$poe_kernel->_data_ev_dispatch_due();

verify_handle_state(
  "dispatch one", $a_read,
  "pp", "rr", "pp"
);

# Resume a handle, and verify its status.  Since there are no
# outstanding events for the handle, change both the requested and
# actual flags.
$poe_kernel->_data_handle_resume($a_read, MODE_RD);

verify_handle_state(
  "resume one", $a_read,
  "rr", "rr", "pp"
);

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

verify_handle_refcounts(
  "first remove", $a_read, "w"
);

# Verify the handle's state.
verify_handle_state(
  "first remove", $a_read,
  "ss", "rr", "pp"
);

# Verify the handle's sessions.
verify_handle_sessions(
  "first remove", $a_read, undef, "event-wr", undef
);

# Verify the handle structure.
verify_handle_structure(
  "third write add",
  [ [$a_read => 'w'], [$b_read => 'rx'] ],
);

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

# Now test some special cases

# regular file filehandle
{
  my $fh = IO::File->new($0, "r+");
  $poe_kernel->_data_handle_add($fh, MODE_RD, $poe_kernel, "event-rd", []);
  $poe_kernel->_data_handle_add($fh, MODE_WR, $poe_kernel, "event-wr", []);

  verify_handle_refcounts("regular file", $fh, "rw");
  verify_handle_state("regular file", $fh, "rr", "rr", "pp");
  verify_handle_sessions("regular file", $fh, "event-rd", "event-wr", undef);
  verify_handle_structure("regular file",
    [ [$fh => 'rw'], [$b_read => 'rx'] ]);

  # now pause the handle, check it's paused,
  # then add it again, and check that this resumes it
  $poe_kernel->_data_handle_pause($fh, MODE_RD);
  verify_handle_state("regular file - paused", $fh, "pp", "rr", "pp");
  $poe_kernel->_data_handle_add($fh, MODE_RD, $poe_kernel, "event-rd", []);
  verify_handle_state("regular file - resumed", $fh, "rr", "rr", "pp");

  # get a new handle for the same FD, and try to add it
  # --- this should fail
  {
    my $dup_fh = IO::Handle->new_from_fd(fileno($fh), "r");
    eval {
      $poe_kernel->_data_handle_add($dup_fh, MODE_RD, $poe_kernel,
        "event-rd", []);
    };
    ok($@ ne '', "failure when adding different handle but same FD");
  }

  $poe_kernel->_data_handle_remove($fh, MODE_RD, $poe_kernel);
  $poe_kernel->_data_handle_remove($fh, MODE_WR, $poe_kernel);

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1,
    "regular file: session reference count"
  );
  ok(
    !$poe_kernel->_data_handle_is_good($fh, MODE_WR)
    && !$poe_kernel->_data_handle_is_good($fh, MODE_RD),
    "regular file: handle removed fully"
  );
}

# tied filehandle
SKIP: {
  BEGIN {
    package My::TiedHandle;
    use vars qw(@ISA);
    @ISA = qw( Tie::StdHandle IO::Handle );
  }
  my $fh = IO::Handle->new;
  tie *$fh, 'My::TiedHandle';

  open *$fh, "+<$0" or skip("couldn't open tied handle: $!", 19);

  $poe_kernel->_data_handle_add($fh, MODE_WR, $poe_kernel, "event-wr", []);
  $poe_kernel->_data_handle_add($fh, MODE_EX, $poe_kernel, "event-ex", []);

  verify_handle_refcounts("tied fh", $fh, "wx");
  verify_handle_state("tied fh", $fh, "pp", "rr", "rr");
  verify_handle_sessions("tied fh", $fh, undef, "event-wr", "event-ex");
  verify_handle_structure("tied fh",
    [ [$fh => 'wx'], [$b_read => 'rx'] ]);

  $poe_kernel->_data_handle_remove($fh, MODE_WR, $poe_kernel);
  $poe_kernel->_data_handle_remove($fh, MODE_EX, $poe_kernel);

  ok(
    $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount + 1,
    "tied fh: session reference count"
  );
  ok(
    !$poe_kernel->_data_handle_is_good($fh, MODE_WR)
    && !$poe_kernel->_data_handle_is_good($fh, MODE_EX),
    "tied fh: handle removed fully"
  );
}

{
  # Enqueue an event for a handle that we're about to remove
  $poe_kernel->_data_handle_enqueue_ready(MODE_RD, fileno($b_write));
  my @verify = ( [ $b_read => 'rx' ] );

  # Add back a write handle.  Can't select on non-sockets on
  # MSWin32, so we skip this check on that platform.
  if ($^O ne "MSWin32") {
    $poe_kernel->_data_handle_add(
      \*STDOUT, MODE_WR, $poe_kernel, "event-wr", []
    );
    push @verify, [ \*STDOUT => 'w' ];
  }

  verify_handle_structure("before final remove all", \@verify);
}

# Remove all handles for the session.  And verify the structures.
$poe_kernel->_data_handle_clear_session($poe_kernel);
ok(
  !$poe_kernel->_data_handle_is_good($b_write, MODE_EX),
  "final remove all: session reference count"
);

# Check again that all handles are gone
ok(
  $poe_kernel->_data_ses_refcount($poe_kernel) == $base_refcount,
  "session reference count is back to base count"
);

# Make sure everything shuts down cleanly.
ok(
  $poe_kernel->_data_handle_finalize(),
  "filehandle subsystem finalization"
);

1;
