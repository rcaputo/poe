#!/usr/bin/perl
# $Id$

# Test Filter::HTTPD by itself
# See other (forthcoming) for more complex interactions

use warnings;
use strict;

use lib qw(./mylib ../mylib ../lib ./lib);

use Data::Dumper;

BEGIN {
    eval " use HTTP::Request; use HTTP::Request::Common; ";
    if($@) {
        eval " use Test::More skip_all => 'HTTP::Request is needed for these tests.' ";
    } else {
        eval {
            eval " use Test::More tests => 56; ";
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

{ # simple post {{{ 

    my $post_request = POST 'http://localhost/foo.mhtml', [ 'I' => 'like', 'tasty' => 'pie' ];
    $post_request->protocol('HTTP/1.0');

    my $filter = POE::Filter::HTTPD->new();

    my $str = $post_request->as_string;
    
    my $data;
    eval { $data = $filter->get([ $str ]); };
    ok(!$@, 'simple post: get() throws no exceptions');
    ok(defined $data, "simple post: get() returns something");
    is(ref $data, 'ARRAY', 'simple post: get() returns list of requests');
    is(scalar @$data, 1, 'simple post: get() returned single request');

    my $req = shift @$data;
   
    is(ref $req, 'HTTP::Request',
        'simple post: get() returns HTTP::Request object');

    is($req->method, 'POST',
        'simple post: HTTP::Request object contains proper HTTP method');

    is($req->url, 'http://localhost/foo.mhtml',
        'simple post: HTTP::Request object contains proper URI');

    is($req->content, "I=like&tasty=pie\n", 
        'simple post: HTTP::Request object contains proper content');

    is($req->header('Content-Type'), 'application/x-www-form-urlencoded',
        'simple post: HTTP::Request object contains proper Content-Type header');

} # }}}

{ # simple head {{{ 

        
    my $head_request = HEAD 'http://localhost/foo.mhtml';

    my $filter = POE::Filter::HTTPD->new();

    my $data;
    eval { $data = $filter->get([ $head_request->as_string ]); };
    ok(!$@, 'simple head: get() throws no exceptions');
    ok(defined $data, "simple head: get() returns something");
    is(ref $data, 'ARRAY', 'simple head: get() returns list of requests');
    is(scalar @$data, 1, 'simple head: get() returned single request');

    my $req = shift @$data;
   
    is(ref $req, 'HTTP::Request',
        'simple head: get() returns HTTP::Request object');

    is($req->method, 'HEAD',
        'simple head: HTTP::Request object contains proper HTTP method');

    is($req->url, 'http://localhost/foo.mhtml',
        'simple head: HTTP::Request object contains proper URI');

} # }}}

SKIP: { # simple put {{{ 
    
    skip "PUT not supported yet.", 7;
    my $put_request = PUT 'http://localhost/foo.mhtml';

    my $filter = POE::Filter::HTTPD->new();

    my $data;
    eval { $data = $filter->get([ $put_request->as_string ]); };
    ok(!$@, 'simple put: get() throws no exceptions');
    ok(defined $data, "simple put: get() returns something");
    is(ref $data, 'ARRAY', 'simple put: get() returns list of requests');
    is(scalar @$data, 1, 'simple put: get() returned single request');

    my $req = shift @$data;
   
    is(ref $req, 'HTTP::Request',
        'simple put: get() returns HTTP::Request object');

    is($req->method, 'PUT',
        'simple put: HTTP::Request object contains proper HTTP method');

    is($req->url, 'http://localhost/foo.mhtml',
        'simple put: HTTP::Request object contains proper URI');

} # }}}

{ # multipart form data post {{{ 

    my $request = POST 'http://localhost/foo.mhtml', Content_Type => 'form-data', 
                    content => [ 'I' => 'like', 'tasty' => 'pie', 
                                 file => [ 't/19_filterchange.t' ]
                               ];
    $request->protocol('HTTP/1.0');

    my $filter = POE::Filter::HTTPD->new();

    my $data;
    eval { $data = $filter->get([ $request->as_string ]); };
    ok(!$@, 'multipart form data: get() throws no exceptions');
    ok(defined $data, "multipart form data: get() returns something");
    is(ref $data, 'ARRAY', 'multipart form data: get() returns list of requests');
    is(scalar @$data, 1, 'multipart form data: get() returned single request');

    my $req = shift @$data;
   
    is(ref $req, 'HTTP::Request',
        'multipart form data: get() returns HTTP::Request object');

    is($req->method, 'POST',
        'multipart form data: HTTP::Request object contains proper HTTP method');

    is($req->url, 'http://localhost/foo.mhtml',
        'multipart form data: HTTP::Request object contains proper URI');

    like($req->header('Content-Type'), qr#multipart/form-data#,
        'multipart form data: HTTP::Request object contains proper Content-Type header');

    like($req->content, qr#&results;.*?exit;#s,
            'multipart form data: content seems to contain all data sent');

} # }}}
