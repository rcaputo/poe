#!/usr/bin/perl
# $Id$

# Test Filter::HTTPD by itself
# See other (forthcoming) for more complex interactions

use warnings;
use strict;

use Data::Dumper;

BEGIN {
    eval " use HTTP::Request; ";
    if($@) {
        eval " use Test::More skip_all => 'HTTP::Request is needed for these tests.' ";
    } else {
        eval {
            eval " use Test::More 'no_plan'; ";
            use_ok('POE::Filter::HTTPD');
        }
    }
}


{ # simple get {{{
    
    my $filter;

    eval { $filter = POE::Filter::HTTPD->new() };
    ok(!$@, 'new() throws no exceptions');
    ok(defined $filter, 'new() returns something');
    is(ref $filter, 'POE::Filter::HTTPD', 'new() returns properly blessed object');

    my $get_request = HTTP::Request->new('GET', 'http://localhost/pie.mhtml');
    my $data;
    eval { $data = $filter->get([ $get_request->as_string() ]); };
    ok(!$@, 'simple get: get() throws no exceptions');
    ok(defined $data, "simple get: get() returns something");
    is(ref $data, 'ARRAY', 'simple get: get() returns list of requests');
    is(scalar @$data, 1, 'simple get: get() returned single request');

    my $req = shift @$data;
    
    is(ref $req, 'HTTP::Request', 'simple get: get() returns HTTP::Request object');
    is($req->method, 'GET', 'simple get: HTTP::Request object contains proper HTTP method');
    is($req->url, 'http://localhost/pie.mhtml', 'simple get: HTTP::Request object contains proper URI');
    is($req->content, '', 'simple get: HTTP::Request object properly contains no content');

} # }}}

{ # More complex get {{{
    
    my $filter;

    $filter = POE::Filter::HTTPD->new();

    my $get_data = q|GET /foo.html HTTP/1.0
User-Agent: Wget/1.8.2
Host: localhost:8080
Accept: */*
Connection: Keep-Alive

|;
    my $data;
    eval { $data = $filter->get([ $get_data ]); };
    ok(!$@, 'HTTP 1.0 get: get() throws no exceptions');
    ok(defined $data, "HTTP 1.0 get: get() returns something");
    is(ref $data, 'ARRAY', 'HTTP 1.0 get: get() returns list of requests');
    is(scalar @$data, 1, 'HTTP 1.0 get: get() returned single request');

    my $req = shift @$data;
    is(ref $req, 'HTTP::Request',
        'HTTP 1.0 get: get() returns HTTP::Request object');
    
    is($req->method, 'GET', 
        'HTTP 1.0 get: HTTP::Request object contains proper HTTP method');

    is($req->url, '/foo.html', 
        'HTTP 1.0 get: HTTP::Request object contains proper URI');
    
    is($req->content, '', 
        'HTTP 1.0 get: HTTP::Request object properly contains no content');
    is($req->header('User-Agent'), 'Wget/1.8.2', 
        'HTTP 1.0 get: HTTP::Request object contains proper User-Agent header');
    
    is($req->header('Host'), 'localhost:8080', 
        'HTTP 1.0 get: HTTP::Request object contains proper Host header');
    
    is($req->header('Accept'), '*/*', 
        'HTTP 1.0 get: HTTP::Request object contains proper Accept header');

    is($req->header('Connection'), 'Keep-Alive', 
        'HTTP 1.0 get: HTTP::Request object contains proper Connection header');

} # }}}


