package POE::Resources;

sub initialize {
    my $package = (caller())[0];
    eval qq|
    package $package;
    use POE::Resource::Extrefs;     # Extra reference counts.
    use POE::Resource::SIDs;        # Session IDs.
    use POE::Resource::Signals;     # Signals.
    use POE::Resource::Aliases;     # Aliases.
    use POE::Resource::FileHandles; # File handles.
    use POE::Resource::Events;      # Events.
    use POE::Resource::Sessions;    # Sessions.
    |;
    die if $@;
}

1;
