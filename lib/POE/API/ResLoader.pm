package POE::API::ResLoader;

use POE::Kernel;

sub import {
    my $package = (caller())[0];
    my $self = shift;
    if(@_) {
        my $initializer = shift;
        if(ref $initializer eq 'CODE') {
            $initializer->();
        }
    }
}


1;
