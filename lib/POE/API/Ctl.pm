#$Id$

package POE::API::Ctl;

use strict;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

use POE::Kernel;
use POE::Resource::Controls;

use Carp qw( carp );

sub import {
    my $package = caller();

    no strict 'refs';
    *{ $package . '::poectl' } = \&poectl;
}


sub poectl {
    if(scalar @_ == 2) {
        return $poe_kernel->_data_magic_set($_[0] => $_[1]);
    } elsif(scalar @_ == 1) {
        return $poe_kernel->_data_magic_get($_[0]);
    } elsif(scalar @_ == 0) {
        return $poe_kernel->_data_magic_get();
    } else {
        carp "Unexpected number of arguments (".scalar @_.") to poectl()";
        return;
    }
}


1;
__END__

=head1 NAME

POE::API::Ctl -- Switches and Knobs for POE Internals

=head1 SYNOPSIS

    use POE::API::Ctl;

    my $value = poectl('kernel.id');

    my $new_value = poectl('some.name' => 'pie');

    my $ctls = poectl();

=head1 DESCRIPTION

This module provides C<sysctl> like functionality for POE. It exports
into the calling namespace a function named C<poectl>.

=head1 FUNCTIONS

=head2 poectl

    my $value = poectl('kernel.id');
    my $new_value = poectl('some.name' => 'pie');
    my $ctls = poectl();

This function is exported into the calling namespace on module load. It
provides the ability to get and set POE control values. All parameters
are optional. If no parameters are given, a hash reference containing a
copy of all POE control entries is returned. If one parameter is given,
the value of that POE control entry is returned. If two parameters are
given, the value of the POE control entry referenced by the first
parameter is set to the contents of the second parameter. In this case,
the new value of the POE control entry is returned. If more than two
parameters are given, an error is thrown and undef is returned.

Control entries can be locked by the POE internals. If a write is
attempted to a locked entry, the write will not succeed and the old
value will remain.

=head1 SEE ALSO

See L<POE::Kernel> and L<POE::Resource::Controls>.

=head1 AUTHORS & COPYRIGHTS

Original Author: Matt Cashner (sungo@pobox.com)

Please see L<POE> for more information about authors and contributors.

=cut

# rocco // vim: ts=2 sw=2 expandtab
# TODO - Redocument.
