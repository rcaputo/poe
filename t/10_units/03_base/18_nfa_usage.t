use strict;

package main;

use Test::More;
use POE::NFA;

plan 'no_plan';

my $nfa;

eval {
  POE::NFA->spawn('foo')
};
like($@, qr/odd number/, 'NFA treats its params as a hash');

eval {
  POE::NFA->spawn(inline_states => {initial => { start => sub { 0 } } })
};
like($@, qr/requires a working Kernel/, 'NFA needs a working kernel');

eval "use POE::Kernel";
eval {
  POE::NFA->spawn(crap => 'foo');
};
like($@, qr/constructor requires at least one of/, 'need states');

eval {
  $nfa = POE::NFA->spawn(inline_states => {initial => { start => sub { 0 } } })
};
isa_ok($nfa, 'POE::NFA', 'most basic machine');

eval {
  POE::NFA->spawn(inline_states => {initial => { start => sub { 0 } } }, crap => 'foo')
};
like($@, qr/constructor does not recognize/, 'unknown parameter');

eval {
  POE::NFA->spawn(package_states => {initial => 'foo'});
};
like($@, qr/the data for state/, 'bad state data');

eval {
  POE::NFA->spawn(package_states => {initial => ['Foo']});
};
like($@, qr/the array for state/, 'bad state data');

eval {
  POE::NFA->spawn(package_states => {initial => ['Foo' => 'bar']});
};
like($@, qr/need to be a hash or array ref/, 'bad event data');

eval {
  $nfa = POE::NFA->spawn(package_states => {initial => ['Foo' => [qw(foo bar)]]});
};
isa_ok($nfa, 'POE::NFA', 'spawn with package_states');

eval {
  $nfa = POE::NFA->spawn(package_states => {initial => ['Foo' => [qw(foo bar)]]}, runstate => [ ] );
};
isa_ok($nfa, 'POE::NFA', 'spawn with package_states');
is( ref $nfa->[0], 'ARRAY', 'RUNSTATE is an ARRAYREF' );

POE::Kernel->run;
