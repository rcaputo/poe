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
    eval { require "$p.pm"; import $p (); };
    warn $@ if $@;
    return $p if $@ eq '';
  }
  die "Filter::Reference requires Storable or FreezeThaw";
}

#------------------------------------------------------------------------------
# Try to acquire Compress::Zlib at runtime.

my $zlib_status = undef;
sub _include_zlib {
  local $SIG{'__DIE__'} = 'DEFAULT';

  unless (defined $zlib_status) {
    eval { require 'Compress::Zlib';
           import Compress::Zlib qw(compress uncompress);
         };
    if ($@) {
      $zlib_status = $@;
      eval <<'      EOE';
        sub compress { @_ }
        sub uncompress { @_ }
      EOE
    }
    else {
      $zlib_status = '';
    }
  }

  $zlib_status;
}

#------------------------------------------------------------------------------

sub new {
  my($type, $freezer, $compression) = @_;
  $freezer ||= _default_freezer();
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
                                        # Compression
  $compression ||= 0;
  if ($compression) {
    my $zlib_status = &_include_zlib();
    if ($zlib_status ne '') {
      warn "Compress::Zlib load failed with error: $zlib_status\n";
      carp "Filter::Reference compression option ignored";
      $compression = 0;
    }
  }

  my $self = bless { buffer    => '',
                     expecting => undef,
                     thaw      => $tt,
                     freeze    => $tf,
                     compress  => $compression,
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

    my $chunk = substr($self->{buffer}, 0, $self->{expecting});
    substr($self->{buffer}, 0, $self->{expecting}) = '';
    undef $self->{expecting};

    $chunk = uncompress($chunk) if $self->{compress};
    push @return, $self->{thaw}->( $chunk );
  }

  return \@return;
}

#------------------------------------------------------------------------------
# freeze one or more references, and return a string representing them

sub put {
  my ($self, $references) = @_;

  my @raw = map {
    my $frozen = $self->{freeze}->($_);
    $frozen = compress($frozen) if $self->{compress};
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

POE::Filter::Reference - freeze data for sending; thaw data when it arrives

=head1 SYNOPSIS

  $filter = new POE::Filter::Reference();
  $arrayref_of_perl_references =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_serialized_perl_references =
     $filter->put($arrayref_of_perl_references);

=head1 DESCRIPTION

This filter packages referenced data for writing to a file or socket.
Upon receipt of packaged data, it reconstitutes the original structure
and returns a reference to it.  This provides a handy way to ship data
between processes and systems.

=head1 PUBLIC FILTER METHODS

=over 4

=item new SERIALIZER, COMPRESSION

=item new SERIALIZER

=item new

new() creates and initializes a reference filter.  It accepts two
optional parameters: A serializer and a flag that determines whether
Compress::Zlib will be used to compress serialized data.

Serializers are modelled after Storable.  Storable has a nfreeze()
function which translates referenced data into strings suitable for
shipping across sockets.  It also contains a freeze() method which is
less desirable since it doesn't take network byte ordering into
effect.  Finally there's thaw() which translates frozen strings back
into data.

SERIALIZER may be a package name or an object reference, or it may be
omitted altogether.

If SERIALIZER is a package name, it is assumed that the package will
have a thaw() function as well as etither an nfreeze() or a freeze()
function.

  # Use Storable explicitly, specified by package name.
  my $filter = new POE::Filter::Reference('Storable');

If SERIALIZER is an object reference, it's assumed to have a thaw()
method as well as either an nfreeze() or freeze() method.

  # Use an object.
  my $filter = new POE::Filter::Reference($object);

If SERIALIZER is omitted or undef, the Reference filter will try to
use Storable.  If storable isn't found, it will try FreezeThaw.  And
finally, if FreezeThaw is not found, it will die.

  # Use the default filter (either Storable or FreezeThaw).
  my $filter = new POE::Filter::Reference();

Filter::Reference will try to compress frozen strings and uncompress
them before thawing if COMPRESSION is true.  It uses Compress::Zlib
for this, but it works fine even without Zlib as long as COMPRESSION
is false.

-><-

An object serializer must have a thaw() method.  It also must have
either a freeze() or nfreeze() method.  If it has both freeze() and
nfreeze(), then Filter::Reference will use nfreeze() for portability.
The thaw() method accepts $self and a scalar; it should return a
reference to the reconstituted data.  The freeze() and nfreeze()
methods receive $self and a reference; they should return a scalar
with the reference's serialized representation.

If the serializer parameter is undef, a default one will be used.
This lets programs specify compression without having to worry about
naming a serializer.

For example:

  # Use the default filter (either Storable or FreezeThaw).
  my $filter = new POE::Filter::Reference();

  # Use an object, with compression.
  my $filter = new POE::Filter::Reference($object, 1);

  # Use the default serializer, with compression.
  my $filter = new POE::Filter::Reference(undef, 1);

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

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Whatever is used to freeze and thaw data should be aware of potential
differences in system byte orders.  Also be careful that the same
freeze/thaw code is used on both sides of a socket.  That includes
even the most minor version differences.

=head1 AUTHORS & COPYRIGHTS

The Reference filter was contributed by Arturn Bergman, with changes
by Philip Gwyn.

Please see L<POE> for more information about authors and contributors.

=cut
