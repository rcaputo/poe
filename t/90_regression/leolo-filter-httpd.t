#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use POE;
use POE::Wheel::ReadWrite;
use POE::Filter::HTTPD;
use IO::Socket::INET;
use Data::Dump qw( pp );

sub DEBUG () { 0 }


foreach my $package ( qw( LWP::UserAgent HTTP::Request::Common CGI 
                          File::Temp LWP::ConnCache ) ) {
    eval "use $package";
    next unless $@;
    plan skip_all => "$package isn't available";
    exit 0;
}

my $socket = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    Listen => 1,
    ReuseAddr => 1
);
unless( $socket ) {
    plan skip_all => "Unable to create socket: $!";
    exit 0;
}

my $sockhost = $socket->sockhost();
my $sockport = $socket->sockport();

# $DB::fork_TTY = '/dev/pts/1';
my $pid = fork();
unless( defined $pid ) {
    plan skip_all => "Unable to fork: $!";
    exit 0;
}

#################################################
if( $pid ) {
    plan tests => 18;
    parent( $socket, $pid );
}
else {
    child( $sockhost, $sockport );
    exit 0;
}

pass( "DONE" );

#################################################
sub child
{
    my( $sockhost, $sockport ) = @_;

    my $uri = URI->new( "http://$sockhost:$sockport/upload" );

    my $UA = LWP::UserAgent->new;
    $UA->agent("$0/0.1 " . $UA->agent);
    my $CC = LWP::ConnCache->new( total_capacity => 100 );
    $UA->conn_cache( $CC );

    my $req = POST( $uri, 
                        Content_Type => 'form-data',
                        Content      => [ honk => 'bonk',
                                          zip  => 'zoip',
                                          something => [ $0 ]
                                        ] );
    $req->protocol('HTTP/1.1');
    DEBUG and warn "$$: req 1";
    my $resp = $UA->request( $req );
    die "$$: Failed request 1: ", $resp->status_line unless $resp->is_success;

    $uri->path( "/other" );
    $req = POST( $uri,  Content_Type => 'form-data',
                        Content      => [ take => 'five',
                                          dave => 'brubeck',
                                        ] );
    $req->protocol('HTTP/1.1');
    DEBUG and warn "$$: req 2";
    $resp = $UA->request( $req );
    die "$$: Failed request 2: ", $resp->status_line unless $resp->is_success;

    $uri->path( "/done" );
    $uri->query_form( bon => 'jour' );
    $req = GET( $uri );
    $req->protocol('HTTP/1.1');
    DEBUG and warn "$$: req 3";
    $resp = $UA->request( $req );
    die "$$: Failed request 3: ", $resp->status_line unless $resp->is_success;
}



#################################################
sub parent
{
    my( $sock, $pid ) = @_;

    my $read = $sock->accept();
    POE::Session->create( 
                package_states => [
                    Parent => [ qw( _start _stop input error ) ],
                ],
                heap => { client => $read, pid => $pid }
        );
    $poe_kernel->run;
}

#################################################
package Parent;

use strict;
use warnings;

use POE;
use Test::More;

use File::Temp qw( tempfile );
use Scalar::Util qw( blessed );

use HTTP::Request::Common qw( POST GET );

use HTTP::Status qw( status_message RC_BAD_REQUEST RC_OK RC_LENGTH_REQUIRED  
                                    RC_REQUEST_ENTITY_TOO_LARGE );
use Data::Dump qw( pp );

##############
sub _start
{
    my( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    ::DEBUG and diag "$$: _start";
    $kernel->alias_set( __PACKAGE__ );

    $heap->{wheel} = POE::Wheel::ReadWrite->new( 
                        Handle => $heap->{client},
                        Filter => POE::Filter::HTTPD->new( Streaming => 1 ),
                        InputEvent => 'input',    
                        ErrorEvent => 'error'
                    );
}

##############
sub _stop
{
    my( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    ::DEBUG and diag "$$: _stop";
    delete $heap->{client};
    delete $heap->{wheel};
}

##############
sub mk_response 
{
    my( $code, $msg ) = @_;
    my $resp = HTTP::Response->new( $code, $msg );
    $resp->content( $msg );
    $resp->header( 'Content-Length' => length $msg );
    $resp->header( 'Connection' => 'keepalive' ) 
                if $code < 400;
    $resp->protocol( 'HTTP/1.1' );
    return $resp;
}


sub input
{
    my( $kernel, $heap, $req_or_data ) = @_[ KERNEL, HEAP, ARG0 ];
    ::DEBUG and diag "$$: input";
    if( blessed $req_or_data ) {
        # Find errors
        unless( isa_ok( $req_or_data, "HTTP::Request" ) ) {
            ::DEBUG and diag( "$$: ".$req_or_data->status_line );
            $heap->{wheel}->put( $req_or_data );
            return;
        }
            
        # Handle a new request
        ::DEBUG and diag "$$: request";
        $heap->{req} = $req_or_data;

        if( $heap->{req}->method eq 'GET' ) {
            ::DEBUG and diag( "$$: GET" );
            handle_get( $heap );
            delete $heap->{req};
            return;
        }


        # make sure content is small enough
        if( $heap->{req}->header( 'content-length' ) > 1024*1024 ) {
            ::DEBUG and diag "$$: to much (".$heap->{req}->header( 'content-length' ).")";
            $heap->{wheel}->put( mk_response( RC_REQUEST_ENTITY_TOO_LARGE, 
                                                 "So much content!" ) );
            delete $heap->{req};
            return;
        }

        # read content into this file
        my( $fh, $file ) = tempfile( "httpd-XXXXXXXX", TMPDIR=>1 );
        ::DEBUG and diag( "$$: file=$file, fh=$fh" );
        $heap->{content_file} = $file;
        $heap->{content_fh} = $fh;
        $heap->{content_size} = 0;
    }
    else {
        unless( $heap->{req} ) {
            ::DEBUG and diag( "$$: no req" );
        }
        $heap->{content_size} += length( $_[ARG0] );
        ::DEBUG and diag( "$$: size=$heap->{content_size}" );
        my $n = $heap->{content_fh}->print( $_[ARG0] );
        die "Can't write: $!" unless $n > 0;
        if( $heap->{content_size} >= $heap->{req}->header( 'content-length' ) ) {
            delete $heap->{content_fh};
            delete $heap->{content_size};

            if( $heap->{req}->method eq 'POST' ) {
                handle_post( $heap );
            }
            delete $heap->{req};
        }
    }
    return;
}

##############
sub error
{
    my( $kernel, $heap, $op, $errnum, $errstr, $wid ) = @_[ KERNEL, HEAP, ARG0..$#_ ];

    ::DEBUG and diag "$$: error";
    unless( $op eq 'read' and $errnum == 0 ) {
        fail "$op error: ($errnum) $errstr";
    }
    delete $heap->{client};
    delete $heap->{wheel};
    waitpid $heap->{pid}, 0;
}


##############
sub handle_post
{
    my( $heap ) = @_;

    # Now we have to load and parse $heap->{content_file}            

    # Thank you Mr. Stein et al for not only including a kitchen sink in
    # CGI.pm but also all the hammers necessary to make more kitchen
    # sinks...

    local $ENV{REQUEST_METHOD} = 'POST';
    local $CGI::PERLEX = $CGI::PERLEX = "CGI-PerlEx/Fake";
    local $ENV{CONTENT_TYPE} = $heap->{req}->header( 'content-type' );
    local $ENV{CONTENT_LENGTH} = $heap->{req}->header( 'content-length' );
    # CGI->read_from_client reads from STDIN
    my $keep = IO::File->new( "<&STDIN" ) or die "Unable to reopen STDIN: $!";
    open STDIN, "<$heap->{content_file}" or die "Reopening STDIN failed: $!";
    ::DEBUG and diag( "$$: read $heap->{content_file}" );
    my $cgi = CGI->new();
    open STDIN, "<&".$keep->fileno or die "Unable to reopen $keep: $!";
    undef $keep;
    unlink delete $heap->{content_file};

    # Now check what we received
    isa_ok( $cgi, "CGI" );

    my $path = $heap->{req}->uri->path;
    if( $path eq '/upload' ) {
        is_deeply( [ sort $cgi->param ], [ sort qw( honk zip something) ], "Got 3 params" );
        is( $cgi->param( 'honk' ), 'bonk', " ... honk" );
        is( $cgi->param( 'zip' ), 'zoip', " ... zip" );

        my $fh = $cgi->upload( 'something' );
        ok( $fh, " ... something" );
        isa_ok( $fh, "Fh" ); # CGI's "lightweight" filehandle
        ok( $cgi->param( 'something' ), " ... filename");

        $heap->{wheel}->put( mk_response( RC_OK, "Thank you" ) );
    }
    elsif( $path eq '/other' ) {
        is_deeply( [ sort $cgi->param ], [ sort qw( take dave) ], "Got 2 params" );
        is( $cgi->param( 'take' ), 'five', " ... take" );
        is( $cgi->param( 'dave' ), 'brubeck', " ... dave" );

        $heap->{wheel}->put( mk_response( RC_OK, "Thank you" ) );
    }
}


##############
sub handle_get
{
    my( $heap ) = @_;

    local $ENV{REQUEST_METHOD} = 'GET';
    local $CGI::PERLEX = $CGI::PERLEX = "CGI-PerlEx/Fake";
    local $ENV{CONTENT_TYPE} = $heap->{req}->header( 'content-type' );
    local $ENV{'QUERY_STRING'} = $heap->{req}->uri->query;
    
    my $cgi = CGI->new();

    isa_ok( $cgi, "CGI" );
    is_deeply( [ sort $cgi->param ], [ sort qw( bon ) ], "Got 1 params" );
    is( $cgi->param( 'bon' ), 'jour', " ... bon" );

    $heap->{wheel}->put( mk_response( RC_OK, "DONE" ) );

}
