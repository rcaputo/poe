#!/usr/bin/perl -w
# $Id$

# Tests error conditions.  This has to be a separate test since it
# depends on ASSERT_DEFAULT being 0.  All the other tests enable it.

use strict;
use lib qw(./lib ../lib);
use TestSetup;

BEGIN {
  &test_setup(26);
};

use POSIX qw(:errno_h);
use Socket;

my (@symbols_to_clean_up, @files_to_unuse);

BEGIN {
  @symbols_to_clean_up =
    qw( POE_USES_TIME_HIRES SUBSTRATE_NAME_EVENT SUBSTRATE_NAME_GTK
        SUBSTRATE_NAME_SELECT SUBSTRATE_NAME_TK SUBSTRATE_EVENT
        SUBSTRATE_GTK SUBSTRATE_SELECT SUBSTRATE_TK POE_SUBSTRATE
        POE_SUBSTRATE_NAME _substrate_signal_handler_generic
        _substrate_signal_handler_pipe _substrate_signal_handler_child

        VEC_RD VEC_WR VEC_EX SS_SESSION SS_REFCOUNT SS_EVCOUNT
        SS_PARENT SS_CHILDREN SS_HANDLES SS_SIGNALS SS_ALIASES
        SS_PROCESSES SS_ID SS_EXTRA_REFS SS_ALCOUNT SH_HANDLE
        SH_REFCOUNT SH_VECCOUNT KR_SESSIONS KR_VECTORS KR_HANDLES
        KR_STATES KR_SIGNALS KR_ALIASES KR_ACTIVE_SESSION KR_PROCESSES
        KR_ALARMS KR_ID KR_SESSION_IDS KR_ID_INDEX KR_WATCHER_TIMER
        KR_WATCHER_IDLE KR_EXTRA_REFS KR_ALARM_IDS KR_SIZE HND_HANDLE
        HND_REFCOUNT HND_VECCOUNT HND_SESSIONS HND_WATCHERS HSS_HANDLE
        HSS_SESSION HSS_STATE ST_SESSION ST_SOURCE ST_NAME ST_TYPE
        ST_ARGS ST_TIME ST_OWNER_FILE ST_OWNER_LINE ST_SEQ EN_START
        EN_STOP EN_SIGNAL EN_GC EN_PARENT EN_CHILD EN_SCPOLL
        CHILD_GAIN CHILD_LOSE CHILD_CREATE ET_USER ET_CALL ET_START
        ET_STOP ET_SIGNAL ET_GC ET_PARENT ET_CHILD ET_SCPOLL ET_ALARM
        ET_SELECT FIFO_DISPATCH_TIME LARGE_QUEUE_SIZE

        F_GETFL F_SETFL EINPROGRESS EWOULDBLOCK

        import signal_ui_destroy
      );

  @files_to_unuse =
    qw( POE/Kernel.pm POE/Kernel/Event.pm POE/Kernel/Gtk.pm
        POE/Kernel/Select.pm POE/Kernel/Tk.pm Event.pm Gtk.pm Tk.pm
      );
};

# Clean up after destructive tests.
sub test_cleanup {
  POE::Preprocessor->clear_package( 'POE::Kernel' );

  foreach my $symbol (@symbols_to_clean_up) {
    delete $POE::Kernel::{$symbol};
  }

  delete @INC{ @files_to_unuse };
}

# Test that errors occur when multiple event loops are enabled.
BEGIN {
  # Event + Tk
  @INC{'Event.pm', 'Tk.pm'} = (1,1);
  eval 'use POE::Kernel';
  print 'not ' unless defined $@ and length $@;
  print "ok 1\n";
  test_cleanup();

  # Gtk + Tk
  @INC{'Gtk.pm', 'Tk.pm'} = (1, 1);
  eval 'use POE::Kernel';
  print 'not ' unless defined $@ and length $@;
  print "ok 2\n";
  test_cleanup();

  # Event + Gtk
  @INC{'Event.pm', 'Gtk.pm'} = (1, 1);
  eval 'use POE::Kernel';
  print 'not ' unless defined $@ and length $@;
  print "ok 3\n";
  test_cleanup();
};

use POE::Kernel;
use POE::Session;
use POE::Component::Server::TCP;
use POE::Wheel::SocketFactory;

die if $@;

#use POE qw( Component::Server::TCP Wheel::SocketFactory );

# Test that errors occur when nonexistent modules are used.
stderr_pause();
eval 'use POE qw(NonExistent);';
stderr_resume();
print "not " unless defined $@ and length $@;
print "ok 4\n";

# Test that an error occurs when trying to instantiate POE directly.
stderr_pause();
eval 'my $x = new POE;';
stderr_resume();
print "not " unless defined $@ and length $@;
print "ok 5\n";

### Test state machine.

sub test_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];

  ### Aliases.

  # Test error handling for the Kernel's call() method.
  $! = 0;
  print "not "
    if (defined $kernel->call( 1000 => 'nonexistent' ) or $! != ESRCH);
  print "ok 8\n";

  # Test error handling for the Kernel's post() method.
  $! = 0;
  print "not "
    if (defined $kernel->post( 1000 => 'nonexistent' ) or $! != ESRCH);
  print "ok 9\n";

  # Failed alias addition.
  print "not " if $kernel->alias_set( 'kernel_alias' ) != EEXIST;
  print "ok 10\n";

  # Failed alias removal.  Not allowed to remove one from another
  # session.
  print "not " if $kernel->alias_remove( 'kernel_alias' ) != EPERM;
  print "ok 11\n";

  # Failed alias removal.  Not allowed to remove one that doesn't
  # exist.
  print "not " if $kernel->alias_remove( 'yatta yatta yatta' ) != ESRCH;
  print "ok 12\n";

  ### IDs

  # Test failed ID->session and session->ID lookups.
  $! = 0;
  print "not " if defined $kernel->ID_id_to_session( 1000 ) or $! != ESRCH;
  print "ok 13\n";

  print "not " if defined $kernel->ID_session_to_id( 1000 ) or $! != ESRCH;
  print "ok 14\n";

  ### Signals.

  # Test failed signal() call.
  $! = 0;
  print "not " if defined $kernel->signal( 1000 => 'BOOGA' ) or $! != ESRCH;
  print "ok 15\n";

  ### Extra references.
  $! = 0;
  print 'not ' if defined $kernel->refcount_increment( 'tag' ) or $! != ESRCH;
  print "ok 16\n";

  $! = 0;
  print 'not ' if defined $kernel->refcount_decrement( 'tag' ) or $! != ESRCH;
  print "ok 17\n";
}

# Did we get this far?

print "ok 6\n";

print "not " if $poe_kernel->alias_set( 'kernel_alias' );
print "ok 7\n";

POE::Session->create
  ( inline_states =>
    { _start => \&test_start,
    }
  );

print "not " if $poe_kernel->alias_remove( 'kernel_alias' );
print "ok 18\n";

print "not " unless $poe_kernel->state( woobly => sub { die } ) == ESRCH;
print "ok 19\n";

### TCP Server problems.

{ my $warnings = 0;
  local $SIG{__WARN__} = sub { $warnings++; };

  stderr_pause();
  POE::Component::Server::TCP->new
    ( Port => -1,
      Acceptor => sub { die },
      Nonexistent => 'woobly',
    );
  stderr_resume();

  print "not " unless $warnings == 1;
  print "ok 20\n";
}

### SocketFactory problems.

{ my $warnings = 0;
  local $SIG{__WARN__} = sub { $warnings++; };

  stderr_pause();
  POE::Wheel::SocketFactory->new
    ( SuccessEvent => [ ],
      FailureEvent => [ ],
    );
  stderr_resume();

  print "not " unless $warnings == 2;
  print "ok 21\n";

  stderr_pause();
  POE::Wheel::SocketFactory->new
    ( SocketDomain   => AF_UNIX,
      SocketProtocol => 'tcp',
      SuccessEvent   => 'okay',
      FailureEvent   => 'okay',
    );
  stderr_resume();

  print "not " unless $warnings == 3;
  print "ok 22\n";
}

### Main loop.

stderr_pause();
$poe_kernel->run();
stderr_resume();

### Misuse of unusable modules.

use POE::Wheel;
eval 'POE::Wheel->new';
print 'not ' unless defined $@ and length $@;
print "ok 23\n";

use POE::Component;
eval 'POE::Component->new';
print 'not ' unless defined $@ and length $@;
print "ok 24\n";

use POE::Driver;
eval 'POE::Driver->new';
print 'not ' unless defined $@ and length $@;
print "ok 25\n";

use POE::Filter;
eval 'POE::Filter->new';
print 'not ' unless defined $@ and length $@;
print "ok 26\n";

exit;
