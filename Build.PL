use Module::Build;
my $build = Module::Build->new(
                dist_name => 'POE',
                dist_version_from => 'POE.pm',
                license => 'perl',

                requires => {
                    'Filter::Util::Call' => 1.04,
                    'Test::More'         => 0,
                },
            );

$build->create_build_script;
