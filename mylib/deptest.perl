#!/usr/bin/perl -w
# $Id$

# Scan a distribution's source tree and test its dependencies.  Exit
# with a failure code if the distribution can't build.

use strict;
use File::Find;
use Config qw(%Config);
use Text::Wrap;

use File::Spec;
use ExtUtils::Manifest qw(maniread);

sub TRACE_GOOD     () { 0 }  # (noise) show good modules
sub TRACE_VERBOSE  () { 0 }  # (noise) show extra geeky bits
sub TRACE_SECTIONS () { 1 }  # (signal or noise) section headers
sub TRACE_BAD      () { 1 }  # (signal) show bad modules
sub SHOW_SUMMARY   () { 1 }  # (signal) show report at the end

# Twice to avoid warnings.
open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";
open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";

#------------------------------------------------------------------------------
# Read dependency hints from NEEDS.  By default, and for backward
# compatibility, every rule is core and every dependent is needed.

TRACE_SECTIONS and print STDERR "Gathering dependency hints from NEEDS.\n";

sub FT_CORE       () { 0x0001 } # this file is an internal/external core
sub FT_EXTENSION  () { 0x0002 } # this file is an internal/external extension
sub FT_DATA       () { 0x0004 } # this file is a test program
sub FT_INTERNAL   () { 0x0018 } # this file belongs to this project
sub FT_EXTERNAL   () { 0x0020 } # this file belongs to something else
sub DT_WANTS      () { 0x0030 } # soft dependency
sub DT_NEEDS      () { 0x0080 } # hard dependency
sub FT_IMPAIRED   () { 0x0100 } # file impaired by missing DT_WANTS dependent
sub FT_BROKEN     () { 0x0200 } # file broken by missing DT_NEEDS dependent
sub FT_TROUBLED   () { 0x0400 } # file has miscellaneous trouble

sub RULE_USER_MASK () { 0 }
sub RULE_TYPE      () { 1 }
sub RULE_DEP_MASK  () { 2 }

my %module_type =
  ( core      => FT_CORE,
    extension => FT_EXTENSION,
    data      => FT_DATA
  );
my %dependency_type = ( wants => DT_WANTS, needs     => DT_NEEDS     );

my @mod_rules =
  ( [ '.*',                     # RULE_USER_MASK
      $module_type{core},       # RULE_TYPE
    ],
  );

my @dep_rules =
  ( [ '.*',                     # RULE_USER_MASK
      $dependency_type{needs},  # RULE_TYPE
      '.*',                     # RULE_DEP_MASK
    ],
  );

# Translate a simple * mask into a regexp.
sub mask_to_regexp {
  my $mask = quotemeta(shift);
  $mask =~ s/\\\*/.*/g;
  return $mask;
}

if (open(NEEDS, "<NEEDS")) {
  while (<NEEDS>) {
    chomp;
    next if /^\s*$/;
    next if /^\s*\#/;

    if (/^\s*(\S+)\s+is\s+(core|extension|data)\s*(?:\#.*)?$/) {
      my ($mask, $type) = ($1, $2);
      push( @mod_rules,
            [ &mask_to_regexp($mask),  # RULE_USER_MASK
              $module_type{$type},     # RULE_USER_TYPE
            ]
          );
    }
    elsif (/^\s*(\S+)\s+(wants|needs|prefers)\s+(\S+)\s*(?:\#.*)?$/) {
      my ($user_mask, $dep_type, $usee_mask) = ($1, $2, $3);
      push( @dep_rules,
            [ &mask_to_regexp($user_mask),  # RULE_USER_MASK
              $dependency_type{$dep_type},  # RULE_DEP_TYPE
              &mask_to_regexp($usee_mask),  # RULE_DEP_MASK
            ]
          );
    }

    else {
      die "bad rule at NEEDS line $.\n";
    }
  }
  close NEEDS;
}

# Determine core/extension for distribution modules.
sub file_type {
  my $file = shift;
  my $file_type;
  foreach my $mod_rule (@mod_rules) {
    my $mod_regexp = $mod_rule->[RULE_USER_MASK];
    next unless $file =~ /^$mod_regexp$/;
    $file_type = $mod_rule->[RULE_TYPE];
  }
  return $file_type;
}

# Determine a dependency type.
sub dep_type {
  my ($user, $usee) = @_;
  my $dep_type;
  foreach my $dep_rule (@dep_rules) {
    my $user_regexp = $dep_rule->[RULE_USER_MASK];
    next unless $user =~ /^$user_regexp$/;
    my $usee_regexp = $dep_rule->[RULE_DEP_MASK];
    next unless $usee =~ /^$usee_regexp$/;
    $dep_type = $dep_rule->[RULE_TYPE];
  }
  return $dep_type;
}

#------------------------------------------------------------------------------
# Scan the MANIFEST for dependencies.

sub FS_CORE_BROKEN () { 0 }
sub FS_EXT_BROKEN  () { 1 }
sub FS_IMPAIRED    () { 2 }
sub FS_TROUBLED    () { 3 }
my @file_status;

my $test_package = 0;
my $is_core_regexp = '^' . quotemeta($Config{installprivlib});
my $is_site_regexp = '^' . quotemeta($Config{installsitelib});
my $distribution_can_install = 1;
my %file_status;

TRACE_SECTIONS and
  print STDERR "Scanning files from MANIFEST for obvious dependencies.\n";

my $manifest = maniread();
die "can't read MANIFEST: $!\n" unless defined $manifest;

foreach my $filename (sort keys %$manifest) {

  # Transform MANIFEST entries into module names, if they can be.
  my $file_key = $filename;
  if ($file_key =~ s!\.pm$!!) {
    $file_key = join '::', File::Spec->splitdir( $file_key );
  }

  my $file_type = &file_type($file_key);
  my $file_type_name = 'unknown';
  if ($file_type & FT_CORE) {
    $file_type_name = 'core';
  }
  elsif ($file_type & FT_EXTENSION) {
    $file_type_name = 'extension';
  }

  # Skip data files.
  next if $file_type & FT_DATA;

  my @file_messages = ( "$file_type_name $file_key" );
  TRACE_VERBOSE and $file_messages[-1] .= " (was: $filename)";

  open( FILE, "<$filename" ) or die "can't read $filename: $!\n";

  my $file = '';
  while (<FILE>) {
    chomp;
    s/(?<!\\)\s*\#.*$//; # May Turing have mercy upon me.
    next if /^\s*$/;     # Skip blank lines.
    last if /^__END__/;  # Skip DATA division.

    $file .= " $_ ";
  }
  close FILE;

  # Canonicalize whitespace.
  $file =~ s/\s+/ /g;

  # Hunt down dependents.
  my %dependent;
  while ($file =~ / (?<!\w\s)
                    \b (use|require) \s+ (\S+)
                    (?: \s* (?:qw\(|['"]) \s* (.+?) \s* [\)'"] )?
                  /gx
        )
  {
    my ($cmd, $dependent, $extra) = ($1, $2, $3);

    # Remove funny leading and trailing characters.
    $dependent =~ s/\W+$//;
    $dependent =~ s/^\W+//;

    # If it's a "use lib", then use it here to expand our search path.
    if ($cmd eq 'use' and $dependent eq 'lib') {
      if ($extra =~ /\s/) {
        eval "use lib qw($extra)";
      }
      else {
        eval "use lib '$extra'";
      }
      next;
    }

    # Skip other all-lowercase modules.
    next if $dependent !~ /[A-Z]/;

    # Skip modules with illegal characters.
    next if $dependent =~ /[^A-Za-z\:\-\_]/;

    # Explode extra parameters if the reference is to POE itself.
    my @modules = ($dependent);
    push @modules, map { "POE::" . $_ } split /\s+/, $extra
      if $dependent eq 'POE' and defined $extra;

    foreach my $dependent (@modules) {
      $dependent{$dependent} = 1;
    }
  }

  # Test dependents of the current file.

  my $file_problems = 0;
  foreach my $dependent (sort keys %dependent) {

    my $dep_type = &dep_type($file_key, $dependent);
    my $dep_name = '????s';
    if ($dep_type & DT_WANTS) {
      $dep_name = 'wants';
    }
    elsif ($dep_type & DT_NEEDS) {
      $dep_name = 'needs';
    }

    close STDERR;
    eval 'package Test::' . $test_package++ . "; use $dependent";
    open STDERR, '>&STDERR_HOLD' or print "cannot restore STDERR: $!";

    my $is_ok = !(defined $@ and length $@);

    my $inc_key = $dependent . '.pm';
    $inc_key = File::Spec->catdir( split /\:\:/, $inc_key );

    # -><- set $is_ok=0 here to test a missing/broken dependency
    # $is_ok = 0 if $dependent eq 'Filter::Util::Call';

    # Classify the module.
    if ($is_ok) {
      if (TRACE_GOOD) {

        push @file_messages, "\t$dep_name $dependent";

        if (exists $INC{$inc_key}) {
          my $inc_file = $INC{$inc_key};

          TRACE_VERBOSE and $file_messages[-1] .= " (aka: $inc_file)";
          $file_messages[-1] .= " from ";

          if ($inc_file =~ $is_core_regexp) {
            TRACE_VERBOSE and
              $file_messages[-1] .= "perl's private library";
          }
          elsif ($inc_file =~ $is_site_regexp) {
            TRACE_VERBOSE and
              $file_messages[-1] .= "perl's site library";
          }
          elsif ($inc_file !~ m!^(?:[a-zA-Z]\:)/!) {
            my $type = &file_type($dependent);
            if ($type & FT_CORE) {
              TRACE_VERBOSE and
                $file_messages[-1] .= "this distribution's core library";
            }
            elsif ($type & FT_EXTENSION) {
              TRACE_VERBOSE and
                $file_messages[-1] .= "this distribution's extended library";
            }
            else {
              TRACE_VERBOSE and
                $file_messages[-1] .= "somewhere in this distribution";
            }
          }
          else {
            TRACE_VERBOSE and
              $file_messages[-1] .= "who knows where?";
          }
        }
        else {
          TRACE_VERBOSE and
            $file_messages[-1] .= " which loaded but isn't in \%INC";
        }
      }
    }
    else {
      TRACE_BAD and
        push( @file_messages,
              "\t$dep_name $dependent which didn't load"
            );
      
      if ($dep_type & DT_NEEDS) {
        $file_problems |= FT_BROKEN;
        if ($file_type & FT_CORE) {
          $file_status[FS_CORE_BROKEN]->{$dependent} = 1;
        }
        else {
          $file_status[FS_EXT_BROKEN]->{$dependent} = 1;
        }
      }
      elsif ($dep_type & DT_WANTS) {
        $file_problems |= FT_IMPAIRED;
        $file_status[FS_IMPAIRED]->{$dependent} = 1;
      }
      else {
        $file_problems |= FT_TROUBLED;
        $file_status[FS_TROUBLED]->{$dependent} = 1;
      }
    }
  }

  if ($file_problems & (FT_BROKEN | FT_IMPAIRED | FT_TROUBLED)) {

    if ($file_problems & FT_BROKEN) {
      if ($file_type & FT_CORE) {
        TRACE_BAD and
          push( @file_messages,
                "\t... this distribution cannot be installed."
              );
      }
      elsif ($file_type & FT_EXTENSION) {
        TRACE_BAD and
          push( @file_messages,
                "\t... this extension will not work."
              );
      }
      else {
        TRACE_BAD and
          push( @file_messages,
                "\t... this distribution may encounter problems."
              );
      }
    }
    elsif ($file_problems & FT_IMPAIRED) {
      TRACE_BAD and
        push( @file_messages,
              "\t... this module may not work as well as it could."
            );
    }
    elsif ($file_problems & FT_TROUBLED) {
      if ($file_type & FT_CORE) {
        TRACE_BAD and
          push( @file_messages,
                "\t... this distribution may encounter problems."
              );
      }
      elsif ($file_type & FT_EXTENSION) {
        TRACE_BAD and
          push( @file_messages,
                "\t... this extension may encounter problems."
              );
      }
      else {
        TRACE_BAD and
          push( @file_messages,
                "\t... this distribution may encounter problems."
              );
      }
    }

    TRACE_BAD and print STDERR join( "\n", @file_messages ), "\n";
  }
  else {
    TRACE_GOOD and print STDERR join( "\n", @file_messages ), "\n";
  }
}

# A final summary.

$Text::Wrap::columns = 80;
my @core_broken = sort keys %{$file_status[FS_CORE_BROKEN]};

my @ext_broken = grep( { !exists($file_status[FS_CORE_BROKEN]->{$_})
                       } sort keys %{$file_status[FS_EXT_BROKEN]}
                     );

my @impaired = grep( { !( exists($file_status[FS_CORE_BROKEN]->{$_}) or
                          exists($file_status[FS_EXT_BROKEN]->{$_})
                        )
                     } sort keys %{$file_status[FS_IMPAIRED]}
                   );

my @troubled = grep( { !( exists($file_status[FS_CORE_BROKEN]->{$_}) or
                          exists($file_status[FS_EXT_BROKEN]->{$_}) or
                          exists($file_status[FS_IMPAIRED]->{$_})
                        )
                     } sort keys %{$file_status[FS_TROUBLED]}
                   );

if (SHOW_SUMMARY) {
  my @messages;
  if (@core_broken) {
    push( @messages,
          "This distribution cannot be installed because it requires one or " .
          "more modules which are not present: " . join('; ', @core_broken)
        );
  }

  if (@ext_broken) {
    push( @messages,
          "Optional parts of this distribution will be installed but may " .
          "not work correctly (or at all) because one or more modules " .
          "which they require are not installed: " . join('; ', @ext_broken)
        );
  }

  if (@impaired) {
    push( @messages,
          "One or more recommended modules are not present.  This " .
          "distribution will work around the missing modules at the " .
          "expense of features or performance: " . join('; ', @impaired)
        );
  }

  if (@troubled) {
    push( @messages,
          "This distribution uses one or more modules which are " .
          "classified neither as requirements nor as recommendations.  " .
          "Something may go wrong after installation, but this program " .
          "can't determine what that might be.  If problems occur, try " .
          "installing these modules: " . join('; ', @troubled)
        );
  }

  foreach my $message (@messages) {
    print STDERR "\n***\n";
    print STDERR wrap( '*** ', '*** ', $message );
  }
  print STDERR "\n***\n\n" if @messages;
}

exit 1 if @core_broken;
exit 0;
