# 2001/01/25 shizukesa@pobox.com

package POE::Filter::Stackable;

use strict;
use Carp qw(croak);

sub FILTERS () { 0 }

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type must be given an even number of parameters" if @_ & 1;
  my %params = @_;

  my $self = bless [], $type;

  $self->[FILTERS] = $params{Filters};

  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $data) = @_;
  foreach my $filter (@{$self->[FILTERS]}) {
    $data = $filter->get($data);
    last unless @$data;
  }
  $data;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $data) = @_;
  foreach my $filter (reverse @{$self->[FILTERS]}) {
    $data = $filter->put($data);
    last unless @$data;
  }
  $data;
}

#------------------------------------------------------------------------------

sub get_pending {
  my ($self) = @_;
  my $data;
  for (@{$self->[FILTERS]}) {
    $_->put($data) if $data && @{$data};
    $data = $_->get_pending;
  }
  $data || [];
}

#------------------------------------------------------------------------------

sub filter_types {
   map { ((ref $_) =~ /::(\w+)$/)[0] } @{$_[0]->[FILTERS]};
}

#------------------------------------------------------------------------------

sub filters {
  @{$_[0]->[FILTERS]};
}

#------------------------------------------------------------------------------

sub shift {
  my ($self) = @_;
  my $filter = shift @{$self->[FILTERS]};
  $self->[FILTERS]->[0]->put($filter->get_pending || []);
  $filter;
}

#------------------------------------------------------------------------------

sub unshift {
  my ($self, @filters) = @_;
  unshift(@{$self->[FILTERS]}, @filters);
}

#------------------------------------------------------------------------------

sub push {
  my ($self, @filters) = @_;
  push(@{$self->[FILTERS]}, @filters);
}

#------------------------------------------------------------------------------

sub pop {
  my ($self) = @_;
  my $filter = pop @{$self->[FILTERS]};
  $self->[FILTERS]->[-1]->put($filter->get_pending || []);
  $filter;
}

###############################################################################

1;

__END__

=head1 NAME

POE::Filter::Stackable - POE Multiple Filter Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Stackable(Filters => [ $filter1, $filter2 ]);
  $filter = new POE::Filter::Stackable;
  $filter->push($filter1, $filter2);
  $filter2 = $filter->pop;
  $filter1 = $filter->shift;
  $filter->unshift($filter1, $filter2);
  $arrayref_for_driver = $filter->put($arrayref_of_data);
  $arrayref_for_driver = $filter->put($single_data_element);
  $arrayref_of_data = $filter->get($arrayref_of_raw_data);
  $arrayref_of_leftovers = $filter->get_pending;
  @filter_type_names = $filter->filter_types;
  @filter_objects = $filter->filters;

=head1 DESCRIPTION

The Stackable filter allows the use of multiple filters within a
single wheel.  Internally, filters are stored in an array, with array
index 0 being "near" to the wheel's handle and therefore being the
first filter passed through using "get" and the last filter passed
through in "put".  All POE::Filter public methods are implemented as
though data were being passed through a single filter; other program
components do not need to know there are multiple filters.

=head1 PUBLIC FILTER METHODS

=over 4

=item *

POE::Filter::Stackable::new( ... )

The new() method creates the Stackable filter.  It accepts an optional
parameter "Filters" that specifies an arrayref of initial filters.  If
no filters are given, Stackable will pass data through unchanged; this
is true if there are no filters present at any time.

=item *

POE::Filter::Stackable::pop()
POE::Filter::Stackable::shift()
POE::Filter::Stackable::push($filter1, $filter2, ...)
POE::Filter::Stackable::unshift($filter1, $filter2...)

These methods all function identically to the perl builtin functions
of the same name.  push() and unshift() will return the new number of
filters inside the Stackable filter.

=item *

POE::Filter::Stackable::filter_types

The filter_types() method returns a list of types for the filters
inside the Stackable filter, in order from near to far; for example,
qw(Block HTTPD).

=item *

POE::Filter::Stackable::filters

The filters() method returns a list of the objects inside the
Stackable filter, in order from near to far.

=item *

See POE::Filter.

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Reference;
POE::Filter::Line; POE::Filter::Block; POE::Filter::Stream

=head1 BUGS

Undoubtedly.  None currently known.

=head1 AUTHORS & COPYRIGHTS

The Stackable filter was contributed by Dieter Pearcey.  Rocco Caputo
is sure to have had his hands in it.

Please see the POE manpage for more information about authors and
contributors.

=cut

