#!/usr/bin/perl
# $Id$

# Test Filter::HTTPD by itself
# See other (forthcoming) for more complex interactions

use warnings;
use strict;

use Data::Dumper;

BEGIN {
    eval " use HTTP::Request; use HTTP::Request::Common; ";
    if($@) {
        eval " use Test::More skip_all => 'HTTP::Request is needed for these tests.' ";
    } else {
        eval {
            eval " use Test::More tests => 47; ";
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

SKIP: { # simple post {{{ 

    my $post_request = POST 'http://localhost/foo.mhtml', [ 'I' => 'like', 'tasty' => 'pie' ];

    my $filter = POE::Filter::HTTPD->new();

    # If i'm reading the rfc right, and i'm pretty sure i am, POST is not a 
    # request type in HTTP 0.9. HTTP::Request::Common generates a POST
    # transaction that is missing an HTTP Version string. By rfc, 
    # the parser falls back to 0.9 mode which makes the post data invalid.
    # Until i get a patch into Gisle to fix this and until we can be
    # reasonably sure its installed everywhere (: never), i hack
    # an HTTP version string into the post data.

    my $str = $post_request->as_string;
    $str =~ s#POST (\S+)#POST \1 HTTP/1.0#s;
    
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
