# $Id$

package POE::Preprocessor;

use strict;

use vars qw($VERSION);
$VERSION = (qw($Revision$ ))[1];

use Carp qw(croak);
use Filter::Util::Call;

sub MAC_PARAMETERS () { 0 }
sub MAC_CODE       () { 1 }
sub MAC_NAME       () { 2 } # only used in temporary %macro
sub MAC_FILE       () { 3 }
sub MAC_LINE       () { 4 } # only used in temporary %macro

sub STATE_PLAIN     () { 0x0000 }
sub STATE_MACRO_DEF () { 0x0001 }

sub COND_FLAG   () { 0 }
sub COND_LINE   () { 1 }
sub COND_INDENT () { 2 }

#sub DEBUG () { 1 }
#sub DEBUG_INVOKE () { 1 }
#sub DEBUG_DEFINE () { 1 }

#sub WARN_DEFINE  () { 1 }

BEGIN {
  defined &DEBUG        or eval 'sub DEBUG        () { 0 }'; # preprocessor
  defined &DEBUG_INVOKE or eval 'sub DEBUG_INVOKE () { 0 }'; # macro invocs
  defined &DEBUG_DEFINE or eval 'sub DEBUG_DEFINE () { 0 }'; # macro defines
  defined &WARN_DEFINE  or eval 'sub WARN_DEFINE  () { 0 }'; # macro/const redefinition warning
};

# text_trie_trie is virtually identical to code in Ilya Zakharevich's
# Text::Trie::Trie function.  The minor differences involve hardcoding
# the minimum substring length to 1 and sorting the output.

sub text_trie_trie {
  my @list = @_;
  return shift if @_ == 1;
  my (@trie, %first);

  foreach (@list) {
    my $c = substr $_, 0, 1;
    if (exists $first{$c}) {
      push @{$first{$c}}, $_;
    }
    else {
      $first{$c} = [ $_ ];
    }
  }

  foreach (sort keys %first) {
    # Find common substring
    my $substr = $first{$_}->[0];
    (push @trie, $substr), next if @{$first{$_}} == 1;
    my $l = length($substr);
    foreach (@{$first{$_}}) {
      $l-- while substr($_, 0, $l) ne substr($substr, 0, $l);
    }
    $substr = substr $substr, 0, $l;

    # Feed the trie.
    @list = map {substr $_, $l} @{$first{$_}};
    push @trie, [$substr, text_trie_trie(@list)];
  }

  @trie;
}

# This is basically Text::Trie::walkTrie, but it's hardcoded to build
# regular expressions.

sub text_trie_as_regexp {
  my @trie   = @_;
  my $num    = 0;
  my $regexp = '';

  foreach (@trie) {
    $regexp .= '|' if $num++;
    if (ref $_ eq 'ARRAY') {
      $regexp .= $_->[0] . '(?:';

      # If the first tail is empty, make the whole group optional.
      my ($tail, $first);
      if (length $_->[1]) {
        $tail  = ')';
        $first = 1;
      }
      else {
        $tail  = ')?';
        $first = 2;
      }

      # Recurse into the group of tails.
      if ($#$_ > 1) {
        $regexp .= text_trie_as_regexp( @{$_}[$first .. $#$_] );
      }
      $regexp .= $tail;
    }
    else {
      $regexp .= $_;
    }
  }

  $regexp;
}

### End of regexp optimizer.

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

my (%constants, %macros, %const_regexp, %macro);

sub import {

    my $self = shift;
    my %args;
    if(@_ > 1) {
        %args = @_;
    }

    # Outer closure to define a unique scope.
    { my $macro_name = '';
    my ($macro_line, $enum_index);
    my ($package_name, $file_name, $line_number) = (caller)[0,1,2];
    my $const_regexp_dirty = 0;
    my $state = STATE_PLAIN;

    # The following block processes inheritance requests for macros/constants and enums.  added by sungo 09/2001
    my @isas;
     
    if($args{isa}) {
        if(ref $args{isa} eq 'ARRAY') {
            foreach my $isa (@{$args{isa}}) {
                push @isas, $isa;
            }
        } else {
            push @isas, $args{isa};
        }
        foreach my $isa (@isas) {
            eval "use $isa";
            croak "Unable to load $isa : $@" if $@;

            foreach my $const (keys %{$constants{$isa}}) {
                $constants{$package_name}->{$const} = $constants{$isa}->{$const};
                $const_regexp_dirty = 1;
            }

            foreach my $macro (keys %{$macros{$isa}}) {
                $macros{$package_name}->{$macro} = $macros{$isa}->{$macro};
            }
        }
    }

    $conditional_stacks{$package_name} = [ ];
    $excluding_code{$package_name} = 0;

    my $set_const = sub {
      my ($name, $value) = @_;

      if (WARN_DEFINE && exists $constants{$package_name}->{$name}) {
        warn "const $name redefined at $file_name line $line_number\n"
          unless $constants{$package_name}->{$name} eq $value;
      }

      $constants{$package_name}->{$name} = $value;
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
          if (/\#\s*include/) {

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
                $macro{$package_name}->[MAC_CODE] .= $_;
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
                $macro{$package_name}->[MAC_CODE] .= $_;
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
                $macro{$package_name}->[MAC_CODE] .= $_;
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
                warn
                  ( ",-----\n",
                    "| Defined macro $macro_name\n",
                    "| Parameters: ",
                    @{$macro{$package_name}->[MAC_PARAMETERS]}, "\n",
                    "| Code: {\n",
                    $macro{$package_name}->[MAC_CODE],
                    "| }\n",
                    "`-----\n"
                  );

              $macro{$package_name}->[MAC_CODE] =~ s/^\s*//;
              $macro{$package_name}->[MAC_CODE] =~ s/\s*$//;

              if ( WARN_DEFINE &&
                   exists $macros{$package_name}->{$macro_name}
                 ) {
                warn( "macro $macro_name redefined at ",
                      "$file_name line $line_number\n"
                    )
                  if ( $macros{$package_name}->{$macro_name}->[MAC_CODE] ne
                       $macro{$package_name}->[MAC_CODE]
                     );
              }

              $macros{$package_name}->{$macro_name} = $macro{$package_name};

              $macro_name = '';
            }

            # Otherwise append this line to the macro.
            else {
              $macro_line++;
              $macro{$package_name}->[MAC_CODE] .= $_;
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
          if (/^const\s+(\S+)\s+(.+?)\s*$/i) {
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

            $macro{$package_name} =
              [ \@macro_params, # MAC_PARAMETERS
                '',             # MAC_CODE
                $macro_name,    # MAC_NAME
                $file_name,     # MAC_FILE
                $line_number,   # MAC_LINE
              ];

            $_ = "# $temp_line";
            DEBUG and warn sprintf "%4d D: %s", $line_number, $_;
            return $status;
          }

          ### Perform macro substitutions.
          my $substitutions = 0;
          while (/(\{\%\s+(\S+)\s*(.*?)\s*\%\})/gs) {
            my ($name, $params) = ($2, $3);

            # Backtrack to the beginning of the substitution so that
            # the newly inserted text may also be checked.
            pos($_) -= length($1);

            DEBUG_INVOKE and
              warn ",-----\n| macro invocation: $name $params\n";

            if (exists $macros{$package_name}->{$name}) {

              my @use_params = split /\s*\,\s*/, $params;
              my @mac_params =
                @{$macros{$package_name}->{$name}->[MAC_PARAMETERS]};

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
              my $substitution = $macros{$package_name}->{$name}->[MAC_CODE];
              my $macro_file   = $macros{$package_name}->{$name}->[MAC_FILE];
              my $macro_line   = $macros{$package_name}->{$name}->[MAC_LINE];

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
                          "\"macro $name (defined in $macro_file at line " .
                          ($macro_line + $sub_line + 1) . ") " .
                          "invoked from $file_name\""
                        );
                }
                $substitution = join "\n", @sub_lines;
              }

              substr($_, pos($_), length($1)) = $substitution;
              $_ .= "# line " . ($line_number+1) . " \"$file_name\"\n"
                unless $^P;

              DEBUG_INVOKE and warn "$_`-----\n";

              $substitutions++;
            }
            else {
              die( "macro $name has not been defined ",
                   "at $file_name line $line_number\n"
                 );
              last;
            }
          }

          # Only rebuild the constant regexp if necessary.  This
          # prevents redundant regexp rebuilds when defining several
          # constants all together.
          if ($const_regexp_dirty) {
            $const_regexp{$package_name} =
              text_trie_as_regexp
                ( text_trie_trie(keys %{$constants{$package_name}})
                );
            $const_regexp_dirty = 0;
          }

          # Perform constant substitutions.
          if (defined $const_regexp{$package_name}) {
            $substitutions +=
              s[\b($const_regexp{$package_name})\b]
               [$constants{$package_name}->{$1}]sg;
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

# Clear a package's macros.  Used for destructive testing.
sub clear_package {
  my ($self, $package) = @_;
  delete $constants{$package};
  delete $macros{$package};
  delete $const_regexp{$package};
  delete $macro{$package};
}

1;

__END__

=head1 NAME

POE::Preprocessor - a macro/const/enum preprocessor

=head1 SYNOPSIS

  use POE::Preprocessor;

  # use POE::Preprocessor ( isa => 'POE::SomeModule' );

  macro max (one,two) {
    ((one) > (two) ? (one) : (two))
  }

  print {% max $one, $two %}, "\n";

  const PI 3.14159265359

  print "PI\n";  # Substitutions don't grok Perl!

  enum ZERO ONE TWO
  enum 12 TWELVE THIRTEEN FOURTEEN
  enum + FIFTEEN SIXTEEN SEVENTEEN

  print "ZERO ONE TWO TWELVE THIRTEEN FOURTEEN FIFTEEN SIXTEEN SEVENTEEN\n";

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
macro substitution language.  Think of it like compile-time code
templates.

=head2 Macros

Macros are defined with the C<macro> statement.  The syntax is similar
to Perl subs:

  macro macro_name (parameter_0, parameter_1) {
    macro code ... parameter_0 ... parameter_1 ...
  }

The open brace is required to be on the same line as the C<macro>
statement.  The Preprocessor doesn't analyze macro bodies.  Instead,
it assumes that any closing brace in the leftmost column ends an open
macro.

The parameter list is optional for macros that don't accept
parameters.

  macro macro_name {
    macro code;
  }

Macros are substituted into a program with a syntax borrowed from
Iaijutsu and altered slightly to jive with Perl's native syntax.

  {% macro_name $param_1, 'param two' %}

This is the code the first macro would generate:

  macro code ... $param_1 ... 'param two' ...

It's very simplistic.  See POE::Kernel for extensive macro use.

=head2 Constants and Enumerations

The C<const> command defines a constant.

  const CONSTANT_NAME    'constant value'
  const ANOTHER_CONSTANT 23

Enumerations are defined with the C<emun> command.  Enumerations start
from zero by default:

  enum ZEROTH FIRST SECOND ...

If the first parameter of an enumeration is a number, then the
enumerated constants will start with that value:

  enum 10 TENTH ELEVENTH TWELFTH

C<enum> statements may not span lines.  If the first enumeration
parameter is a plus sign, the constants will start where a previous
C<enum> left off.

  enum 13 THIRTEENTH FOURTEENTH  FIFTEENTH
  enum +  SIXTEENTH  SEVENTEENTH EIGHTEENTH

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
same line as the previous block's closing brace, as they are in the
previous example.

Conditional includes are experimental pending a decision on how useful
they are.

=head1 IMPORTING MACROS/CONSTANTS

    use POE::Preprocessor ( isa => 'POE::SomeModule' );

This method of calling Preprocessor causes the macros and constants of 
C<POE::SomeModule> to be imported for use in the current namespace. 
These macros and constants can be overriden simply by defining items 
in the current namespace of the same name.

Note: if the macros in C<POE::SomeModule> require additional perl 
modules, any code which imports these macros will need to C<use> 
those modules as well.

=head1 DEBUGGING

POE::Preprocessor has three debugging constants which may be defined
before the first time POE::Preprocessor is used.

To trace source filtering in general, and to see the resulting code
and operations performed on each line:

  sub POE::Preprocessor::DEBUG () { 1 }

To trace macro invocations as they happen:

  sub POE::Preprocessor::DEBUG_INVOKE () { 1 }

To see macro, constant, and enum definitions:

  sub POE::Preprocessor::DEBUG_DEFINE () { 1 }

To see warnings when a macro or constant is redefined:

  sub POE::Preprocessor::WARN_DEFINE () { 1 }

=head1 BUGS

Source filters are line-based, and so is the macro language.  The only
constructs that may span lines are macro definitions, and those *must*
span lines.

The regular expressions that detect and replace code are simplistic
and may not do the right things when given challenging Perl syntax to
parse.  For example, constants are replaced within strings.

Substitution is done in two phases: macros first, then constants.  It
would be nicer (and more dangerous) if the phases looped around and
around until no more substitutions occurred.

The regexp builder makes silly subexpressions like /(?:|m)/.  That
could be done better as /m?/ or /(?:jklm)?/ if the literal is longer
than a single character.

=head1 SEE ALSO

The regexp optimizer is based on code in Ilya Zakharevich's
Text::Trie.

=head1 AUTHOR & COPYRIGHT

POE::Preprocessor is Copyright 2000 Rocco Caputo.  Some parts are 
Copyright 2001 Matt Cashner. All rights reserved.  POE::Preprocessor 
is free software; you may redistribute it and/or modify it under 
the same terms as Perl itself.

=cut
