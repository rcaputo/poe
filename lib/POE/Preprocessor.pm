# $Id$

package POE::Preprocessor;

use strict;
use Filter::Util::Call;

sub MAC_PARAMETERS () { 0 }
sub MAC_CODE       () { 1 }

sub STATE_PLAIN     () { 0x0000 }
sub STATE_MACRO_DEF () { 0x0001 }

sub COND_FLAG   () { 0 }
sub COND_LINE   () { 1 }
sub COND_INDENT () { 2 }

BEGIN {
  defined &DEBUG        or eval 'sub DEBUG        () { 0 }'; # preprocessor
  defined &DEBUG_ROP    or eval 'sub DEBUG_ROP    () { 0 }'; # regexp optimizer
  defined &DEBUG_INVOKE or eval 'sub DEBUG_INVOKE () { 0 }'; # macro invocs
  defined &DEBUG_DEFINE or eval 'sub DEBUG_DEFINE () { 0 }'; # macro defines
};

# Create an optimal regexp to match a list of things.
my $debug_level = 0;

sub optimum_match {
  my @sorted = sort { (length($b) <=> length($a)) || ($a cmp $b) } @_;
  my @regexp;
  my $width = 40 - $debug_level;

  DEBUG_ROP and do {
    warn ' ' x $debug_level, "+-----\n";
    warn ' ' x $debug_level, "| Given: @sorted\n";
    warn ' ' x $debug_level, "+-----\n";
  };

  while (@sorted) {
    my $longest = $sorted[0];

    DEBUG_ROP and do {
      warn ' ' x $debug_level, "+-----\n";
      warn( ' ' x $debug_level,
            "| Longest : ",
            sprintf("%-${width}s", unpack('H*', $longest)),
            " ($longest)\n"
          );
    };

    # Find the length of the longest match.
    my $minimum_match_count = length $longest;
    foreach (@sorted) {
      my $xor = $_ ^ $longest;
      if (($xor =~ /^(\000+)/) and (length($1) < $minimum_match_count)) {
        $minimum_match_count = length($1);
      }
    }

    DEBUG_ROP and
      warn ' ' x $debug_level, "| sz_match: $minimum_match_count\n";

    # Extract the things matching it.
    my $minimum_match_string = substr($longest, 0, $minimum_match_count);
    DEBUG_ROP and
      warn ' ' x $debug_level, "| st_match: $minimum_match_string\n";

    my @matches = grep /^$minimum_match_string/, @sorted;
    @sorted = grep !/^$minimum_match_string/, @sorted;

    # Only one match? Nothing to compare, or anything.
    if (@matches == 1) {
      DEBUG_ROP and warn ' ' x $debug_level, "| matches : $matches[0]\n";
      push @regexp, $matches[0];
    }

    # More than one match? Recurse!
    else {
      # Remove the common prefix.
      my $matches_index = @matches;
      while ($matches_index--) {
        $matches[$matches_index] =~ s/^$minimum_match_string//;
        splice(@matches, $matches_index, 1)
          unless length $matches[$matches_index];
      }

      # If only one left now, then it's an optional prefix.
      if (@matches == 1) {
        my $sub_expression = "$minimum_match_string(?:$matches[0])?";
        DEBUG_ROP and warn ' ' x $debug_level, "| option  : $sub_expression\n";
        push @regexp, $sub_expression;
      }
      else {
        DEBUG_ROP and warn ' ' x $debug_level, "| recurse : @matches\n";

        $debug_level++;
        my $sub_expression = &optimum_match(@matches);
        $debug_level--;

        # Build part of this regexp.
        push @regexp, '(?:' . $minimum_match_string . $sub_expression . ')';
      }
    }
  }

  my $sub_expression = '(?:' . join('|', @regexp). ')';

  DEBUG_ROP and do {
    warn ' ' x $debug_level, "+-----\n";
    warn ' ' x $debug_level, "| Returns: $sub_expression\n";
    warn ' ' x $debug_level, "+-----\n";
  };

  $sub_expression;
}

# These must be accessible from outside the current package.
use vars qw(%conditional_stacks %excluding_code %exclude_indent);

sub fix_exclude {
  my $package_name = shift;
  $excluding_code{$package_name} = 0;
  if (@{$conditional_stacks{$package_name}}) {
    foreach my $flag (@{$conditional_stacks{$package_name}}) {
      unless ($flag->[COND_FLAG]) {
        $excluding_code{$package_name} = 1;
        $exclude_indent{$package_name} = $flag->[COND_INDENT];
        last;
      }
    }
  }
}

sub import {
  # Outer closure to define a unique scope.
  { my $macro_name = '';
    my ( %macros, $macro_line, %constants, $const_regexp, $enum_index );
    my ($package_name, $file_name, $line_number) = (caller)[0,1,2];
    my $const_regexp_dirty = 0;
    my $state = STATE_PLAIN;

    $conditional_stacks{$package_name} = [ ];
    $excluding_code{$package_name} = 0;

    my $set_const = sub {
      my ($name, $value) = @_;

      if (exists $constants{$name}) {
        warn "const $name redefined at $file_name line $line_number\n";
      }

      $constants{$name} = $value;
      $const_regexp_dirty++;

      DEBUG_DEFINE and
        warn( ",-----\n",
              "| Defined a constant: $name = $value\n",
              "`-----\n"
            );
    };

    # Define the filter sub.
    filter_add
      ( sub {
          my $status = filter_read();
          $line_number++;

          ### Handle errors or EOF.
          if ($status <= 0) {
            if (@{$conditional_stacks{$package_name}}) {
              die( "include block never closed.  It probably started " .
                   "at $file_name line " .
                   $conditional_stacks{$package_name}->[0]->[COND_LINE] . "\n"
                 );
            }
            return $status;
          }

          ### Usurp modified Perl syntax for code inclusion.  These
          ### are hardcoded and always handled.

          # Only do the conditionals if there's a flag present.
          if (/[\{\}]\s*\#\s*include\s*$/) {

            # if (...) { # include
            if (/^(\s*)if\s*\((.+)\)\s*\{\s*\#\s*include\s*$/) {
              my $space = (defined $1) ? $1 : '';
              $_ =
                ( $space .
                  "BEGIN { push( \@{\$" . __PACKAGE__ .
                  "::conditional_stacks{'$package_name'}}, " .
                  "[ !!$2, $line_number, '$space' ] ); \&" . __PACKAGE__ .
                  "::fix_exclude('$package_name'); }; # $_"
                );
              s/\#\s+/\# /;

              # Dummy line in the macro.
              if ($state & STATE_MACRO_DEF) {
                local $_ = $_;
                s/B/\# B/;
                $macro_line++;
                $macros{$macro_name}->[MAC_CODE] .= $_;
                DEBUG and
                  warn sprintf "%4d M: # mac 1: %s", $line_number, $_;
              }
              else {
                DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
              }

              return $status;
            }

            # } # include
            elsif (/^\s*\}\s*\#\s*include\s*$/) {
              s/^(\s*)/$1\# /;
              pop @{$conditional_stacks{$package_name}};
              &fix_exclude($package_name);

              unless ($state & STATE_MACRO_DEF) {
                DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
                return $status;
              }
            }

            # } else { # include
            elsif (/^\s*\}\s*else\s*\{\s*\#\s*include\s*$/) {
              unless (@{$conditional_stacks{$package_name}}) {
                die( "else { # include ... without if or unless " .
                     "at $file_name line $line_number\n"
                   );
                return -1;
              }

              s/^(\s*)/$1\# /;
              $conditional_stacks{$package_name}->[-1]->[COND_FLAG] =
                !$conditional_stacks{$package_name}->[-1]->[COND_FLAG];
              &fix_exclude($package_name);

              unless ($state & STATE_MACRO_DEF) {
                DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
                return $status;
              }
            }

            # unless (...) { # include
            elsif (/^(\s*)unless\s*\((.+)\)\s*\{\s*\#\s*include\s*$/) {
              my $space = (defined $1) ? $1 : '';
              $_ = ( $space .
                     "BEGIN { push( \@{\$" . __PACKAGE__ .
                     "::conditional_stacks{'$package_name'}}, " .
                     "[ !$2, $line_number, '$space' ] ); \&" . __PACKAGE__ .
                     "::fix_exclude('$package_name'); }; # $_"
                   );
              s/\#\s+/\# /;

              # Dummy line in the macro.
              if ($state & STATE_MACRO_DEF) {
                local $_ = $_;
                s/B/\# B/;
                $macro_line++;
                $macros{$macro_name}->[MAC_CODE] .= $_;
                DEBUG and
                  warn sprintf "%4d M: # mac 2: %s", $line_number, $_;
              }
              else {
                DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
              }

              return $status;
            }

            # } elsif (...) { # include
            elsif (/^(\s*)\}\s*elsif\s*\((.+)\)\s*\{\s*\#\s*include\s*$/) {
              unless (@{$conditional_stacks{$package_name}}) {
                die( "Include elsif without include if or unless " .
                     "at $file_name line $line_number\n"
                   );
                return -1;
              }

              my $space = (defined $1) ? $1 : '';
              $_ = ( $space .
                     "BEGIN { \$" . __PACKAGE__ .
                     "::conditional_stacks{'$package_name'}->[-1] = " .
                     "[ !!$2, $line_number, '$space' ]; \&" . __PACKAGE__ .
                     "::fix_exclude('$package_name'); }; # $_"
                   );
              s/\#\s+/\# /;

              # Dummy line in the macro.
              if ($state & STATE_MACRO_DEF) {
                local $_ = $_;
                s/B/\# B/;
                $macro_line++;
                $macros{$macro_name}->[MAC_CODE] .= $_;
                DEBUG and
                  warn sprintf "%4d M: # mac 3: %s", $line_number, $_;
              }
              else {
                DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
              }

              return $status;
            }
          }

          ### Not including code, so comment it out.  Don't return
          ### $status here since the code may well be in a macro.
          if ($excluding_code{$package_name}) {
            s{^($exclude_indent{$package_name})?}
             {$exclude_indent{$package_name}\# };

            # Kludge: Must thwart macros on this line.
            s/\{\%(.*?)\%\}/MACRO($1)/g;

            unless ($state & STATE_MACRO_DEF) {
              DEBUG and warn sprintf "%4d C: %s", $line_number, $_;
              return $status;
            }
          }

          ### Inside a macro definition.
          if ($state & STATE_MACRO_DEF) {

            # Close it!
            if (/^\}\s*$/) {
              $state = STATE_PLAIN;

              DEBUG_DEFINE and
                warn( ",-----\n",
                      "| Defined macro $macro_name\n",
                      "| Parameters: ",
                      @{$macros{$macro_name}->[MAC_PARAMETERS]}, "\n",
                      "| Code: {\n",
                      $macros{$macro_name}->[MAC_CODE],
                      "| }\n",
                      "`-----\n"
                    );

              $macros{$macro_name}->[MAC_CODE] =~ s/^\s*//;
              $macros{$macro_name}->[MAC_CODE] =~ s/\s*$//;

              $macro_name = '';
            }

            # Otherwise append this line to the macro.
            else {
              $macro_line++;
              $macros{$macro_name}->[MAC_CODE] .= $_;
            }

            # Either way, the code must not go on.
            $_ = "# mac 4: $_";
            DEBUG and warn sprintf "%4d M: %s", $line_number, $_;

            return $status;
          }

          ### Ignore everything after __END__ or __DATA__.  This works
          ### around a coredump in 5.005_61 through 5.6.0 at the
          ### expense of preprocessing data and documentation.
          if (/^__(END|DATA)__\s*$/) {
            $_ = "# $_";
            return 0;
          }

          ### We're done if we're excluding code.
          return $status if $excluding_code{$package_name};

          ### Define an enum.
          if (/^enum(?:\s+(\d+|\+))?\s+(.*?)\s*$/) {
            my $temp_line = $_;

            $enum_index = ( (defined $1)
                            ? ( ($1 eq '+')
                                ? $enum_index
                                : $1
                              )
                            : 0
                          );
            foreach (split /\s+/, $2) {
              &{$set_const}($_, $enum_index++);
            }

            $_ = "# $temp_line";

            DEBUG and warn sprintf "%4d E: %s", $line_number, $_;

            return $status;
          }

          ### Define a constant.
          if (/^const\s+([A-Z_][A-Z_0-9]+)\s+(.+?)\s*$/) {

            &{$set_const}($1, $2);
            $_ = "# $_";
            DEBUG and warn sprintf "%4d E: %s", $line_number, $_;
            return $status;
          }

          ### Begin a macro definition.
          if (/^macro\s*(\w+)\s*(?:\((.*?)\))?\s*\{\s*$/) {
            $state = STATE_MACRO_DEF;

            my $temp_line = $_;

            $macro_name = $1;
            $macro_line = 0;
            my @macro_params =
              ( (defined $2)
                ? split(/\s*\,\s*/, $2)
                : ()
              );

            if (exists $macros{$macro_name}) {
              warn( "macro $macro_name redefined ",
                    "at $file_name line $line_number\n"
                  );
            }

            $macros{$macro_name} = [ ];
            $macros{$macro_name}->[MAC_PARAMETERS] = \@macro_params;
            $macros{$macro_name}->[MAC_CODE] = '';

            $_ = "# $temp_line";
            DEBUG and warn sprintf "%4d D: %s", $line_number, $_;
            return $status;
          }

          ### Perform macro substitutions.
          my $substitutions = 0;
          while (/^(.*?)\{\%\s+(\S+)\s*(.*?)\s*\%\}(.*)$/s) {
            my ($left, $name, $params, $right) = ($1, $2, $3, $4);

            DEBUG_INVOKE and
              warn ",-----\n| macro invocation: $name $params\n";

            if (exists $macros{$name}) {

              my @use_params = split /\s*\,\s*/, $params;
              my @mac_params = @{$macros{$name}->[MAC_PARAMETERS]};

              if (@use_params != @mac_params) {
                warn( "macro $name paramter count (",
                      scalar(@use_params),
                      ") doesn't match defined count (",
                      scalar(@mac_params),
                      ") at $file_name line $line_number\n"
                    );
                return $status;
              }

              # Build a new bit of code here.
              my $substitution = $macros{$name}->[MAC_CODE];

              foreach my $mac_param (@mac_params) {
                my $use_param = shift @use_params;
                1 while ($substitution =~ s/$mac_param/$use_param/g);
              }

              unless ($^P) {
                my @sub_lines = split /\n/, $substitution;
                my $sub_line = @sub_lines;
                while ($sub_line--) {
                  splice( @sub_lines, $sub_line, 0,
                          "# line $line_number " .
                          "\"macro $name (line $sub_line) " .
                          "invoked from $file_name\""
                        );
                }
                $substitution = join "\n", @sub_lines;
              }

              $_ = $left . $substitution . $right;
              $_ .= "# line " . ($line_number+1) . " \"$file_name\"\n"
                unless $^P;

              DEBUG_INVOKE and warn "$_`-----\n";

              $substitutions++;
            }
            else {
              warn( "macro $name has not been defined ",
                    "at $file_name line $line_number\n"
                  );
              last;
            }
          }

          # Only rebuild the constant regexp if necessary.  This
          # prevents redundant regexp rebuilds when defining several
          # constants all together.
          if ($const_regexp_dirty) {
            $const_regexp = &optimum_match(keys %constants);
            $const_regexp_dirty = 0;
          }

          # Perform constant substitutions.
          if (defined $const_regexp) {
            $substitutions += s/\b($const_regexp)\b/$constants{$1}/sg;
          }

          # Trace substitutions.
          if (DEBUG) {
            if ($substitutions) {
              foreach my $line (split /\n/) {
                warn sprintf "%4d S: %s\n", $line_number, $line;
              }
            }
            else {
              warn sprintf "%4d |: %s", $line_number, $_;
            }
          }

          $status;
        }
      );
  }
}

1;

__END__

=head1 NAME

POE::Preprocessor - A Macro Preprocessor

=head1 SYNOPSIS

  use POE::Preprocessor;

  macro max (one,two) {
    ((one) > (two) ? (one) : (two))
  }

  print {% max $one, $two %}, "\n";

  const PI 3.14159265359

  print "PI\n";  # Substitutions don't grok Perl!

  enum ONE TWO THREE
  enum 12 TWELVE THIRTEEN FOURTEEN
  enum + FIFTEEN SIXTEEN SEVENTEEN

  print "ONE TWO THREE TWELVE THIRTEEN FOURTEEN FIFTEEN SIXTEEN SEVENTEEN\n";

  if ($expression) {      # include
     ... lines of code ...
  }                       # include

  unless ($expression) {  # include
    ... lines of code ...
  } elsif ($expression) { # include
    ... lines of code ...
  } else {                # include
    ... lines of code ...
  }                       # include

=head1 DESCRIPTION

POE::Preprocessor is a Perl source filter that implements a simple
macro substitution language.

=head2 Macros

The preprocessor defines a "macro" compile-time directive:

  macro macro_name (parameter_0, parameter_1) {
    macro code ... parameter_0 ... parameter_1 ...
  }

The parameter list is optional for macros that don't accept
parameters.

Macros are substituted into a program with a syntax borrowed from
Iaijutsu and altered slightly to jive with Perl's native syntax.

  {% macro_name parameter_0, parameter_1 %}

=head2 Constants and Enumerations

Constants are defined this way:

  const CONSTANT_NAME    'constant value'
  const ANOTHER_CONSTANT 23

Enumerations can begin with 0:

  enum ZEROTH FIRST SECOND ...

Or some other number:

  enum 10 TENTH ELEVENTH TWELFTH

Or continue where the previous one left off, which is necessary
because an enumeration can't span lines:

  enum + THIRTEENTH FOURTEENTH FIFTEENTH ...

=head2 Conditional Code Inclusion (#ifdef)

The preprocessor supports something like cpp's #if/#else/#endif by
usurping a bit of Perl's conditional syntax.  The following
conditional statements will be evaluated at compile time if they are
followed by the comment C<# include>:

  if (EXPRESSION) {      # include
    BLOCK;
  } elsif (EXPRESSION) { # include
    BLOCK;
  } else {               # include
    BLOCK;
  }                      # include

  unless (EXPRESSION) {  # include
    BLOCK;
  }                      # include

The code in each conditional statement's BLOCK will be included or
excluded in the compiled code depending on the outcome of its
EXPRESSION.

Conditional includes are nestable, but else and elsif must be on the
same line as the previous block's closing brace.  This may change
later.

=head1 DEBUGGING

POE::Preprocessor has four debugging constants: DEBUG (which traces
source filtering to stderr); DEBUG_ROP (which shows what the regexp
optimizer is up to); DEBUG_INVOKE (which traces macro substitutions);
and DEBUG_DEFINE (which traces macro, const and enum definitions).
They can be overridden prior to POE::Preprocessor's use:

  sub POE::Preprocessor::DEBUG        () { 1 } # trace preprocessor
  sub POE::Preprocessor::DEBUG_ROP    () { 1 } # trace regexp optimizer
  sub POE::Preprocessor::DEBUG_INVOKE () { 1 } # trace macro use
  sub POE::Preprocessor::DEBUG_DEFINE () { 1 } # trace macro/const/enum defs
  use POE::Preprocessor;

=head1 BUGS

=over 2

=item *

Source filters are line-based, and so is the macro language.  The only
constructs that may span lines are the brace-delimited macro
definitions.  And those *must* span lines.

=item *

The regular expressions that detect and replace code are simplistic
and may not do the right things when given challenging Perl syntax to
parse.  This includes placing constants in strings.

=item *

Substitution is done in two phases: macros first, then constants.  It
would be nicer (and more dangerous) if the phases looped around and
around until no more substitutions occurred.

=item *

Optimum matches aren't, but they're better than nothing.

=back

=head1 AUTHOR & COPYRIGHT

POE::Preprocessor is Copyright 2000 Rocco Caputo.  All rights
reserved.  POE::Preprocessor is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=cut
