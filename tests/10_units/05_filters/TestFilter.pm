# filter testing utility functions
package TestFilter;

use strict;
use Exporter;
use vars qw(@ISA @EXPORT $COUNT_FILTER_INTERFACE $COUNT_FILTER_STANDARD);
use Test::More;

@ISA = qw/Exporter/;
@EXPORT = qw/
  $COUNT_FILTER_INTERFACE test_filter_interface
  $COUNT_FILTER_STANDARD test_filter_standard
/;

## each of these needs the number of subtests documented
## export this in a variable

# check interface exists
$COUNT_FILTER_INTERFACE = 8;
sub test_filter_interface {
  my $class = ref $_[0] || $_[0];

  ok(UNIVERSAL::isa($class, 'POE::Filter'), '$class isa POE::Filter');
  can_ok($class, 'new');
  can_ok($class, 'get');
  can_ok($class, 'get_one_start');
  can_ok($class, 'get_one');
  can_ok($class, 'put');
  can_ok($class, 'get_pending');
  can_ok($class, 'clone');
}

# given a input, and the expected output run it through the filter in a few ways
$COUNT_FILTER_STANDARD = 7;
sub test_filter_standard {
  my ($filter, $in, $out, $put) = @_;

  { # first using get()
    my $records = $filter->get($in);
    is_deeply($records, $out, "get [standard test]");
  }

  # now clone the filter which will clear the buffer
  {
    my $type = ref($filter);
    $filter = $filter->clone;
    ok(!defined($filter->get_pending()),
      "clone() clears buffer [standard test]");
    is(ref($filter), $type,
      "clone() doesn't change filter type [standard test]");
  }

  { # second using get_one()
    $filter->get_one_start($in);
    {
      my $pending = $filter->get_pending();
      unless (ref($pending) eq 'ARRAY') {
        fail("get_pending() didn't return array");
      } else {
        is(join('', @$pending), join('', @$in),
          "get_one_start() only loads buffer [standard test]");
      }
    }

    my @records;
    my $ret_arrayref = 1;
    GET_ONE: while (my $r = $filter->get_one()) {
      unless (ref($r) eq 'ARRAY') {
        $ret_arrayref = 0;
        last GET_ONE;
      }

      last GET_ONE unless @{$r};
      push @records, @{$r};
    }

    ok($ret_arrayref, "get_one returns arrayref [standard test]");
    is_deeply(\@records, $out, "get_one [standard test]");
  }

  { # third using put()
    my $chunks = $filter->put($out);
    is_deeply($chunks, $put, "put [standard test]");
  }
}

1;
