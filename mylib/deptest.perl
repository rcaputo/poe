#!/usr/bin/perl -w
# $Id$

use strict;
use Config qw(%Config);
use ExtUtils::Manifest qw(maniread);
use File::Spec;
use Text::Wrap;

# Enable verbose testing if this is running on solaris, because
# solaris' CPAN tester's machine has trouble finding some modules
# which do exist.
BEGIN {
  if ($^O eq 'solaris') {
    eval 'sub TRACE_GATHER () { 1 }';
  }
  else {
    eval 'sub TRACE_GATHER () { 0 }';
  }
};
sub TRACE_SECTION () { 1 }  # lets the installer know what's going on

open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";
open STDERR_HOLD, '>&STDERR' or die "cannot save STDERR: $!";
open STDOUT_HOLD, '>&STDOUT' or die "cannot save STDOUT: $!";
open STDOUT_HOLD, '>&STDOUT' or die "cannot save STDOUT: $!";

#------------------------------------------------------------------------------
# Tracing stuff.

sub trace_gather {
  TRACE_GATHER and print STDERR join('', @_), "\n";
}

sub trace_section {
  TRACE_SECTION and print STDERR join('', @_), "\n";
}

#------------------------------------------------------------------------------
# Read dependency tagging rules from the NEEDS file.  Includes some
# functions used to test files against rules.

&trace_section( 'Reading dependency hints from NEEDS.' );

sub FT_UNKNOWN    () { 0x0001 } # file type: unknown
sub FT_CORE       () { 0x0002 } # file type: core
sub FT_EXTENSION  () { 0x0004 } # file type: extension
sub FT_DATA       () { 0x0008 } # file type: data
sub FT_ANY        () { FT_UNKNOWN | FT_CORE | FT_EXTENSION | FT_DATA }

sub FO_UNKNOWN    () { 0x0010 } # file type: unknown
sub FO_INTERNAL   () { 0x0020 } # file type: internal (part of this dist.)
sub FO_EXTERNAL   () { 0x0040 } # file type: external (part of something else)
sub FO_ANY        () { FO_UNKNOWN | FO_INTERNAL | FO_EXTERNAL }

sub FS_UNKNOWN    () { 0x0080 } # file status: unknown (prevents dep. loops)
sub FS_OK         () { 0x0100 } # file status: ok
sub FS_BAD        () { 0x0200 } # file status: bad
sub FS_IMPAIRED   () { 0x0400 } # file status: impaired
sub FS_OUTDATED   () { 0x0800 } # file status: dependency is too old
sub FS_ANY        () { FS_UNKNOWN | FS_OK | FS_BAD |
                       FS_IMPAIRED | FS_OUTDATED
                     }

sub DT_WANTS      () { 0x0800 } # dependency type: soft
sub DT_NEEDS      () { 0x1000 } # dependency type: hard
sub DT_ANY        () { DT_WANTS | DT_NEEDS }

sub RULE_USER_MASK   () { 0 }
sub RULE_TYPE        () { 1 }
sub RULE_DEP_MASK    () { 2 }
sub RULE_DEP_VERSION () { 3 }

my %module_type =
  ( core      => FT_CORE,
    extension => FT_EXTENSION,
    data      => FT_DATA
  );
my %dependency_type = ( wants => DT_WANTS, needs => DT_NEEDS );

my @mod_rules =
  ( [ '.*',                     # RULE_USER_MASK
      $module_type{core},       # RULE_TYPE
    ],
  );

my @dep_rules =
  ( [ '.*',                     # RULE_USER_MASK
      $dependency_type{needs},  # RULE_TYPE
      '.*',                     # RULE_DEP_MASK
      0,                        # RULE_DEP_VERSION
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
    elsif (/^ \s* (\S+)
              \s+ (wants|needs|prefers)
              \s+ (\S+)
              \s* ([0-9_\.]*)
              \s* (?:\#.*)?
           $/x
          ) {

      my ($user_mask, $dep_type, $usee_mask, $version) = ($1, $2, $3, $4);
      $version = 0 unless defined $version and length $version;

      push( @dep_rules,
            [ &mask_to_regexp($user_mask),  # RULE_USER_MASK
              $dependency_type{$dep_type},  # RULE_DEP_TYPE
              &mask_to_regexp($usee_mask),  # RULE_DEP_MASK
              $version,                     # RULE_DEP_VERSION
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

# Make a name for a file type.
sub file_type_name {
  my $file_type = shift;
  return 'core'      if $file_type & FT_CORE;
  return 'extension' if $file_type & FT_EXTENSION;
  return 'unknown';
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

# Determine a dependency version.  Make a hash, or use masks properly?
sub dep_version {
  my $usee = quotemeta(shift);
  my $dep_version = 0;
  foreach my $dep_rule (@dep_rules) {
    my $usee_regexp = $dep_rule->[RULE_DEP_MASK];
    next unless $usee =~ /^$usee_regexp$/;
    $dep_version = $dep_rule->[RULE_DEP_VERSION];
  }
  return $dep_version;
}

#------------------------------------------------------------------------------
# Gather MANIFEST files.

my %dep_node;
sub NODE_TYPE      () { 0 }
sub NODE_CHILDREN  () { 1 }
sub NODE_FILE_NAME () { 2 }

&trace_section( 'Gathering files from MANIFEST.' );

my $manifest = maniread();
die "can't read MANIFEST: $!\n" unless defined $manifest;

foreach my $manifest_filename (sort keys %$manifest) {

  # Transform obvious module names into filenames.  Old versions of
  # File::Spec (and they're out there) don't do splitdir.  Fall back
  # on a cheezy regexp if one is encountered.
  my $file_key = $manifest_filename;
  if ($file_key =~ s!\.pm$!!) {
    my @split_dir;
    eval { @split_dir = File::Spec->splitdir( $file_key ); };
    @split_dir = split(/[\\\/\:]+/, $file_key) unless @split_dir;
    $file_key = join '::', @split_dir;
  }

  # Determine what sort of file we have.  Don't bother with data.
  my $file_type = &file_type($file_key);
  next if $file_type & FT_DATA;

  # Just in case MANIFEST has duplicates.
  next if exists $dep_node{$file_key};

  # Build an internal node.
  $dep_node{$file_key} =
    [ FO_INTERNAL | $file_type,  # NODE_TYPE
      { },                       # NODE_CHILDREN
      $manifest_filename,        # NODE_FILE_NAME
    ];
}

#------------------------------------------------------------------------------
# Expand the MANIFEST nodes into trees.

&trace_section( 'Building dependency tree.' );

my $test_package = 0;
my $is_core_regexp = '^' . quotemeta($Config{installprivlib});

my @manifest_files = keys %dep_node;
foreach my $manifest_file (@manifest_files) {
  &build_dependency_tree($manifest_file);
}

sub build_dependency_tree {
  my $file_key = shift;

  # If the module isn't in %dep_node, then we'll have to try to find
  # it and figure out whether it's internal or external.
  unless (exists $dep_node{$file_key}) {

    &trace_gather( "Testing module $file_key ..." );

    # Pause output.  Older File::Spec doesn't include a devnull
    # method, so fall back on /dev/null if it's missing.
    my $dev_null;
    eval { $dev_null = File::Spec->devnull };
    $dev_null = '/dev/null' unless defined $dev_null;

    if ($^O ne 'solaris' or $file_key !~ /Exporter/) {
      open(STDERR, ">$dev_null") or close STDERR;
      open(STDOUT, ">$dev_null") or close STDERR;
    }

    eval 'package Test::Package_' . $test_package++ . "; use $file_key";
    my $is_ok = !(defined $@ and length $@);

    # Resume output.
    if ($^O ne 'solaris' or $file_key !~ /Exporter/) {
      open STDOUT, '>&STDOUT_HOLD'
        or print STDOUT_HOLD "cannot restore STDOUT: $!";
      open STDERR, '>&STDERR_HOLD'
        or print STDERR_HOLD "cannot restore STDERR: $!";
    }

    if ($is_ok) {
      # Determine the filename from %INC, and try to figure out
      # whether it's ours or something else's.

      &trace_gather( "\t$file_key found." );

      my $inc_key = $file_key . '.pm';
      $inc_key = File::Spec->catdir( split /\:\:/, $inc_key );

      if (exists $INC{$inc_key}) {

        my $inc_file = $INC{$inc_key};
        my $file_type;

        if (File::Spec->file_name_is_absolute($inc_file)) {
          $file_type = FO_EXTERNAL;

          # If it's an outdated dependency, then it's bad.
          my $dependency_version = eval "\$" . $file_key . '::VERSION';
          $dependency_version = 0
            unless defined $dependency_version and length $dependency_version;
          { local $^W = 0;
            $dependency_version += 0;
          }

          my $test_version = dep_version($file_key);
          &trace_gather( "\t$file_key is version $dependency_version." );
          &trace_gather( "\t$file_key version needed: $test_version." );

          if ($dependency_version < dep_version($file_key)) {
            $file_type |= FS_OUTDATED;
          }
          else {
            $file_type |= FS_OK;
          }

          if ($inc_file =~ /^$is_core_regexp$/) {
            $file_type |= FT_CORE;
          }
          else {
            $file_type |= FT_EXTENSION;
          }
        }
        else {
          $file_type = FO_INTERNAL | &file_type($file_key);
        }

        $dep_node{$file_key} =
          [ $file_type,  # NODE_TYPE
            { },         # NODE_CHILDREN
            $inc_file,   # NODE_FILE_NAME
          ];
      }
      else {
        die "$file_key was used ok, but it didn't appear in \%INC";
      }
    }
    else {
      &trace_gather( "\t$file_key NOT found." );

      $dep_node{$file_key} =
        [ FT_UNKNOWN | FO_UNKNOWN | FS_BAD, # NODE_TYPE
          { },                              # NODE_CHILDREN
          undef,                            # NODE_FILE_NAME
        ];
      return FS_BAD;
    }
  }

  my $file_name = $dep_node{$file_key}->[NODE_FILE_NAME];

  # Don't bother with this node if it's already been done.
  return $dep_node{$file_key}->[NODE_TYPE] & FS_ANY
    if $dep_node{$file_key}->[NODE_TYPE] & FS_ANY;

  # If the module is internal to this project, then we'll read it.
  if ($dep_node{$file_key}->[NODE_TYPE] & FO_INTERNAL) {

    &trace_gather( "Gathering dependencies for $file_key ($file_name)" );

    # Flag the file status as bad if it can't be read.

    unless (open(FILE, "<$file_name")) {
      &trace_gather( "\tskipping unreadable MANIFEST file $file_name: $!" );
      $dep_node{$file_key}->[NODE_TYPE] &= ~FS_UNKNOWN;
      $dep_node{$file_key}->[NODE_TYPE] |= FS_BAD;
      return FS_BAD;
    }

    # Read file into a single string.  Normalize whitespace, and, to
    # the best of our ability, remove comments.

    my $code = '';
    while (<FILE>) {
      chomp;
      s/(?<!\\)\s*\#.*$//; # May Turing have mercy upon me.
      next if /^\s*$/;     # Skip blank lines.
      last if /^__END__/;  # Skip DATA division.

      $code .= " $_ ";
    }
    close FILE;

    $code =~ s/\s+/ /g;

    # Break circular dependencies by flagging this file's status as
    # "unknown" while it's being dealt with.
    $dep_node{$file_key}->[NODE_TYPE] |= FS_UNKNOWN;

    # Gather whatever dependents we can find in this file.  This is
    # far from ideal code.

    while ($code =~ / (?<!\w\s)
                      \b (use|require) \s+ (\S+)
                      (?: \s* (?:qw\(|[\'\"]) \s* (.+?) \s* [\)\'\"] )?
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
      next if $dependent =~ /[^A-Za-z\:\-_]/;

      # Explode extra parameters if the reference is to POE itself.
      my @modules = ($dependent);
      push @modules, map { "POE::" . $_ } split /\s+/, $extra
        if $dependent eq 'POE' and defined $extra;

      foreach my $dependent (@modules) {

        # Determine the dependent's status.
        my $dependency_type =
          ( &dep_type($file_key, $dependent) |
            &build_dependency_tree($dependent)
          );

        # If the dependency status is unknown, it means we're pointing
        # back to something which depends upon us.  Break the circle
        # here by ignoring the dependent.  -><- Fix it later?
        next if $dependency_type & FS_UNKNOWN;

        $dep_node{$file_key}->[NODE_CHILDREN]->{$dependent} = $dependency_type;

        # Dependent is ok; move along.
        next if $dependency_type & FS_OK;

        # This file is impaired if an optional dependent is bad.
        if ($dependency_type & DT_WANTS) {
          $dep_node{$file_key}->[NODE_TYPE] |= FS_IMPAIRED;
          next;
        }

        # This file is bad if an optional dependent is bad.
        if ($dependency_type & DT_NEEDS) {
          $dep_node{$file_key}->[NODE_TYPE] |= FS_BAD;
          next;
        }
      }
    }

    # Turn off the FS_UNKNOWN flag.
    $dep_node{$file_key}->[NODE_TYPE] &= ~FS_UNKNOWN;

    # The module is good if no FS_* bit has been set by now.
    $dep_node{$file_key}->[NODE_TYPE] |= FS_OK
      unless $dep_node{$file_key}->[NODE_TYPE] & FS_ANY;
  }
  else {
    &trace_gather( "WTF? $file_key" );
  }

  # Return just the FS portion of this node's status.
  return $dep_node{$file_key}->[NODE_TYPE] & FS_ANY;
}

#------------------------------------------------------------------------------
# Summary.

sub node_flags {
  my $type = shift;
  my @words;

  push @words, 'file=unknown'   if $type & FT_UNKNOWN;
  push @words, 'file=core'      if $type & FT_CORE;
  push @words, 'file=extension' if $type & FT_EXTENSION;
  push @words, 'file=data'      if $type & FT_DATA;

  push @words, 'owner=unknown'  if $type & FO_UNKNOWN;
  push @words, 'owner=dist'     if $type & FO_INTERNAL;
  push @words, 'owner=other'    if $type & FO_EXTERNAL;

  push @words, 'stat=unknown'   if $type & FS_UNKNOWN;
  push @words, 'stat=ok'        if $type & FS_OK;
  push @words, 'stat=bad'       if $type & FS_BAD;
  push @words, 'stat=impaired'  if $type & FS_IMPAIRED;

  push @words, 'dep=wants'      if $type & DT_WANTS;
  push @words, 'dep=needs'      if $type & DT_NEEDS;

  join( ' ', map { "($_)" } @words );
}

sub PARENT_KEY      () { 0 }
sub PARENT_CHILDREN () { 1 }

sub gather_leaves {
  my ($parent_must_be, $dep_must_be) = @_;
  my @parents;

  foreach my $parent_key (sort keys %dep_node) {
    my $parent = $dep_node{$parent_key};

    # Skip the node if it's not part of the distribution or if it's
    # ok.  We only need to know about distribution modules which have
    # bad dependencies.
    next unless $parent->[NODE_TYPE] & FO_INTERNAL;
    next unless $parent->[NODE_TYPE] & $parent_must_be;
    next if     $parent->[NODE_TYPE] & FS_OK;

    # Skip this node if all its bad dependents are internal.
    my @found_children;

    foreach my $child_key (sort keys %{$parent->[NODE_CHILDREN]}) {
      my $child_status = $dep_node{$child_key}->[NODE_TYPE];
      next if     $child_status & FO_INTERNAL;
      next if     $child_status & FS_OK;
      next unless $parent->[NODE_CHILDREN]->{$child_key} & $dep_must_be;
      push( @found_children, $child_key );
    }

    push( @parents,
          [ $parent_key,      # PARENT_KEY
            \@found_children, # PARENT_CHILDREN
          ]
        )
      if @found_children;
  }

  return @parents;
}

sub show_leaves {
  my $verb = shift;
  my %dependents;
  foreach (@_) {
    my @children = @{$_->[PARENT_CHILDREN]};
    foreach my $child (@children) {
      my $child_version = dep_version($child);
      if (defined $child_version and $child_version > 0) {
        $child .= " $child_version or newer";
      }
    }
    my $children = join('; ', @children);
    foreach my $child (@{$_->[PARENT_CHILDREN]}) {
      $dependents{$child} = 1;
    }
    $children =~ s/^(.*)\;/$1 and/;
    print( STDERR
           "\n",
           wrap( '***     ', '***     ', "$_->[PARENT_KEY] $verb $children")
         );
  }
  return sort keys %dependents;
}

my @critical_errors = &gather_leaves( FT_CORE, DT_NEEDS );
if (@critical_errors) {
  my ($parts, $need);
  if (@critical_errors == 1) {
    ($parts, $need) = ('A required part', 'needs');
  }
  else {
    ($parts, $need) = ('Required parts', 'need');
  }

  print( STDERR
         "\n***\n",
         wrap
         ( '*** ', '*** ',

           "$parts of this distribution $need at least one additional " .
           "module which is either outdated or not installed.  The " .
           "distribution should not be installed until these modules " .
           "are installed or updated:"
         ),
       );
  my @summary = &show_leaves('needs', @critical_errors);
  print( STDERR
         "\n", wrap( '***   ', '***   ',
                     "Please install the most recent: @summary" )
       );
}

my @recoverable_errors = &gather_leaves( FT_EXTENSION, DT_NEEDS );
if (@recoverable_errors) {
  my ($parts, $need, $these_parts, $their);
  if (@recoverable_errors == 1) {
    ($parts, $need, $these_parts, $their) =
      ('An optional part', 'needs', 'This part', 'its');
  }
  else {
    ($parts, $need, $these_parts, $their) =
      ('Optional parts', 'need', 'These parts', 'their');
  }

  print( STDERR
         "\n***\n",
         wrap
         ( '*** ', '*** ',
           "$parts of this distribution $need at least one additional " .
           "module which is either outdated or not installed.  " .
           "$these_parts will be installed, but $their features may not " .
           "be usable until $their dependencies are installed or updated:"
         ),
       );
  my @summary = &show_leaves('wants', @recoverable_errors);
  print( STDERR
         "\n", wrap( '***   ', '***   ',
                     "Please consider installing the most recent: @summary"
                   )
       );
}

my @warnings = &gather_leaves( FS_IMPAIRED, DT_ANY );
if (@warnings) {
  my ($parts, $these_parts, $they, $their);
  if (@warnings == 1) {
    ($parts, $these_parts, $they, $their) =
      ('An optional part', 'This part', 'it', 'its');
  }
  else {
    ($parts, $these_parts, $they, $their) =
      ('Optional parts', 'These parts', 'they', 'their');
  }

  print( STDERR
         "\n***\n",
         wrap
         ( '*** ', '*** ',
           "$parts of this distribution may work better if at least one " .
           "additional module is installed or updated.  $these_parts " .
           "will be installed, but $they may not work as well as $they " .
           "could if $their dependencies are installed or updated:"
         ),
       );
  my @summary = &show_leaves('works better with', @warnings);
  print( STDERR
         "\n", wrap( '***   ', '***   ',
                     "Please install the most recent: @summary"
                   )
       );
}

if (@critical_errors or @recoverable_errors or @warnings) {
  print STDERR "\n***\n";
}
else {
  print STDERR "\n***\n*** All dependencies found.\n***\n";
}

exit 1 if @critical_errors;
exit 0;
