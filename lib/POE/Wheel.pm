# $Id$
# Documentation exists after __END__

package Driver;

my $VERSION = 1.0;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  croak "$type is not meant to be used directly";
}

#------------------------------------------------------------------------------
1;
__END__

=head1 NAME

POE::Wheel - extend C<POE::Session> by adding new states

=head1 SYNOPSIS

  $wheel = new POE::Wheel::Derivative
    ( $kernel,
      'name1' => $value1, # These parameters depend on the type of wheel
      'name2' => $value2, # being created.  See each wheel's documentation
      'nameN' => $valueN, # for more information.
    );

=head1 DESCRIPTION

When created, C<POE::Wheel> derivatives splice their own states into the
parent C<POE::Session> state machine.  When destroyed, they remove their states
from the machine.

=head1 PUBLIC METHODS

=over 4

=item new POE::Wheel::Derivative

C<$wheel = new POE::Wheel::Derivative($kernel, 'name' => 'value', ...)>

The name/value pairs are specific to each class derived from C<POE::Wheel>.

=item Others

C<POE::Wheel> derivatives may have their own public methods.

C<POE::Wheel> derivatives send information to their parent C<POE::Session>s by
posting events.

=back

=head1 EXAMPLES

Please see tests/selects.perl for an example of C<POE::Wheel::ListenAccept>
and C<POE::Wheel::ReadWrite>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
