#!/usr/bin/perl
# rocco // vim: ts=2 sw=2 expandtab

# Note to Dist::Zilla fans - This is NOT a standard Makefile.PL by ANY
# stretch of the imagination.  If you want to port it to Dist::Zilla,
# you'll have a number of challenges ahead of you:
#
# - Custom Makefile.PL code.
#
# - Dynamic dependencies varying by $^O (see mylib/PoeBuildInfo.pm)
# and by $] (see IPv6 dependencies below).
#
# - Dynamically generated tests.  See PREOP in WriteMakefile(), below.
#
# - Custom Makefile target "coverage".  See MY::postamble, below.
#
# I have tried using Dist::Zilla::Plugin::Makemaker::Awesome, but the
# need to break encapsulation in order to make it work turned me away.
#
# People who love Dist::Zilla are welcome to replace this perfectly
# fine Makefile.PL, but you should be aware of some requirements
# before I'll accept the change:
#
# - Reproduce or improve upon all current Makefile.PL features.  It's
# all there for one reason or another.  The reasons are still largely
# pertinent.  When in doubt, ask.
#
# - Limit your changes to replacing Makefile.PL and $VERSION.  I'd
# rather be able to rely on error message line numbers than to add
# more moving parts to my build and test workflows.

use strict;
use ExtUtils::MakeMaker;
use Config;
use File::Spec;

# Switch to default behavior if STDIN isn't a tty.

unless (-t STDIN) {
  warn(
    "\n",
    "=============================================\n\n",
    "STDIN is not a terminal.  Assuming --default.\n\n",
    "=============================================\n\n",
  );
  push @ARGV, "--default";
}

# Remind the user she can use --default.

unless (grep /^--default$/, @ARGV) {
  warn(
    "\n",
    "=============================================\n\n",
    "Prompts may be bypassed by running:\n",
    "   $^X $0 --default\n\n",
    "=============================================\n\n",
  );
}

# Should we skip the network tests?

my $prompt = (
  "Some of POE's tests require a functional network.\n" .
  "You can skip these tests if you'd like.\n\n" .
  "Would you like to skip the network tests?"
);

my $ret = "n";
if (grep /^--default$/, @ARGV) {
  print $prompt, " [$ret] $ret\n\n";
}
else {
  $ret = prompt($prompt, "n");
}

my $marker = 'run_network_tests';
unlink $marker;
unless ($ret =~ /^Y$/i) {
  open(TOUCH,"+>$marker") and close TOUCH;
}

print "\n";

sub CONFIG_REQUIREMENTS () {
  (
    "POE::Test::Loops"  => '1.360',
  );
}

sub CORE_REQUIREMENTS () {
  my @core_requirements = (
    "Carp"              => 0,
    "Errno"             => 1.09,
    "Exporter"          => 0,
    "File::Spec"        => 0.87,
    "IO"                => 1.24,  # MSWin32 blocking(0)
    "IO::Handle"        => 1.27,
    "IO::Pipely"        => 0.005,
    "POSIX"             => 1.02,
    "Socket"            => 1.7,
    "Storable"          => 2.16,
    "Test::Harness"     => 2.26,
    "Time::HiRes"       => 1.59,
    CONFIG_REQUIREMENTS,
  );

  if (-f 'META.yml') { # only include dynamic deps when installing
    if ($^O eq "MSWin32") {
      push @core_requirements, (
        "Win32::Console" => 0.031,
        "Win32API::File" => 0.05,
        "Win32::Job"     => 0.03,
        "Win32::Process" => 0,
        "Win32"          => 0,
      );
    }
    elsif ($^O eq 'cygwin') {
      # Skip IO::Tty.  It has trouble building as of this writing.
    }
    else {
      push @core_requirements, (
        "IO::Tty"        => 1.08, # avoids crashes on fbsd
      );
    }
  }

  return @core_requirements;
}

sub DIST_AUTHOR () {
  ( 'Rocco Caputo <rcaputo@cpan.org>' )
}

sub DIST_ABSTRACT () {
  ( 'Portable, event-loop agnostic eventy networking and multitasking.' )
}

sub CLEAN_FILES () {
  my @clean_files = qw(
    */*/*/*/*~
    */*/*/*~
    */*/*/*~
    */*/*~
    */*~
    *~
    META.yml
    Makefile.old
    bingos-followtail
    coverage.report
    poe_report.xml
    run_network_tests
    t/20_resources/10_perl
    t/20_resources/10_perl/*
    t/20_resources/20_xs
    t/20_resources/20_xs/*
    t/30_loops
    t/30_loops/*
    t/30_loops/*/*
    test-output.err
  );
  "@clean_files";
}

sub TEST_FILES () {
  my @test_files = qw(
    t/*.t
    t/*/*.t
    t/*/*/*.t
  );
  "@test_files";
}

sub REPOSITORY () {
  'https://github.com/rcaputo/poe'
}

sub HOMEPAGE () {
  'http://poe.perl.org/'
}

### Touch files that will be generated at "make dist" time.
### ExtUtils::MakeMaker will complain about them if
### they aren't present now.

open(TOUCH, ">>CHANGES") and close TOUCH;

### Touch gen-tests.perl so it always triggers.

utime(time(), time(), "mylib/gen-tests.perl");

### Some advisory dependency testing.

sub check_for_modules {
  my ($dep_type, @modules) = @_;

  my @failures;
  while (@modules) {
    my $module  = shift @modules;
    my $target  = shift @modules;

    my $version = eval "use $module (); return \$$module\::VERSION";

    if ($@) {
      push(
        @failures,
        "***   $module $target could not be loaded.\n"
      );
    }
    elsif ($version < $target) {
      push(
        @failures,
        "***   $module $target is $dep_type, " .
        "but version $version is installed.\n"
      );
    }
  }

  if (@failures) {
    warn(
      "*** Some $dep_type features may not be available:\n",
      @failures,
    );
  }
}

check_for_modules("required", CORE_REQUIREMENTS);
check_for_modules(
  "optional",
  "Compress::Zlib"        => 1.33,
  "Curses"                => 1.08,
  "IO::Poll"              => 0.01,
  "IO::Pty"               => 1.02,
  "LWP"                   => 5.79,
  "Term::Cap"             => 1.10,
  "Term::ReadKey"         => 2.21,
  "URI"                   => 1.30,
);

# check for optional IPv6 stuff
{
  # under perl-5.6.2 the warning "leaks" from the eval, while newer versions don't...
  # it's due to Exporter.pm behaving differently, so we have to shut it up
  no warnings 'redefine';
  require Carp;
  local *Carp::carp = sub { die @_ };

  # On perl-5.14.0 Socket.pm provides getaddrinfo
  # otherwise we need to use Socket::GetAddrInfo
  eval { require Socket; Socket->import("getaddrinfo") };
  if ($@) {
    check_for_modules( "optional",
      "Socket::GetAddrInfo" => "0.20",
    );
  }

  # On perl-5.14.0 Socket.pm provides the needed IPv6 constants
  # otherwise we need to use Socket6
  eval { Socket->import( qw(AF_INET6 PF_INET6) ) };
  if ($@) {
    check_for_modules( "optional",
      "Socket6" => "0.23",
    );
  }
}

### Generate Makefile.PL.

sub MY::postamble {
  my $cov = File::Spec->catfile(mylib => 'coverage.perl');
  return <<EOF;

coverage: Makefile
\cI$^X $cov

cover: coverage
EOF
}

WriteMakefile(
  NAME               => 'POE',
  AUTHOR             => DIST_AUTHOR,
  ABSTRACT           => DIST_ABSTRACT,
  LICENSE            => 'perl',

  CONFIGURE_REQUIRES => { CONFIG_REQUIREMENTS },
  BUILD_REQUIRES     => { CONFIG_REQUIREMENTS },

  VERSION_FROM       => 'lib/POE.pm',
  dist               => {
    COMPRESS => 'gzip -9f',
    SUFFIX   => 'gz',
    PREOP    => (
      'git-log.pl | ' .
      '/usr/bin/tee ./$(DISTNAME)-$(VERSION)/CHANGES > ./CHANGES; '
    ),
  },

  clean          => { FILES => CLEAN_FILES  },
  test           => { TESTS => TEST_FILES  },

  # Not executed on "make test".
  PL_FILES       => { File::Spec->catfile(mylib => 'gen-tests.perl') => [ 'lib/POE.pm' ] },

  PREREQ_PM      => { CORE_REQUIREMENTS },

  META_MERGE => {
    no_index => {
      directory => [ 'mylib' ],
    },
    resources => {
      homepage   => HOMEPAGE,
      license    => 'http://dev.perl.org/licenses/',
      repository => REPOSITORY,
    },
  },

  # TODO - ExtUtils::MakeMaker doesn't generate 'provides'.
  # Module::Build did, but we're not using it anymore.
);

1;
