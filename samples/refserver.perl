#!perl -w -I..
# $Id$

# Filter::Reference test, part 1 of 2.
# This program accepts references from refsender.perl.  It thaws the
# references it receives, and displays its contents for verification.

# Contributed by Artur Bergman <artur@vogon-solutions.com>

use strict;

use POE qw(Wheel::ListenAccept Wheel::ReadWrite
           Driver::SysRW Filter::Reference
          );
use IO::Socket;

my $kernel = new POE::Kernel();

#------------------------------------------------------------------------------
# Start listening for objects.

new POE::Session
  ( $kernel,
    _start => sub {
      my ($k, $me, $from) = @_;

      my $listener = new IO::Socket::INET
        ( 'LocalPort' => '31338', # eleet++
          'Listen'    => 5,
          'Proto'     => 'tcp',
          'Reuse'     => 'yes',
        );
		    
      if ($listener) {
        $me->{'wheel'} = new POE::Wheel::ListenAccept
          ( $kernel,
            'Handle'      => $listener,
            'AcceptState' => 'accept',
            'ErrorState'  => 'accept error',
          );
      }
      else {
        warn "redirection could not start: $!";
      }
    },
    'accept error' => sub { 
      my ($k, $me, $from, $operation, $errnum, $errstr) = @_;
      print "! $operation error $errnum: $errstr\n";
    },
    'accept' => sub {
      my ($k,$me,$from,$handle) = @_;
      my $object = Daemon->new($handle);
      my ($peer_host,$peer_port) = ( $handle->peerhost(),
                                     $handle->peerport()
                                   );
      print STDERR "Got connection from $peer_host:$peer_port\n";
      
      new POE::Session ( $k,
                         $object,
                         [qw (_start client write shutdown client_error)],
                       );
    },
  );

#------------------------------------------------------------------------------
# Set up a single Responder session that can handle thawed references.

new POE::Session ( $kernel,
                   new Responder(),
                   [ qw(_start respond) ],
		 );

$kernel->run();

#------------------------------------------------------------------------------
# Responder is an aliased (daemon) session that processes thawed references.

package Responder;
use strict;

sub new {
  my $class = shift;
  return bless {}, $class;
}

sub _start {
  my ($self,$kernel,$namespace,$from) = @_;
  $kernel->alias_set('Responder');
}

sub respond {
  my ($self,$kernel,$namespace,$from,$request) = @_;
  print STDERR "Respond received: $request\n";
  print STDERR "$request contains:\n";
  if ($request =~ /(^|=)HASH\(/) {
    foreach my $key (sort(keys(%$request))) {
      print "    '$key' = '$request->{$key}'\n";
    }
  }
  elsif ($request =~ /(^|=)ARRAY\(/) {
    print "    '", join("', '", @$request), "'\n";
  }
  elsif ($request =~ /(^|=)SCALAR\(/) {
    print "    '", $$request, "'\n";
  }
  else {
    print "    (unknown reference type)\n";
  }
}

#------------------------------------------------------------------------------
# Daemon instances are created by the listening session to handle connections.
# It receives one or more thawed references, and passes them to the running
# Responder session for processing.

package Daemon;
use strict;

sub new {
  my $class = shift;
  my $handle = shift;

  return bless {
		handle => $handle,
	       }, $class;
}

sub _start {
  my ($self,$kernel,$namespace,$from) = @_;
  $namespace->{'wheel_client'} = new POE::Wheel::ReadWrite
    ( $kernel,
      Handle => $self->{handle},
      Driver => new POE::Driver::SysRW(),
      Filter => new POE::Filter::Reference(),
      InputState => 'client',
      ErrorState => 'client_error',
    );
}

sub client {
  my ($self,$kernel,$namespace,$from,$request) = @_;
  $kernel->post('Responder','respond',$request);
}

sub write {
  my ($self,$kernel,$namespace,$from,$response) = @_;
  $namespace->{'wheel_client'}->put($response);
}

sub client_error {
  my ($self,$k,$me,$from,$operation,$errnum,$errstr) = @_;
  print "client closed connection";
  if ($errnum) {
    print ": $operation error $errnum ($errstr)";
  }
  print "\n";
  $k->post($me, 'shutdown');
}

sub shutdown {
  my ($self,$k, $me, $from) = @_;
  delete $me->{'wheel_client'};
}
