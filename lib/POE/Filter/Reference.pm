# $Id$

# Filter::Reference partial copyright 1998 Artur Bergman
# <artur@vogon-solutions.com>.  Partial copyright 1999 Philip Gwyn.

package POE::Filter::Reference;

use strict;
use Carp;

#------------------------------------------------------------------------------
# Try to require one of the default freeze/thaw packages.

sub _default_freezer {
  local $SIG{'__DIE__'} = 'DEFAULT';
  my $ret;

  foreach my $p (qw(Storable FreezeThaw)) {
    eval { require "$p.pm"; import $p ();};
    warn $@ if $@;
    return $p if $@ eq '';
  }
  die "Filter::Reference requires Storable or FreezeThaw";
}

#------------------------------------------------------------------------------

sub new {
  my($type, $freezer) = @_;
  $freezer||=_default_freezer();
                                        # not a reference... maybe a package?
    unless(ref $freezer) {
      unless(exists $::{$freezer.'::'}) {
        eval {require "$freezer.pm"; import $freezer ();};
        croak $@ if $@;
      }
    }

  # Now get the methodes we want
  my $freeze=$freezer->can('nfreeze') || $freezer->can('freeze');
  carp "$freezer doesn't have a freeze or nfreeze method" unless $freeze;
  my $thaw=$freezer->can('thaw');
  carp "$freezer doesn't have a thaw method" unless $thaw;


  # If it's an object, we use closures to create a $self->method()
  my $tf=$freeze;
  my $tt=$thaw;
  if(ref $freezer) {
    $tf=sub {$freeze->($freezer, @_)};
    $tt=sub {$thaw->($freezer, @_)};
  }
  my $self = bless { buffer    => '',
                     expecting => undef,
                     thaw      => $tt,
                     freeze    => $tf,
                   }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my @return;

  $self->{buffer} .= join('', @$stream);

  while ( defined($self->{expecting}) ||
          ( ($self->{buffer} =~ s/^(\d+)\0//s) &&
            ($self->{expecting} = $1)
          )
  ) {
    last if (length $self->{buffer} < $self->{expecting});
    push( @return,
          $self->{thaw}->(substr( $self->{buffer}, 0, $self->{expecting}))
        );
    substr($self->{buffer}, 0, $self->{expecting}) = '';
    undef $self->{expecting};
  }

  return \@return;
}

#------------------------------------------------------------------------------
# freeze one or more references, and return a string representing them

sub put {
  my ($self, $references) = @_;

  my @raw = map {
    my $frozen = $self->{freeze}->($_);
    length($frozen) . "\0" . $frozen;
  } @$references;
  \@raw;
}

#------------------------------------------------------------------------------
# We are about to be destroyed!  Hand all we have left over to our Wheel

sub get_pending {
  my($self)=@_;
  return unless $self->{'framing buffer'};
  my $ret=[$self->{'framing buffer'}];
  $self->{'framing buffer'}='';
  return $ret;
}

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Reference - POE Freeze/Thaw Protocol Abstraction

=head1 SYNOPSIS

  $filter = new POE::Filter::Something();
  $arrayref_of_perl_references =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_serialized_perl_references =
     $filter->put($arrayref_of_perl_references);

=head1 DESCRIPTION

The "put" half of this filter freezes referenced Perl structures into
serialized versions for sending.  The "get" half of this filter thaws
serialized Perl structures back into references.  This provides a
handy way to ship data between processes and systems.

Serializers should recognize that POE::Filter::Reference is used to
ship data between systems with different byte orders.

=head1 PUBLIC FILTER METHODS

=over 4

=item *

POE::Filter::Reference::new( ... )

The new() method creates and initializes the reference filter.  It
accepts an optional parameter to specify a serializer.  The serializer
may be a package or an object.

A package serializer must have a thaw() function, and it must have
either a freeze() or nfreeze() function.  If it has both freeze() and
nfreeze(), then Filter::Reference will use nfreeze() for portability.
These functions match Storable and FreezeThaw's call signatures.

An object serializer must have a thaw() method.  It also must have
either a freeze() or nfreeze() method.  If it has both freeze() and
nfreeze(), then Filter::Reference will use nfreeze() for portability.
The thaw() method accepts $self and a scalar; it should return a
reference to the reconstituted data.  The freeze() and nfreeze()
methods receive $self and a reference; they should return a scalar
with the reference's serialized representation.

For example:

  # Use the default filter (either Storable or FreezeThaw).
  my $filter1 = new POE::Filter::Reference();

  # Use Storable explicitly, specified by package name.
  my $filter = new POE::Filter::Reference('Storable');

  # Use an object.
  my $filter = new POE::Filter::Reference($object);


The new() method will try to require any packages it needs.

The default behavior is to try Storable first, FreezeThaw second, and
fail if neither is present.  This is rapidly becoming moot because of
the PM_PREREQ entry in Makefile.PL, which makes CPAN and ``make'' carp
about requirements even when they aren't required.

=item *

POE::Filter::Reference::get($frozen_data)

The get() method thaws streamed, frozen data into references.
References will be blessed, if necessary.  If the reference points to
an object, be sure the receiving end has use'd it before calling its
methods.

=item *

POE::Filter::Reference::put($reference)

The put() method freezes references and returns their serialized,
streamable representations.

=back

=head1 SEE ALSO

POE::Filter; POE::Filter::HTTPD; POE::Filter::Line;
POE::Filter::Stream

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

The Reference filter was contributed by Arturn Bergman, with changes
by Philip Gwyn.

Please see the POE manpage for more information about authors and
contributors.

=cut
