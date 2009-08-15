#!/usr/bin/perl

# Fetch and test all the /^POE::/ distributions on CPAN.

use strict;

use CPANPLUS::Configure;
use CPANPLUS::Backend;
use Cwd;
use Digest::MD5;

### Local configuration.  Do everything out of the current directory,
### which is usually (always?) the main POE development directory.

my $cwd = cwd;
sub DIR_MAIN     () { $cwd . "/comptest" }
sub DIR_CPANPLUS () { DIR_MAIN . "/cpanplus" }
sub DIR_TARBALLS () { DIR_MAIN . "/tarballs" }
sub DIR_TESTING  () { DIR_CPANPLUS . "/build" }

### Create directories as necessary.

unless (-e DIR_MAIN) {
  mkdir DIR_MAIN, 0777 or die $!;
}

unless (-e DIR_CPANPLUS) {
  mkdir DIR_CPANPLUS, 0777 or die $!;
}

unless (-e DIR_TARBALLS) {
  mkdir DIR_TARBALLS, 0777 or die $!;
}

### Grab CPANPLUS' configuration, and locally redirect its base
### directory to our own location.

my $cc = CPANPLUS::Configure->new();
$cc->set_conf(
  base => DIR_CPANPLUS
);

### Gather a list of POE components that aren't distributed with POE.

print "Searching CPAN for POE distributions...\n";

my $cp = CPANPLUS::Backend->new($cc);
my @search = $cp->search(
  type  => "module",
  allow => [ qr/^POE::/ ],
);

my %package;
foreach my $obj (sort @search) {
  my $package = $obj->package();

  my ($pkg, $ver) = ($package =~ /^(.*?)-([0-9\.\_]+)\.tar\.gz$/);

  # Skip things indigenous to POE.
  unless (defined $pkg) {
    warn "Skipping $package (can't parse package name)...\n";
    next;
  }
  next if $pkg eq "POE";

  $package{$package} = $obj;
}

### Fetch distributions.  This caches them in DIR_TARBALLS, avoiding
### redundant downloads.

print "Fetching distributions...\n";

foreach my $package (sort keys %package) {
  my $existing_file = DIR_TARBALLS . "/$package";
  print "Got ", $package{$package}->fetch( fetchdir => DIR_TARBALLS ), "\n";
}

### Remove unsuccessful downloads.  Also remove older versions of
### updated distributions.

my %ver;
opendir(TB, DIR_TARBALLS) or die $!;
foreach (readdir(TB)) {
  my $full_path = DIR_TARBALLS . "/$_";

  next unless -f $full_path;

  if (/-\d+$/) {
    print "Unlinked stale temporary $full_path\n";
    unlink $full_path;
    next;
  }

  my ($mod, $ver) = (/^(.*?)-([0-9\.\_]+)\.tar\.gz$/);
  die "Can't parse $_ into dist/version" unless defined $mod and defined $ver;
  if (exists $ver{$mod}) {
    push @{$ver{$mod}}, $full_path;
  }
  else {
    $ver{$mod} = [$full_path];
  }
}
closedir TB;

foreach my $mod (sort keys %ver) {
  next unless @{$ver{$mod}} > 1;
  my @files = sort { (-M $a) <=> (-M $b) } @{$ver{$mod}};
  while (@files > 1) {
    my $dead = pop @files;
    print "Unlinking older $dead...\n";
    unlink $dead;
  }
}

### Test them!

# Trap SIGINT and exit gracefully, so the END block below gets a
# chance to run.
$SIG{INT} = sub { exit };

# Add my cvspoe directory to the include path.
if (exists $ENV{PERL5LIB}) {
  $ENV{PERL5LIB} .= ":/home/troc/perl/poe";
}
else {
  $ENV{PERL5LIB} = "/home/troc/perl/poe";
}

opendir(TB, DIR_TARBALLS) or die $!;
my @tarballs = grep { -f } map { DIR_TARBALLS . "/$_" } readdir TB;
close TB;

my %results;

foreach my $tarball (@tarballs) {

  # Temporarily skip some modules that hang during testing.
  if ($tarball =~ /(rrdtool|onjoin|player)/i) {
    warn "Skipping $tarball...\n";
    next;
  }

  warn "Testing $tarball...\n";

  system("/bin/rm -rf " . DIR_TESTING);
  mkdir DIR_TESTING, 0777 or die $!;

  $cp->extract(files => [ $tarball ]);

  my $mod = $tarball;
  $mod =~ s/^.*\///;
  $mod =~ s/\.tar.gz$//;

  my $full_dir = DIR_TESTING . "/$mod";
  warn $full_dir;

  my $local_results = $cp->make(
    target => "test",
    dirs   => [ $full_dir ],
  );

  while (my ($dir, $stat) = each %$local_results) {
    $results{$dir} = $stat;
  }
}

### Print summary of results.

END{
  foreach my $dir (sort keys %results) {
    my $mod = $dir;
    $mod =~ s/^.*\///;

    print( $results{$dir}, " = ", ($results{$dir}) ? "   " : "NOT" );
    print " OK $mod\n";
  }
}
