#!/usr/bin/perl -w
# $Id$

# Tests error conditions.  This has to be a separate test since it
# depends on ASSERT_DEFAULT being 0.  All the other tests enable it.

use strict;
use lib qw(./mylib ../mylib);

sub POE::Kernel::ASSERT_DEFAULT () { 0 }
sub POE::Kernel::TRACE_DEFAULT  () { 1 }
sub POE::Kernel::TRACE_FILENAME () { "./test-output.err" }

# use Test::More;

print "1..0 # Skip most of these should move into other test files\n";

#use POSIX qw(:errno_h);
#use Socket;
#
#BEGIN {
#  my @files_to_unuse = qw(
#    POE/Kernel.pm
#
#    POE/Loop/Event.pm
#    POE/Loop/Gtk.pm
#    POE/Loop/Poll.pm
#    POE/Loop/Select.pm
#    POE/Loop/Tk.pm
#
#    POE/Loop/PerlSignals.pm
#    POE/Loop/TkCommon.pm
#    POE/Loop/TkActiveState.pm
#
#    Event.pm Gtk.pm Tk.pm
#  );
#
#  # Clean up after destructive tests.
#  sub test_cleanup {
#    # Not used in POE::Kernel now.
#
#    delete @INC{ @files_to_unuse };
#    use Symbol qw(delete_package);
#    delete_package("POE::Kernel");
#  }
#
#  # Test that errors occur when multiple event loops are enabled.
#
#  if ($^O eq 'MSWin32') {
#    for (1..3) {
#      print "ok $_ # skipped: This test crashes ActiveState Perl.\n";
#    }
#  }
#  else {
#    # Event + Tk
#    @INC{'Event.pm', 'Tk.pm'} = (1,1);
#    $Tk::VERSION = 800.021;
#    stderr_pause();
#    eval 'use POE::Kernel';
#    stderr_resume();
#    print 'not ' unless defined $@ and length $@;
#    print "ok 1\n";
#    test_cleanup();
#
#    # Gtk + Tk
#    @INC{'Gtk.pm', 'Tk.pm'} = (1, 1);
#    $Tk::VERSION = 800.021;
#    stderr_pause();
#    eval 'use POE::Kernel';
#    stderr_resume();
#    print 'not ' unless defined $@ and length $@;
#    print "ok 2\n";
#    test_cleanup();
#
#    # Event + Gtk
#    @INC{'Event.pm', 'Gtk.pm'} = (1, 1);
#    stderr_pause();
#    eval 'use POE::Kernel';
#    stderr_resume();
#    print 'not ' unless defined $@ and length $@;
#    print "ok 3\n";
#    test_cleanup();
#  }
#}
#
## Make these runtime so they occur after the above tests.
#
#use POE::Session;
#use POE::Kernel;
#use POE::Component::Server::TCP;
#use POE::Wheel::SocketFactory;
#
## Test that errors occur when nonexistent modules are used.
#stderr_pause();
#eval 'use POE qw(NonExistent);';
#stderr_resume();
#print "not " unless defined $@ and length $@;
#print "ok 4\n";
#
## Test that an error occurs when trying to instantiate POE directly.
#eval 'my $x = new POE;';
#print "not " unless defined $@ and length $@;
#print "ok 5\n";
#
#### Test state machine.
#
#sub test_start {
#  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
#
#  ### Aliases.
#
#  # Test error handling for the Kernel's call() method.
#  $! = 0;
#  print "not "
#    if defined $kernel->call( 1000 => 'nonexistent' ) or $! != ESRCH;
#  print "ok 8\n";
#
#  # Test error handling for the Kernel's post() method.
#  $! = 0;
#  print "not "
#    if defined $kernel->post( 1000 => 'nonexistent' ) or $! != ESRCH;
#  print "ok 9\n";
#
#  # Failed alias addition.
#  print "not " if $kernel->alias_set( 'kernel_alias' ) != EEXIST;
#  print "ok 10\n";
#
#  # Failed alias removal.  Not allowed to remove one from another
#  # session.
#  print "not " if $kernel->alias_remove( 'kernel_alias' ) != EPERM;
#  print "ok 11\n";
#
#  # Failed alias removal.  Not allowed to remove one that doesn't
#  # exist.
#  print "not " if $kernel->alias_remove( 'yatta yatta yatta' ) != ESRCH;
#  print "ok 12\n";
#
#  ### IDs
#
#  # Test failed ID->session and session->ID lookups.
#  $! = 0;
#  print "not " if defined $kernel->ID_id_to_session( 1000 ) or $! != ESRCH;
#  print "ok 13\n";
#
#  print "not " if defined $kernel->ID_session_to_id( 1000 ) or $! != ESRCH;
#  print "ok 14\n";
#
#  ### Signals.
#
#  # Test failed signal() call.
#  $! = 0;
#  print "not " if defined $kernel->signal( 1000 => 'BOOGA' ) or $! != ESRCH;
#  print "ok 15\n";
#
#  ### Extra references.
#  $! = 0;
#  print 'not ' if defined $kernel->refcount_increment( 'tag' ) or $! != ESRCH;
#  print "ok 16\n";
#
#  $! = 0;
#  print 'not ' if defined $kernel->refcount_decrement( 'tag' ) or $! != ESRCH;
#  print "ok 17\n";
#}
#
## Did we get this far?
#
#print "ok 6\n";
#
#print "not " if $POE::Kernel::poe_kernel->alias_set( 'kernel_alias' );
#print "ok 7\n";
#
#POE::Session->create
#  ( inline_states =>
#    { _start => \&test_start,
#    }
#  );
#
#print "not " if $POE::Kernel::poe_kernel->alias_remove( 'kernel_alias' );
#print "ok 18\n";
#
#print "not "
#  unless $POE::Kernel::poe_kernel->state( woobly => sub { die } ) == ESRCH;
#print "ok 19\n";
#
#### TCP Server problems.
#
#{ my $warnings = 0;
#  local $SIG{__WARN__} = sub { $warnings++; };
#
#  POE::Component::Server::TCP->new
#    ( Port => -1,
#      Acceptor => sub { die },
#      Nonexistent => 'woobly',
#    );
#
#  print "not " unless $warnings == 1;
#  print "ok 20\n";
#}
#
#### SocketFactory problems.
#
#{ my $warnings = 0;
#  local $SIG{__WARN__} = sub { $warnings++; };
#
#  # Grar!  No UNIX sockets on Windows.
#  if ($^O eq 'MSWin32') {
#    print "ok 21 # skipped: $^O does not support listen on unbound sockets.\n";
#    print "ok 22 # skipped: $^O does not support UNIX sockets.\n";
#  }
#  else {
#    # Odd parameters.
#
#    # Cygwin behaves differently.
#    if ($^O eq "cygwin") {
#      print
#        "ok 21 # skipped: $^O does not support listen on unbound sockets.\n";
#    }
#    else {
#      POE::Wheel::SocketFactory->new
#        ( SuccessEvent => [ ],
#          FailureEvent => [ ],
#        );
#
#      print "not " unless $warnings == 2;
#      print "ok 21\n";
#    }
#
#    # Any protocol on UNIX sockets.
#    $warnings = 0;
#    POE::Wheel::SocketFactory->new
#      ( SocketDomain   => AF_UNIX,
#        SocketProtocol => "tcp",
#        SuccessEvent   => "okay",
#        FailureEvent   => "okay",
#      );
#
#    print "not " unless $warnings == 1;
#    print "ok 22\n";
#  }
#
#  # Unsupported protocol for an address family.
#  eval( 'POE::Wheel::SocketFactory->new ' .
#        '( SocketDomain   => AF_INET,' .
#        '  SocketProtocol => "icmp",' .
#        '  SuccessEvent   => "okay",' .
#        '  FailureEvent   => "okay",' .
#        ');'
#      );
#  print 'not ' unless defined $@ and length $@;
#  print "ok 23\n";
#}
#
#### Main loop.
#
#stderr_pause();
#$POE::Kernel::poe_kernel->run();
#stderr_resume();
#
#### Misuse of unusable modules.
#
#use POE::Wheel;
#
#eval 'POE::Wheel->new';
#print 'not ' unless defined $@ and length $@;
#print "ok 24\n";
#
#use POE::Component;
#
#eval 'POE::Component->new';
#print 'not ' unless defined $@ and length $@;
#print "ok 25\n";
#
#use POE::Driver;
#
#eval 'POE::Driver->new';
#print 'not ' unless defined $@ and length $@;
#print "ok 26\n";
#
#use POE::Filter;
#
#eval 'POE::Filter->new';
#print 'not ' unless defined $@ and length $@;
#print "ok 27\n";
#
#### Misuse of usable modules.
#
#use POE::Driver::SysRW;
#
#eval 'POE::Driver::SysRW->new( 1 )';
#print 'not ' unless defined $@ and length $@;
#print "ok 28\n";
#
#eval 'POE::Driver::SysRW->new( Booga => 1 )';
#print 'not ' unless defined $@ and length $@;
#print "ok 29\n";
#
#eval 'use POE::Filter::HTTPD;';
#unless (defined $@ and length $@) {
#  my $pfhttpd = POE::Filter::HTTPD->new();
#
#  eval '$pfhttpd->get_pending()';
#  print 'not ' unless defined $@ and length $@;
#  print "ok 30\n";
#}
#else {
#  print "ok 30 # skipped: libwww-perl and URI are needed for this test.\n";
#}
#
## POE::Session constructor stuff.
#
#eval 'POE::Session->create( 1 )';
#print 'not ' unless defined $@ and length $@;
#print "ok 31\n";
#
#eval 'POE::Session->create( options => [] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 32\n";
#
#eval 'POE::Session->create( inline_states => [] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 33\n";
#
#eval 'POE::Session->create( inline_states => { _start => 1 } )';
#print 'not ' unless defined $@ and length $@;
#print "ok 34\n";
#
#eval 'POE::Session->create( package_states => {} )';
#print 'not ' unless defined $@ and length $@;
#print "ok 35\n";
#
#eval 'POE::Session->create( package_states => [ 1 ] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 36\n";
#
#eval 'POE::Session->create( package_states => [ main => 1 ] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 37\n";
#
#eval 'POE::Session->create( object_states => {} )';
#print 'not ' unless defined $@ and length $@;
#print "ok 38\n";
#
#eval 'POE::Session->create( object_states => [ 1 ] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 39\n";
#
#eval 'POE::Session->create( package_states => [ main => 1 ] )';
#print 'not ' unless defined $@ and length $@;
#print "ok 40\n";
#
#eval 'POE::Session->new( 1 )';  ### DEPRECATED
#print 'not ' unless defined $@ and length $@;
#print "ok 41\n";
#
#eval 'POE::Session->new( _start => 1 )';
#print 'not ' unless defined $@ and length $@;
#print "ok 42\n";
#
#eval 'POE::Session->new( sub {} => 1 )';
#print 'not ' unless defined $@ and length $@;
#print "ok 43\n";
#
#use POE::Wheel::FollowTail;
#use POE::Filter::Stream;
#
#eval 'POE::Wheel::FollowTail->new( )';
#print 'not ' unless defined $@ and length $@;
#print "ok 44\n";
#
#eval 'POE::Wheel::FollowTail->new( Handle => \*STDIN )';
#print 'not ' unless defined $@ and length $@;
#print "ok 45\n";
#
#eval( 'POE::Wheel::FollowTail->new( Handle => \*STDIN,' .
#      '  Driver => POE::Driver::SysRW->new(),' .
#      ')'
#    );
#print 'not ' unless defined $@ and length $@;
#print "ok 46\n";
#
#eval( 'POE::Wheel::FollowTail->new( Handle => \*STDIN,' .
#      '  Driver => POE::Driver::SysRW->new(),' .
#      '  Filter => POE::Filter::Stream->new(),' .
#      ')'
#    );
#print 'not ' unless defined $@ and length $@;
#print "ok 47\n";
#
#if ($^O ne 'MSWin32' and $^O ne 'MacOS') {
#  require POE::Wheel::Run;
#  POE::Wheel::Run->import();
#
#  eval 'POE::Wheel::Run->new( 1 )';
#  print 'not ' unless defined $@ and length $@;
#  print "ok 48\n";
#
#  eval 'POE::Wheel::Run->new( Program => 1 )';
#  print 'not ' unless defined $@ and length $@;
#  print "ok 49\n";
#}
#else {
#  for (48..49) {
#    print "ok $_ # skipped: $^O does not support POE::Wheel::Run.\n";
#  }
#}

1;
