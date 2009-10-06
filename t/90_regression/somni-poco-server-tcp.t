# vim: ts=2 sw=2 filetype=perl expandtab
use warnings;
use strict;

BEGIN {
    my $error;
    unless (-f 'run_network_tests') {
        $error = "Network access (and permission) required to run this test";
    }

    if ($error) {
        print "1..0 # Skip $error\n";
        exit;
    }
}

use POE;
use POE::Component::Server::TCP;
use POE::Component::Client::TCP;
use Socket      qw(sockaddr_in inet_ntoa);
use List::Util  qw(first);

use Test::More tests => 43;


{
    my @state = run();

    ok_state_top(\@state, 'server started');
    ok_state_top(\@state, 'client started');
    ok_state_top(\@state, 'client connected to server');
    ok_state_top(\@state, 'client connected');
    ok_state_top(\@state, 'client flushed');
    ok_state_any(\@state, 'received from server: I will be serving you today!');
    ok_state_any(\@state, 'received from client: I am your new client!');
    ok_state_top(\@state, 'received from server: Go away.');
    ok_state_top(\@state, 'client disconnected');
    ok_state_empty(\@state);
}
{
    my @state = run( Port => 0 );

    ok_state_top(\@state, 'server started');
    ok_state_top(\@state, 'client started');
    ok_state_top(\@state, 'client connected to server');
    ok_state_top(\@state, 'client connected');
    ok_state_top(\@state, 'client flushed');
    ok_state_any(\@state, 'received from server: I will be serving you today!');
    ok_state_any(\@state, 'received from client: I am your new client!');
    ok_state_top(\@state, 'received from server: Go away.');
    ok_state_top(\@state, 'client disconnected');
    ok_state_empty(\@state);
}
{
    my @state = run(
        ClientArgs      =>  [ '', \"", {}, [] ],
        ListenerArgs    =>  [ [], {}, \"", '' ],
    );

    ok_state_top(\@state, 'server started: ARRAY HASH SCALAR none');
    ok_state_top(\@state, 'client started');
    ok_state_top(\@state, 'client connected to server: none SCALAR HASH ARRAY');
    ok_state_top(\@state, 'client connected');
    ok_state_top(\@state, 'client flushed');
    ok_state_any(\@state, 'received from server: I will be serving you today!');
    ok_state_any(\@state, 'received from client: I am your new client!');
    ok_state_top(\@state, 'received from server: Go away.');
    ok_state_top(\@state, 'client disconnected');
    ok_state_empty(\@state);
}
{
    my @state = run(
        InlineStates    =>  { InlineStates_test => \&InlineStates_test },
        ObjectStates    =>  [
            bless({}, 'ObjectStates_test') => { ObjectStates_test => 'test' }
        ],
        PackageStates   =>  [
            'PackageStates_test' => { PackageStates_test => 'test' },
        ],
    );

    ok_state_top(\@state, 'server started');
    ok_state_top(\@state, 'client started');
    ok_state_top(\@state, 'client connected to server');
    ok_state_top(\@state, 'client connected');
    ok_state_top(\@state, 'InlineStates test: from server_client_connected');
    ok_state_top(\@state, 'ObjectStates test: from server_client_connected');
    ok_state_top(\@state, 'PackageStates test: from server_client_connected');
    ok_state_top(\@state, 'client flushed');
    ok_state_any(\@state, 'received from server: I will be serving you today!');
    ok_state_any(\@state, 'received from client: I am your new client!');
    ok_state_top(\@state, 'received from server: Go away.');
    ok_state_top(\@state, 'client disconnected');
    ok_state_empty(\@state);
}



### TESTING SUBROUTINES ###

sub ok_state_empty { ok((not @{ $_[0] }), 'state is empty') }

sub ok_state_top {
    my($state, $value) = @_;
    is($state->[0], $value, $value);
    shift @$state if $state->[0] eq $value;
}




sub ok_state_any {
    my($state, $value) = @_;
    foreach my $i (0 .. $#$state) {
        if ($state->[$i] eq $value) {
            is($state->[$i], $value, $value);
            splice(@$state, $i, 1);
            return;
        }
    }

    fail($value);
}




### UTILITY SUBROUTINES ###

sub run {
    my %args = @_;

    our @state;
    local @state;

    POE::Component::Server::TCP->new(
        Address             =>  '127.0.0.1',
        Alias               =>  'server',
        Started             =>  \&server_started,
        ClientConnected     =>  \&server_client_connected,
        ClientDisconnected  =>  \&server_client_disconnected,
        ClientInput         =>  \&server_client_input,

        %args,
    );

    POE::Kernel->run();

    return @state;
}




sub arginfo {
    my @args = @_[ARG0 .. $#_];
    return '' unless @args;
    return ': ' . join(" ", map { ref or 'none' } @_[ARG0 .. $#_]);
}




### CALLBACK SUBROUTINES ###

sub ObjectStates_test::test  { state("ObjectStates test: $_[ARG0]")  }
sub PackageStates_test::test { state("PackageStates test: $_[ARG0]") }
sub InlineStates_test        { state("InlineStates test: $_[ARG0]")  }

sub server_started {
    my($kernel, $heap) = @_[KERNEL,HEAP];
    my($port, $address) = sockaddr_in($heap->{'listener'}->getsockname);

    state('server started', arginfo(@_));

    POE::Component::Client::TCP->new(
        RemoteAddress   =>  inet_ntoa($address),
        RemotePort      =>  $port,
        Started         =>  \&client_started,
        Connected       =>  \&client_connected,
        ServerInput     =>  \&client_input,
        ServerFlushed   =>  \&client_flushed,
    );

    $kernel->yield( 'InlineStates_test'  => 'from server_started' );
    $kernel->yield( 'ObjectStates_test'  => 'from server_started' );
    $kernel->yield( 'PackageStates_test' => 'from server_started' );
}




sub server_client_connected {
    my($kernel, $heap) = @_[KERNEL,HEAP];

    state('client connected to server', arginfo(@_));
    $heap->{'client'}->put('I will be serving you today!');

    $kernel->yield( 'InlineStates_test'  => 'from server_client_connected' );
    $kernel->yield( 'ObjectStates_test'  => 'from server_client_connected' );
    $kernel->yield( 'PackageStates_test' => 'from server_client_connected' );
}




sub client_connected {
    state('client connected');
    $_[HEAP]{'server'}->put('I am your new client!');
}




sub server_client_disconnected {
    state('client disconnected');
    $_[KERNEL]->post( server => 'shutdown' );
}




sub client_input {
    my($msg) = $_[ARG0];
    state("received from server: $msg");
    $_[KERNEL]->yield('shutdown') if $msg eq 'Go away.';
}




sub server_client_input {
    state("received from client: $_[ARG0]");
    $_[HEAP]{'client'}->put('Go away.');
}




sub client_flushed { state('client flushed') }
sub client_started { state('client started') }

sub state { push our @state, join("", @_) }
