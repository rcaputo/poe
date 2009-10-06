#!/usr/bin/perl -w
# vim: ts=2 sw=2 filetype=perl expandtab

# Test Filter::HTTPD by itself
# See other (forthcoming) for more complex interactions

use strict;

use lib qw(./mylib ../mylib);

use Test::More;

BEGIN {
  unless (-f 'run_network_tests') {
      plan skip_all => 'Need network access (and permission) for these tests';
  }

  foreach my $req (qw(HTTP::Request HTTP::Request::Common HTTP::Status)) {
    eval "use $req";
    if ($@) {
      plan skip_all => "$req is needed for these tests.";
    }
  }
}

BEGIN {
  plan tests => 112;
}

use_ok('POE::Filter::HTTPD');

# takes a object, and a hash { method_name => expected_value },
# and an optional name for the test
# uses is(), so values are simple scalars
sub check_fields {
  my ($object, $expected, $name) = @_;
  $name = $name ? "$name: " : "";
  while (my ($method, $expected_value) = each %$expected) {
    is($object->$method, $expected_value, "$name$method");
  }
}

sub check_error_response {
  my ($data, $code, $label) = @_;

  ok(
    (ref($data) eq 'ARRAY') &&
    (scalar(@$data) == 1) &&
    ($$data[0]->code == $code),
    $label
  );
}

{ # simple get {{{
    my $filter = POE::Filter::HTTPD->new();
    isa_ok($filter, 'POE::Filter::HTTPD');

    my $get_request =
      HTTP::Request->new('GET', 'http://localhost/pie.mhtml');

    my $records = $filter->get([ $get_request->as_string ]);
    is(ref($records), 'ARRAY', 'simple get: get() returns list of requests');
    is(scalar(@$records), 1, 'simple get: get() returned single request');

    my ($req) = @$records;

    isa_ok($req, 'HTTP::Request', 'simple get');
    check_fields($req, {
        method => $get_request->method,
        url => $get_request->url,
        content => $get_request->content,
      }, "simple get");
} # }}}

{ # More complex get {{{
    my $filter = POE::Filter::HTTPD->new();

    my $get_data = q|GET /foo.html HTTP/1.0
User-Agent: Wget/1.8.2
Host: localhost:8080
Accept: */*
Connection: Keep-Alive

|;

    my $data = $filter->get([ $get_data ]);
    is(ref $data, 'ARRAY', 'HTTP 1.0 get: get() returns list of requests');
    is(scalar @$data, 1, 'HTTP 1.0 get: get() returned single request');

    my ($req) = @$data;

    isa_ok($req, 'HTTP::Request', 'HTTP 1.0 get');
    check_fields($req, {
        method => 'GET',
        url => '/foo.html',
        content => '',
      }, "HTTP 1.0 get");

    my %headers = (
      'User-Agent' => 'Wget/1.8.2',
      'Host' => 'localhost:8080',
      'Accept' => '*/*',
      'Connection' => 'Keep-Alive',
    );

    while (my ($k, $v) = each %headers) {
      is($req->header($k), $v, "HTTP 1.0 get: $k header");
    }
} # }}}

{ # simple post {{{
    my $post_request = POST 'http://localhost/foo.mhtml', [ 'I' => 'like', 'tasty' => 'pie' ];
    $post_request->protocol('HTTP/1.0');

    my $filter = POE::Filter::HTTPD->new();

    my $data = $filter->get([ $post_request->as_string ]);
    is(ref $data, 'ARRAY', 'simple post: get() returns list of requests');
    is(scalar @$data, 1, 'simple post: get() returned single request');

    my ($req) = @$data;

    isa_ok($req, 'HTTP::Request',
        'simple post: get() returns HTTP::Request object');

    check_fields($req, {
        method => 'POST',
        url => 'http://localhost/foo.mhtml',
        protocol => 'HTTP/1.0',
      }, "simple post");

    # The HTTP::Request bundled with ActivePerl 5.6.1 causes a test
    # failure here.  The one included in ActivePerl 5.8.3 works fine.
    # It was suggested by an anonymous bug reporter to test against
    # HTTP::Request's version rather than Perl's, so we're doing that
    # here.  Theoretically we shouldn't get this far.  The Makefile
    # magic should strongly suggest HTTP::Request 1.34.  But people
    # install (or fail to) the darnedest things, so I thought it was
    # safe to check here rather than fail the test due to operator
    # error.
    SKIP: {
      my $required_http_request_version = 1.34;
      skip("simple post: Please upgrade HTTP::Request to $required_http_request_version or later", 1)
        if $^O eq "MSWin32" and $HTTP::Request::VERSION < $required_http_request_version;

      is($req->content, "I=like&tasty=pie",
        'simple post: HTTP::Request object contains proper content');

      is( length($req->content), $req->header('Content-Length'),
        'simple post: Content is the right length');
    }

    is($req->header('Content-Type'), 'application/x-www-form-urlencoded',
        'simple post: HTTP::Request object contains proper Content-Type header');
} # }}}

{ # simple head {{{
    my $head_request = HEAD 'http://localhost/foo.mhtml';

    my $filter = POE::Filter::HTTPD->new();

    my $data = $filter->get([ $head_request->as_string ]);
    is(ref $data, 'ARRAY', 'simple head: get() returns list of requests');
    is(scalar @$data, 1, 'simple head: get() returned single request');

    my ($req) = @$data;

    isa_ok($req, 'HTTP::Request',
        'simple head: get() returns HTTP::Request object');

    check_fields($req, {
        method => 'HEAD',
        url => 'http://localhost/foo.mhtml',
      }, "simple head");
} # }}}

SKIP: { # simple put {{{
    skip "PUT not supported yet", 5;

    my $put_request = PUT 'http://localhost/foo.mhtml';

    my $filter = POE::Filter::HTTPD->new();

    my $data = $filter->get([ $put_request->as_string ]);
    is(ref $data, 'ARRAY', 'simple put: get() returns list of requests');
    is(scalar @$data, 1, 'simple put: get() returned single request');

    my ($req) = @$data;

    isa_ok($req, 'HTTP::Request',
        'simple put: get() returns HTTP::Request object');

    check_fields($req, {
        method => 'PUT',
        url => 'http://localhost/foo.mhtml',
      }, "simple put");
} # }}}

{ # multipart form data post {{{
    my $request = POST(
      'http://localhost/foo.mhtml',
      Content_Type => 'form-data',
      content => [
        'I' => 'like', 'tasty' => 'pie', file => [ $0 ]
      ]
    );
    $request->protocol('HTTP/1.0');

    my $filter = POE::Filter::HTTPD->new();

    my $data = $filter->get([ $request->as_string ]);
    is(
      ref($data), 'ARRAY',
      'multipart form data: get() returns list of requests'
    );
    is(
      scalar(@$data), 1,
      'multipart form data: get() returned single request'
    );

    my ($req) = @$data;

    isa_ok(
      $req, 'HTTP::Request',
      'multipart form data: get() returns HTTP::Request object'
    );

    check_fields($req, {
        method => 'POST',
        url => 'http://localhost/foo.mhtml',
        protocol => 'HTTP/1.0',
      }, "multipart form data");

    if($] >= '5.006') {
        eval "
        like(\$req->header('Content-Type'), qr#multipart/form-data#,
            'multipart form data: HTTP::Request object contains proper Content-Type header');

        like(\$req->content, qr#&results;.*?exit;#s,
            'multipart form data: content seems to contain all data sent');
        ";
    } else {
        ok($req->header('Content-Type') =~ m{multipart/form-data},
          "multipart form data: HTTP::Request object contains proper Content-Type header");
        ok($req->content =~ m{&results;.*?exit;}s,
          'multipart form data: content seems to contain all data sent');
    }
} # }}}

{ # options request {{{
    my $request = HTTP::Request->new('OPTIONS', '*');
    $request->protocol('HTTP/1.0');

    my $filter = POE::Filter::HTTPD->new();

    my $data = $filter->get([ $request->as_string ]);
    is(ref $data, 'ARRAY', 'options: get() returns list of requests');
    is(scalar @$data, 1, 'options: get() returned single request');

    my ($req) = @$data;

    isa_ok($req, 'HTTP::Request',
        'options: get() returns HTTP::Request object');

    check_fields($req, {
        method => 'OPTIONS',
        url => '*',
        protocol => 'HTTP/1.0',
      }, 'options');
} # }}}

{ # unless specified, version defaults to HTTP/0.9 in get {{{
  my $req_str = <<'END';
GET /

END

  my $filter = POE::Filter::HTTPD->new;

  my $data = $filter->get([ $req_str ]);
  my ($req) = @$data;
  isa_ok($req, 'HTTP::Request', 'HTTP/0.9 defaulting: get gives HTTP::Request');
  check_fields($req, {
      method => 'GET',
      url => '/',
      protocol => 'HTTP/0.9',
    }, 'HTTP/0.9 defaulting');
} # }}}

{ # reconstruction from lots of fragments {{{
  my $req = POST 'http://localhost:1234/foobar.html',
      [ 'I' => 'like', 'honey' => 'with peas' ];
  $req->protocol('HTTP/1.1');
  my $req_as_string = $req->as_string();
  my @req_frags = ($req_as_string =~ m/(..)/sg);
  my $filter = POE::Filter::HTTPD->new;

  #my $pending_ok = 0;
  my $req_too_early;
  my @records;
  while (@req_frags) {
    my $data = $filter->get([ splice(@req_frags, 0, 2) ]);
    #$pending_ok++ if $filter->get_pending();
    if (@req_frags) {
      $req_too_early++ if @$data;
    }
    push @records, @$data;
  }

  #ok($pending_ok, 'fragments: get_pending() non-empty at some point');
  #is($filter->get_pending(), undef, 'fragments: get_pending() empty at end');
  ok(!$req_too_early, "fragments: get() returning nothing until end");

  is(scalar(@records), 1, 'fragments: only one request returned');
  isa_ok($records[0], 'HTTP::Request', 'fragments: request isa HTTP::Request');
  check_fields($req, {
      method => 'POST',
      url => 'http://localhost:1234/foobar.html',
      content => $req->content,
    }, 'fragments');

} # }}}

{ # trailing content on request {{{
  my $req = HTTP::Request->new('GET', 'http://localhost:1234/foobar.html');

  # request + trailing whitespace in one block == just request
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ $req->as_string . "\r\n  \r\n\n" ]);
    is(ref($data), 'ARRAY', 'trailing: whitespace in block: ref');
    is(scalar(@$data), 1, 'trailing: whitespace in block: one req');
    isa_ok($$data[0], 'HTTP::Request',
      'trailing: whitespace in block: HTTP::Request');
    check_fields($req, {
        method => 'GET',
        url => 'http://localhost:1234/foobar.html'
      }, 'trailing: whitespace in block');
  }

  # request + garbage together == request
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ $req->as_string . "GARBAGE!" ]);
    is(ref($data), 'ARRAY', 'trailing: garbage in block: ref');
    is(scalar(@$data), 1, 'trailing: garbage in block: one req');
    isa_ok($$data[0], 'HTTP::Request',
      'trailing: garbage in block: HTTP::Request');
    check_fields($req, {
        method => 'GET',
        url => 'http://localhost:1234/foobar.html'
      }, 'trailing: garbage in block');
  }

  # request + trailing whitespace in separate block == just request
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ $req->as_string, "\r\n  \r\n\n" ]);
    is(ref($data), 'ARRAY', 'trailing: extra whitespace packet: ref');
    is(scalar(@$data), 1, 'trailing: extra whitespace packet: one req');
    isa_ok($$data[0], 'HTTP::Request',
      'trailing: extra whitespace packet: HTTP::Request');
    check_fields($req, {
        method => 'GET',
        url => 'http://localhost:1234/foobar.html'
      }, 'trailing: extra whitespace packet');
  }

  # request + trailing whitespace in separate get == just request
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ $req->as_string, "\r\n  \r\n\n" ]);
    is(ref($data), 'ARRAY', 'trailing: extra whitespace get: ref');
    is(scalar(@$data), 1, 'trailing: extra whitespace get: only one response');
    $data = $filter->get([ "\r\n  \r\n\n" ]);
    is(ref($data), 'ARRAY', 'trailing: whitespace by itself: ref');
    is(scalar(@$data), 0, 'trailing: whitespace by itself: no req');
  }

  # request + garbage in separate get == error
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ $req->as_string, "GARBAGE!\r\n\r\n" ]);

    is(ref($data), 'ARRAY', 'trailing: whitespace by itself: ref');
    is(scalar(@$data), 2, 'trailing: whitespace by itself: no req');
    isa_ok($data->[0], 'HTTP::Request');
    isa_ok($data->[1], 'HTTP::Response');
  }
} # }}}

SKIP: { # wishlist for supporting get_pending! {{{
  local $TODO = 'add get_pending support';
  skip $TODO, 1;
  my $filter = POE::Filter::HTTPD->new;
  eval { $filter->get_pending() };
  ok(!$@, 'get_pending supported!');
} # }}}

{ # basic checkout of put {{{
  my $res = HTTP::Response->new("404", "Not found");

  my $filter = POE::Filter::HTTPD->new;

  use Carp;
  $SIG{__DIE__} = \&Carp::croak;
  my $chunks = $filter->put([$res]);
  is(ref($chunks), 'ARRAY', 'put: returns arrayref');
} # }}}

{ # really, really garbage requests get rejected, but goofy ones accepted {{{
  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ "ELEPHANT\n\r\n" ]);
    check_error_response($data, RC_BAD_REQUEST,
      'garbage request line: bad request');
  }

  {
    my $filter = POE::Filter::HTTPD->new;
    my $data = $filter->get([ "GET\t/elephant.gif\n\n" ]);
    isa_ok($$data[0], 'HTTP::Request', 'goofy request accepted');
    check_fields($$data[0], {
        protocol => 'HTTP/0.9',
        method => 'GET',
        uri => '/elephant.gif',
      }, 'goofy request');
  }
} # }}}

{ # unsupported method {{{
  { # bad request -- 0.9 so no length required
    my $filter = POE::Filter::HTTPD->new;
    my $req = HTTP::Request->new('ELEPHANT', '/');
    my $data = $filter->get([ $req->as_string ]);
    check_fields($$data[0], {
        protocol => 'HTTP/0.9',
        method => 'ELEPHANT',
        uri => '/',
      }, 'strange method');
  }
  { # bad request -- 1.1+Content-Encoding implies a body so length required
    my $filter = POE::Filter::HTTPD->new;
    my $req = HTTP::Request->new('ELEPHANT', 'http://localhost/');
    $req->header( 'Content-Encoding' => 'mussa' );
    $req->protocol('HTTP/1.1');
    my $data = $filter->get([ $req->as_string ]);
    check_error_response($data, RC_LENGTH_REQUIRED,
      'body indicated, not included: length required');
    $req = $data->[0]->request;
    ok( $req, "body indicated, not included: got request" );
    check_fields( $req, {
            protocol => 'HTTP/1.1', 
            method   => 'ELEPHANT',
            uri      => 'http://localhost/'
        }, 'body indicated, not included' );
  }
} # }}}

{ # strange method {{{
  my $filter = POE::Filter::HTTPD->new;
  my $req = HTTP::Request->new("GEt", "/");
  my $parsed_req = $filter->get([ $req->as_string ])->[0];
  check_fields(
    $parsed_req, {
      protocol => 'HTTP/0.9',
      method => 'GEt',
      uri => '/',
    },
    "mixed case method"
  );
} # }}}

{ # strange request: GET with a body {{{
  my $filter = POE::Filter::HTTPD->new;
  my $trap = HTTP::Request->new( "POST", "/trap.html" ); # IT'S A TRAP
  $trap->protocol('HTTP/1.1');
  $trap->header( 'Content-Type' => 'text/plain' );
  $trap->header( 'Content-Length' => 10 );
  $trap->content( "HONK HONK\n" );

  my $req = HTTP::Request->new("GET", "/");
  $req->protocol('HTTP/1.1');

  my $body = $trap->as_string;
  $req->header( 'Content-Length' => length $body );
  $req->header( 'Content-Type' => 'text/plain' );
  # include a HTTP::Request as body, to make sure we find only one request,
  # not 2
  $req->content( $body );

  my $data = $filter->get([ $req->as_string ]);
  is( 1, 0+@$data, "GET with body: one request" );
  ok( ($data->[0]->content =~ /POST.+HONK HONK\n/s), 
                                    "GET with body: content" );
  check_fields(
    $data->[0], {
      protocol => 'HTTP/1.1',
      method => 'GET',
      uri => '/',
    },
    "GET with body"
  );


  # Same again with HEAD
  $req->method( 'HEAD' );
  $data = $filter->get([ $req->as_string ]);
  is( 1, 0+@$data, "HEAD with body: one request" );
  ok( ($data->[0]->content =~ /POST.+HONK HONK\n/s), 
                                    "HEAD with body: content" );
  check_fields(
    $data->[0], {
      protocol => 'HTTP/1.1',
      method => 'HEAD',
      uri => '/',
    },
    "HEAD with body"
  );
} # }}}
