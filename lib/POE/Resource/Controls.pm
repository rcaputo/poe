# $Id$

package POE::Resource::Controls;

use vars qw($VERSION);
$VERSION = do {my($r)=(q$Revision$=~/(\d+)/);sprintf"1.%04d",$r};

# We fold all this stuff back into POE::Kernel
package POE::Kernel;

use strict;
use Sys::Hostname qw( hostname );
use Carp qw(croak);

# %kr_magic = (
#   'foo'           => 'value',
#   'bar.baz'       => 'value',
#   'bar.bat'       => 'value',
#   'bat.boo.buz'   => 'value',
# );

my %kr_magic;
my %kr_magic_locks;



# Populate the data store with a few  locked variables
sub _data_magic_initialize {
    my $self = shift;

    $kr_magic{'kernel.id'} = $self->ID;
    $kr_magic{'kernel.hostname'} = hostname();

    $self->_data_magic_lock('kernel.id');
    $self->_data_magic_lock('kernel.hostname');

}


# Tear down everything.
sub _data_magic_finalize {
    my $self = shift;

    %kr_magic = ();
    %kr_magic_locks = ();

    return 1;  # finalize OK
}


# Set the value of a magic entry. On success, returns
# the stored value of the entry. On failure, returns
# undef. If the entry is locked, no write is performed
# and the pre-set-request value remains.
sub _data_magic_set {
    my $self = shift;

    croak "_data_magic_set needs two parameters" unless @_ == 2;

    unless(defined $kr_magic_locks{ $_[0] }) {
        $kr_magic{ $_[0] } = $_[1];
    }

    return $kr_magic{ $_[0] };

}

# Get the value of a magic entry. If the entry
# is defined, return its value. Otherwise, return
# undef
sub _data_magic_get {
    my $self = shift;

    if(@_ == 1) {

        # TODO - Why the defined check?

        if(defined $kr_magic{ $_[0] }) {
            return $kr_magic{ $_[0] };
        }
        return;

    } else {
        my %magic_copy = %kr_magic;
        return \%magic_copy;
    }

    die "this condition is impossible";
}


# Lock a magic entry and prevent it from
# being written to.
sub _data_magic_lock {
    my $self = shift;

    my $pack = (caller())[0];

    # A kind of cheesy but functional level of protection.
    # If you're in the POE namespace, you probably know enough
    # to muck with magic locks.
    return unless $pack =~ /^POE::/;

    croak "_data_magic_lock needs one parameter" unless @_ == 1;

    $kr_magic_locks{ $_[0] } = 1;

    return 1;
}


# Clear the lock on a magic entry and allow
# it to be written to.
sub _data_magic_unlock {
    my $self = shift;

    my $pack = (caller())[0];

    # A kind of cheesy but functional level of protection.
    # If you're in the POE namespace, you probably know enough
    # to muck with magic locks.
    return unless $pack =~ /^POE::/;

    croak "_data_magic_unlock needs one parameter" unless @_ == 1;

    delete $kr_magic_locks{ $_[0] };

    return 1;
}

1;

__END__

=head1 NAME

POE::Resource::Controls -- Switches and Knobs for POE Internals

=head1 SYNOPSIS

    my $new_value = $k->_data_magic_set('kernel.pie' => 'tasty');
    my $value = $k->_data_magic_get('kernel.pie');
    my $ctls = $k->_data_magic_get();
    $k->_data_magic_lock('kernel.pie');
    $k->_data_magic_unlock('kernel.pie');

=head1 DESCRIPTION

=head2 _data_magic_set

    my $new_value = $k->_data_magic_set('kernel.pie' => 'tasty');

Set a control entry. Returns new value of control entry. If entry value
did not change, this entry is locked from writing.

=head2 _data_magic_get

    my $value = $k->_data_magic_get('kernel.pie');

Get the value of a control entry. If no entry name is provided, returns
a hash reference containing a copy of all control entries.

=head2 _data_magic_lock

    $k->_data_magic_lock('kernel.pie');

Lock a control entry from write. This call can only be made from
within a POE namespace.

=head2 _data_magic_unlock

    $k->_data_magic_unlock('kernel.pie');

Unlock a control entry. This allows the entry to be written to again.
This call can only be made from within a POE namespace.

=head1 SEE ALSO

See L<POE::Kernel> and L<POE::API::Ctl>.

=head1 AUTHORS & COPYRIGHTS

Original Author: Matt Cashner (sungo@pobox.com)

Please see L<POE> for more information about authors and contributors.

=cut

