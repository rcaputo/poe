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

# Test that errors occur when multiple event loops are enabled.
BEGIN {
  # Tk + Event
  $INC{'Tk.pm'} = 'whatever';
  $INC{'Event.pm'} = 'whatever';
  stderr_pause();
  eval 'use POE::Kernel;';
  stderr_resume();
  print 'not ' unless defined $@ and length $@;
  print "ok 1\n";

  # Tk + Gtk
  delete @INC{'POE/Kernel.pm', 'Event.pm'};
  $INC{'Gtk.pm'} = 'whatever';
  stderr_pause();
  eval 'use POE::Kernel;';
  stderr_resume();
  print 'not ' unless defined $@ and length $@;
  print "ok 2\n";

  # Gtk + Event
  delete @INC{'POE/Kernel.pm', 'Tk.pm'};
  $INC{'Event.pm'} = 'whatever';
  stderr_pause();
  eval 'use POE::Kernel;';
  stderr_resume();
  print 'not ' unless defined $@ and length $@;
  print "ok 3\n";

  # Clean up after previous tests.
  delete @INC{ 'POE/Kernel.pm', 'Tk.pm', 'Event.pm', 'Gtk.pm' };
};

use POE qw( Component::Server::TCP Wheel::SocketFactory );

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
    ( SuccessState => [ ],
      FailureState => [ ],
    );
  stderr_resume();

  print "not " unless $warnings == 2;
  print "ok 21\n";

  stderr_pause();
  POE::Wheel::SocketFactory->new
    ( SocketDomain => AF_UNIX,
      SocketProtocol => 'tcp',
      SuccessState => 'okay',
      FailureState => 'okay',
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
