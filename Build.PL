use Module::Build;
my $build = Module::Build->new(
                dist_name => 'POE',
                dist_version_from => 'lib/POE.pm',
                license => 'perl',

                requires => {
                    'Carp'  => '0',
                    'Exporter' => '0',
                    'IO' => '0',
                    'POSIX' => '0',
                    'Socket' => '0',
                    'Filter::Util::Call' => '1.04',
                },
            );

$build->create_build_script;
