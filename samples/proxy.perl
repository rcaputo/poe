#!/usr/bin/perl -w -I..
# $Id$

use strict;
use POE qw(Wheel::ListenAccept Wheel::ReadWrite Driver::SysRW Filter::Line);
use vars qw($kernel);
use IO::Socket::INET;

$kernel = new POE::Kernel();
                                        # serial number
my $log_id = 0;
                                        # server session
foreach my $redirection
  ( qw( 127.0.0.1:7000-127.0.0.1:7001
        127.0.0.1:7001-127.0.0.1:7002
        127.0.0.1:7002-127.0.0.1:7003
        127.0.0.1:7003-127.0.0.1:7004
        127.0.0.1:7004-127.0.0.1:7005
        127.0.0.1:7005-127.0.0.1:7006
        127.0.0.1:7006-127.0.0.1:7007
        127.0.0.1:7007-127.0.0.1:7008
        127.0.0.1:7008-127.0.0.1:7009
        127.0.0.1:7009-perl.com:daytime
        127.0.0.1:7777-127.0.0.1:30019
      )
  )
{
  my ($local_address, $local_port, $remote_address, $remote_port) =
    split(/[-:]+/, $redirection);

  new POE::Session
    ( $kernel,
      _start => sub {
        my ($k, $me, $from) = @_;

        $me->{'local_address'}  = $local_address;
        $me->{'local_port'}     = $local_port;
        $me->{'remote_address'} = $remote_address;
        $me->{'remote_port'}    = $remote_port;

        print "? redirecting $local_address:$local_port ",
              "to $remote_address:$remote_port\n";

        my $listener = new IO::Socket::INET
          ( 'LocalHost' => $local_address,
            'LocalPort' => $local_port,
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
          print "+ listening on $local_address:$local_port\n";
        }
        else {
          warn "- could not listen on $local_address:$local_port: $!\n";
        }
      },
      'accept error' => sub { 
        my ($k, $me, $from, $operation, $errnum, $errstr) = @_;
        print "! $me->{'local_address'}:$me->{'local_port'}: ",
              "$operation error $errnum: $errstr\n";
      },
      'accept' => \&accept_and_start,
    );
}

$kernel->run();
                                        # spawn a proxy session for connections
sub accept_and_start {
  my ($kernel, $me, $from,$accepted_handle) = @_;
  my ($peer_host,$peer_port) = ( $accepted_handle->peerhost(),
                                 $accepted_handle->peerport()
			       );

  print "< accepted connection from $peer_host:$peer_port\n";

  my $remote_address = $me->{'remote_address'};
  my $remote_port = $me->{'remote_port'};

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

        $me->{'log'} = $log_id++;

        print "[$me->{'log'}] ? linking $peer_host:$peer_port to ",
              "$remote_address:$remote_port\n";

        my $server = new IO::Socket::INET
          ( 'PeerHost' => $remote_address,
            'PeerPort' => $remote_port,
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
          print "[$me->{'log'}] + proxy session $me started\n";
        }
        else {
          print "[$me->{'log'}] - couldn't connect to ",
                "$remote_address:$remote_port: $!\n";
          delete $me->{'wheel_client'};
        }
      },
      _stop => sub {
        my ($k, $me) = @_;
        print "[$me->{'log'}] - proxy session $me shut down\n";
      },
      'client' => sub {
        my ($k,$me,$from,$line) = @_;
       (exists $me->{wheel_server}) && $me->{wheel_server}->put($line);
      },
      'client_error' => sub {
        my ($k,$me,$from,$operation,$errnum,$errstr) = @_;
        if ($errnum) {
          print "[$me->{'log'}] ! $operation error $errnum ($errstr)\n";
        }
        else {
          print "[$me->{'log'}] * client closed connection\n";
        }
                                        # stop the wheels
        delete $me->{'wheel_client'};
        delete $me->{'wheel_server'};
      },
      'server' => sub {
        my ($k,$me,$from,$line) = @_;
        (exists $me->{wheel_client}) && $me->{wheel_client}->put($line);
      },
      'server_error' => sub {
        my ($k,$me,$from,$operation,$errnum,$errstr) = @_;
        if ($errnum) {
          print "[$me->{'log'}] ! $operation error $errnum ($errstr)\n";
        }
        else {
          print "[$me->{'log'}] * server closed connection\n";
        }
                                        # stop the wheels
        delete $me->{'wheel_client'};
        delete $me->{'wheel_server'};
      },
    );
}
