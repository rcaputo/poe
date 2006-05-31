use strict;
use warnings;
use POE qw(Wheel::Run Component::Client::UserAgent);
use HTTP::Request::Common;

my $make = '/usr/pkg/bin/gmake';
my $perl = '/usr/bin/perl';
my $working = '/home/chris/dev/poe/poe/';
my $pbotutil = '/usr/pkg/bin/pbotutil';
my $pbotopts = [ '-s', 'shadow', '-c', '#poe', '-u', 'POESmoke', '-m', 'Results of TEST' ];

POE::Component::Client::UserAgent->new();

POE::Session->create(
  package_states => [
	'main' => [qw(_start _stop _output _wheel_error _wheel_close sig_chld process _response)],
  ],
  options => { trace => 0 },
);

$poe_kernel->run();
exit 0;

sub sig_chld {
  my ($kernel,$heap,$thing,$pid,$status) = @_[KERNEL,HEAP,ARG0,ARG1,ARG2];
  my $processed = delete $heap->{processing}->{ $pid };
  return $poe_kernel->sig_handled() unless $processed;
  print STDOUT "Cmd: ", join(' ', @{ $processed }), " Status: $status\n";
  $heap->{status} = $status unless $status == 0;
  $poe_kernel->sig_handled();
}

sub _start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  $kernel->alias_set("Smoker");
  chdir $working;
  $heap->{status} = 0;
  $heap->{output} = [ ];
  $heap->{todo} = [ [ "$perl Makefile.PL", '--default' ],
		    [ $make ], [ $make, 'test' ], [ $make, 'distclean' ], ];
  $heap->{processing} = { };
  $kernel->sig( CHLD => 'sig_chld' );
  $poe_kernel->yield( 'process' );
  undef;
}

sub process {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  my $todo = shift @{ $heap->{todo} };
  unless ( $todo ) {
	my $postback = $_[SESSION]->postback('_response');
	my %formdata = ( channel => '#poe', nick => 'POEsmoker', summary => 'Results of svn POE Smoke', paste => join( "\n", @{ $heap->{output} } ) );
	my $request = HTTP::Request::Common::POST( 'http://scsys.co.uk:8001/paste' => [ %formdata ] );
	$poe_kernel -> post (useragent => request => { request => $request, response => $postback } );
  	return;
  }
  my $cmd = shift @{ $todo };
  my $wheel = POE::Wheel::Run->new(
	Program => $cmd,
	ProgramArgs => $todo,
	StdoutEvent => '_output',
	StderrEvent => '_output',
	ErrorEvent => '_wheel_error',
        CloseEvent => '_wheel_close',
  );
  if ( $wheel ) {
    $heap->{wheels}->{ $wheel->ID() } = $wheel;
    $heap->{processing}->{ $wheel->PID() } = [ $cmd, @{ $todo } ];
  }
  undef;
}

sub _stop {
  print STDOUT $_, "\n" for @{ $_[HEAP]->{output} };
  print STDOUT "Something went wrong\n" if $_[HEAP]->{status};
  undef;
}

sub _output {
  push @{ $_[HEAP]->{output} }, $_[ARG0];
  undef;
}

sub _wheel_error {
  my ($heap,$wheel_id) = @_[HEAP,ARG3];
  delete $heap->{wheels}->{ $wheel_id };
  $poe_kernel->yield( 'process' );
  undef;
}

sub _wheel_close {
  my ($heap,$wheel_id) = @_[HEAP,ARG0];
  delete $heap->{wheels}->{ $wheel_id };
  undef;
}

sub _response {
  my ($kernel,$heap) = @_[KERNEL,HEAP];
  my ($request, $response, $entry) = @{$_[ARG1]};
  print STDOUT $response -> status_line;
  $kernel->alias_remove($_) for $kernel->alias_list();
  $kernel->post (useragent => 'shutdown');
  undef;
}
