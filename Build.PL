# Accomodate with CPAN autoinstall.  See
# http://www.mail-archive.com/module-authors@perl.org/msg00162.html
shift @ARGV if $ARGV[0] eq 'Build';
use Module::Build;
my $build = Module::Build->new(
                dist_name => 'POE',
                dist_version_from => 'lib/POE.pm',
                license => 'perl',

                requires => {
                    'Filter::Util::Call' => 1.04,
                    'Test::More'         => 0,
                },
            );

$build->create_build_script;
