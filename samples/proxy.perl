#!/usr/bin/perl -w -I..
# $Id$

use strict;
use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Line);
use vars qw($kernel);
use IO::Socket::INET;

$kernel = new POE::Kernel();
                                        # server session
new POE::Session
  ( $kernel,
    _start => sub {
      my ($k, $me, $from) = @_;

      my $listener = new IO::Socket::INET
        ( 'LocalPort' => '7777',
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
        print "redirecting localhost:7777 to perl.com:daytime...\n";
      }
      else {
        warn "redirection could not start: $!";
      }
    },
    'accept error' => sub { 
      my ($k, $me, $from, $operation, $errnum, $errstr) = @_;
      print "! $operation error $errnum: $errstr\n";
    },
    'accept' => \&accept_and_start,
  );

$kernel->run();
                                        # spawn a proxy session for connections
sub accept_and_start {
  my ($kernel, $me, $from,$accepted_handle) = @_;
  my ($peer_host,$peer_port) = ( $accepted_handle->peerhost(),
                                 $accepted_handle->peerport()
			       );

  print "Got connection from $peer_host:$peer_port\n";

  new POE::Session
    ( $kernel,
      _start => sub {
        my ($k,$me,$from) = @_;
        $me->{'wheel_client'} = new POE::Wheel::ReadWrite
          ( $k,
            Handle => $accepted_handle,
            Driver => new POE::Driver::SysRW(),
            Filter => new POE::Filter::Line(),
            InputState => 'client',
            ErrorState => 'client_error',
          );

        my $server = new IO::Socket::INET
          ( 'PeerAddr' => 'perl.com:daytime',
            'Proto'    => 'tcp',
            'Reuse'    => 'yes',
          );

        if ($server) {
          $me->{'wheel_server'} = new POE::Wheel::ReadWrite
            ( $k,
              Handle => $server,
              Driver => new POE::Driver::SysRW(),
              Filter => new POE::Filter::Line(),
              InputState => 'server',
              ErrorState => 'server_error',
            );
        }
        else {
          $me->{'wheel_client'}->put("Couldn't connect to server");
          delete $me->{'wheel_client'};
        }
        print "> proxy session $me started\n";
      },
      _stop => sub {
        my ($k, $me) = @_;
        print "< proxy session $me shut down\n";
      },
      'client' => sub {
        my ($k,$me,$from,$line) = @_;
        $me->{wheel_server}->put($line);
      },
      'client_error' => sub {
        my ($k,$me,$from,$operation,$errnum,$errstr) = @_;
        print "client closed connection: $operation error $errnum ($errstr)\n";
        $k->post($me, 'shutdown');
      },
      'server' => sub {
        my ($k,$me,$from,$line) = @_;
        $me->{wheel_client}->put($line);
      },
      'server_error' => sub {
        my ($k,$me,$from,$operation,$errnum,$errstr) = @_;
        print "server closed connection: $operation error $errnum ($errstr)\n";
        $k->post($me, 'shutdown');
      },
      'shutdown' => sub {
        my ($k, $me, $from) = @_;
        delete $me->{'wheel_server'};
        delete $me->{'wheel_client'};
      }
    );
}


	
		   
       

