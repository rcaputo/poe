#!/usr/bin/perl -w

use strict;
use File::Spec;
use File::Path;

my $test_base = "tests";

### Resources, and their perl and XS implementations.

{
  my $base_dir = File::Spec->catfile($test_base, "20_resources");
  my $base_lib = File::Spec->catfile($base_dir,  "00_base");

  my %derived_conf = (
    "10_perl" => { implementation => "perl" },
# TODO - Enable when an XS implementation arrives.
#    "20_xs"   => { implementation => "xs"   },
  );

  my $source = (
    "#!/usr/bin/perl -w\n" .
    "# \$Id\$\n" .
    "\n" .
    "use strict;\n" .
    "use lib qw(--base_lib--);\n" .
    "use Test::More;\n" .
    "\n" .
    "\$ENV{POE_IMPLEMENTATION} = '--implementation--';\n" .
    "\n" .
    "require '--base_file--';\n" .
    "\n" .
    "CORE::exit 0;\n"
  );

  derive_files(
    base_dir     => $base_dir,
    base_lib     => $base_lib,
    derived_conf => \%derived_conf,
    src_template => $source,
  );
}

### Event loops and the tests that love them.

{
  my $base_dir = File::Spec->catfile($test_base, "30_loops");
  my $base_lib = File::Spec->catfile($base_dir,  "00_base");

  my %derived_conf = (
    "10_select" => {
      module    => "",
      display    => "",
    },
    "20_poll"   => {
      module    => "IO::Poll",
      display    => "",
      no_sys    => [ "MSWin32" ],
    },
    "30_event"  => {
      module    => "Event",
      display    => "",
    },
    "40_gtk"    => {
      module    => "Gtk",
      display    => 1,
    },
    "50_tk"     => {
      module    => "Tk",
      display    => 1,
    },
  );

  # Expand flags into code.

  foreach my $variables (values %derived_conf) {
    my $module = $variables->{module};

    # If platforms are to be excluded, check for them.

    if (
      $variables->{no_sys} and
      grep /^\Q$^O\E/, @{$variables->{no_sys}}
    ) {
      $variables->{no_sys} = (
        "\n" .
        "BEGIN {\n" .
        "  \$| = 1;\n" .
        "  print qq(1..0 # Skip This test cannot be run on $^O\\n);\n" .
        "  CORE::exit(0);\n" .
        "}\n"
      );
    }
    else {
      $variables->{no_sys} = "";
    }

    # Turn a specified display flag into the code that tests for a
    # DISPLAY environment variable.  DISPLAY is not necessary for
    # ActiveState Perl, at least not for Tk.

    if ($variables->{display}) {
      if ($^O eq "MSWin32") {
        $variables->{display} = "";
      }
      else {
        $variables->{display} = (
          "\n" .
          "BEGIN {\n" .
          "  unless (\$ENV{DISPLAY}) {\n" .
          "    \$| = 1;\n" .
          "    print qq(1..0 # " .
          "Skip $module needs a DISPLAY (set one today, okay?)\\n);\n" .
          "    CORE::exit(0);\n" .
          "  }\n" .
          "}\n"
        );
      }
    }

    # If a module must be loaded, load it.  Skip the tests if it can't
    # be loaded.

    if ($variables->{module}) {
      $variables->{module} = (
        "\n" .
        "BEGIN {\n" .
        "  eval 'use $module';\n" .
        "  if (\$@) {\n" .
        "    \$| = 1;\n" .
        "    print qq(1..0 # Skip $module could not be loaded\\n);\n" .
        "    CORE::exit(0);\n" .
        "  }\n" .
        "}\n"
      );
    }
  }

  my $source = (
    "#!/usr/bin/perl -w\n" .
    "# \$Id\$\n" .
    "\n" .
    "use strict;\n" .
    "--no_sys--" .
    "use lib qw(--base_lib--);\n" .
    "use Test::More;\n" .
    "use POSIX qw(_exit);\n" .
    "--display--" .
    "--module--" .
    "\n" .
    "require '--base_file--';\n" .
    "\n" .
    "_exit 0 if \$^O eq 'MSWin32';\n" .
    "CORE::exit 0;\n"
  );

  derive_files(
    base_dir     => $base_dir,
    base_lib     => File::Spec->catfile($base_dir, "00_base"),
    derived_conf => \%derived_conf,
    src_template => $source,
  );
}

exit 0;

sub derive_files {
  my %conf = @_;

  my $base_dir = $conf{base_dir};

  # Gather the list of base files.  Each will be used to generate a
  # real test file.

  opendir BASE, $conf{base_lib} or die $!;
  my @base_files = grep /\.pm$/, readdir(BASE);
  closedir BASE;

  # Generate a set of test files for each configuration.

  foreach my $dst_dir (keys %{$conf{derived_conf}}) {
    my $full_dst = File::Spec->catfile($base_dir, $dst_dir);
    $full_dst =~ tr[/][/]s;
    $full_dst =~ s{/+$}{};

    my %template_conf = %{$conf{derived_conf}{$dst_dir}};

    # Blow away any previously generated test files.

    rmtree($full_dst);
    mkpath($full_dst, 0, 0755);

    # For each base file, generate a corresponding one in the
    # configured destination directory.  Expand various bits to
    # customize the test.

    foreach my $base_file (@base_files) {
      my $full_file = File::Spec->catfile($full_dst, $base_file);
      $full_file =~ s/\.pm$/.t/;

      # These hardcoded expansions are for the base file to be
      # required, and the base library directory where it'll be found.

      my $expanded_src = $conf{src_template};
      $expanded_src =~ s/--base_file--/$base_file/g;
      $expanded_src =~ s/--base_lib--/$conf{base_lib}/g;

      # The others are plugged in from the directory configuration.

      while (my ($key, $val) = each %template_conf) {
        $expanded_src =~ s/--\Q$key\E--/$val/g;
      }

      # Write with lots of error checking.

      open EXPANDED, ">$full_file" or die $!;
      print EXPANDED $expanded_src;
      close EXPANDED or die $!;
    }
  }
}
