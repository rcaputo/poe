# $Id$

# Data and methods to manage performance metrics, allowing clients to
# look at how much work their POE server is performing.
# None of this stuff will activate unless TRACE_PERFORMANCE or
# TRACE_PROFILE are enabled.
#
# Most of this is 

package POE::Resources::Performance;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision$=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

# We fold all this stuff back into POE::Kernel
package POE::Kernel;

use strict;

# We keep a number of metrics (idle time, user time, etc).
# Every tick (by default 30secs), we compute the rolling average
# of those metrics. The rolling average is computed based on
# the number of readings specified in $_perf_window_size.

my $_perf_metrics     = []; # the data itself
my $_perf_interval    = 30; # how frequently we take readings
my $_perf_window_size = 4;  # how many readings we average across
my $_perf_wpos        = 0;  # where to currrently write metrics (circ. buffer)
my $_perf_rpos        = 0;  # where to currrently write metrics (circ. buffer)
my %average;

# This is for collecting event frequencies if TRACE_PROFILE is
# enabled.
my %profile;

sub _data_perf_initialize {
    my ($self) = @_;
    $self->_data_perf_reset;
    $self->_data_ev_enqueue(
      $self, $self, EN_PERF, ET_PERF, [ ],
      __FILE__, __LINE__, time() + $_perf_interval
    );
}

sub _data_perf_finalize {
    my ($self) = @_;

    if (TRACE_PERFORMANCE) {
      POE::Kernel::_warn('<pr> ,----- Performance Data ' , ('-' x 50), ",\n");
      foreach (sort keys %average) {
          next if /epoch/;
          POE::Kernel::_warn(
            sprintf "<pr> | %60.60s %9.1f  |\n", $_, $average{$_}
          );
      }

      unless (keys %average) {
          POE::Kernel::_warn '<pr> `', ('-' x 73), "'\n";
          return;
      }

      # Division by zero sucks.
      $average{blocked}     ||= 0;
      $average{user_events} ||=1;

      POE::Kernel::_warn(
        '<pr> +----- Derived Performance Metrics ', ('-' x 39), "+\n",
        sprintf(
          "<pr> | %60.60s %9.1f%% |\n",
          'idle', 100 * $average{idle_seconds} / $average{interval}
        ),
        sprintf(
          "<pr> | %60.60s %9.1f%% |\n",
          'user', 100 * $average{user_seconds} / $average{interval}
        ),
        sprintf(
          "<pr> | %60.60s %9.1f%% |\n",
          'blocked', 100 * $average{blocked} / $average{user_events}
        ),
        sprintf(
          "<pr> | %60.60s %9.1f  |\n",
          'user load', $average{user_events} / $average{interval}
        ),
        '<pr> `', ('-' x 73), "'\n"
      );
    }

    if (TRACE_PROFILE) {
      perf_show_profile();
    }
}

sub _data_perf_add {
    my ($self, $key, $count) = @_;
    $_perf_metrics->[$_perf_wpos] ||= {};
    $_perf_metrics->[$_perf_wpos]->{$key} += $count;
}

sub _data_perf_tick {
    my ($self) = @_;

    my $pos = $_perf_rpos;
    $_perf_wpos = ($_perf_wpos+1) % $_perf_window_size;
    if ($_perf_wpos == $_perf_rpos) {
	$_perf_rpos = ($_perf_rpos+1) % $_perf_window_size;
    }

    my $count = 0;
    %average = ();
    while ($count < $_perf_window_size && $_perf_metrics->[$pos]->{epoch}) {
	while (my ($k,$v) = each %{$_perf_metrics->[$pos]}) {
	    next if $k eq 'epoch';
	    $average{$k} += $v;
	}
	$count++;
	$pos = ($pos+1) % $_perf_window_size;
    }

    if ($count) {
	map { $average{$_} /= $count } keys %average;
	$average{interval} = $_perf_interval;
    }

    $self->_data_perf_reset;
    $self->_data_ev_enqueue(
      $self, $self, EN_PERF, ET_PERF, [ ],
      __FILE__, __LINE__, time() + $_perf_interval
    ) if $self->_data_ses_count() > 1;
}

sub _data_perf_reset {
    $_perf_metrics->[$_perf_wpos] = {
      epoch => time,
      idle_seconds => 0,
      user_seconds => 0,
      kern_seconds => 0,
    };
}

# Profile this event.

sub _perf_profile {
  my ($self, $event) = @_;
  $profile{$event}++;
}

# Public routines...

sub perf_getdata {
    return %average;
}

sub perf_show_profile {
  POE::Kernel::_warn('<pr> ,----- Event Profile ' , ('-' x 53), ",\n");
  foreach (sort keys %profile) {
    POE::Kernel::_warn(
      sprintf "<pr> | %60.60s %9d  |\n", $_, $profile{$_}
    );
  }
  POE::Kernel::_warn '<pr> `', ('-' x 73), "'\n";
}

1;
