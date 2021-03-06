#!/usr/bin/perl
#

package Apache::DebateSuicide;

use strict;
use Class::Autouse qw(
                      LJ::ModuleCheck
                      );

use vars qw($gtop);
our %known_parent;
our $ppid;

$LJ::SUICIDE_MAX_VIRTUAL_SIZE = 1.5 * 1024*1024*1024; ## 1.5 Gb 

# oh btw, this is totally linux-specific.  gtop didn't work, so so much for portability.
sub handler
{
    my $r = shift;
    LJ::Request->init($r) unless LJ::Request->is_inited;
    
    ## TODO: why is that? shouldn't we process sub-requests as well
    return LJ::Request::OK if LJ::Request->main;
    return LJ::Request::OK unless $LJ::SUICIDE && LJ::ModuleCheck->have("GTop");

    $gtop ||= GTop->new;
    my $pm = $gtop->proc_mem($$);
    my $size = $pm->size;
    if ($size > $LJ::SUICIDE_MAX_VIRTUAL_SIZE) {
        my $host = LJ::Request->header_in("Host");
        my $uri  = LJ::Request->uri; 
        terminate(sprintf("i'm too big (%0.3f Gb), url=http://$host/$uri", $size/1024/1024/1024));
    } 

    my $meminfo;
    return LJ::Request::OK unless open (MI, "/proc/meminfo");
    $meminfo = join('', <MI>);
    close MI;

    my %meminfo;
    while ($meminfo =~ m/(\w+):\s*(\d+)\skB/g) {
        $meminfo{$1} = $2;
    }

    my $memfree = $meminfo{'MemFree'} + $meminfo{'Cached'};
    return LJ::Request::OK unless $memfree;

    my $goodfree = $LJ::SUICIDE_UNDER{$LJ::SERVER_NAME} || $LJ::SUICIDE_UNDER ||   150_000;
    my $is_under = $memfree < $goodfree;

    my $maxproc  = $LJ::SUICIDE_OVER{$LJ::SERVER_NAME}  || $LJ::SUICIDE_OVER  || 1_000_000;
    my $is_over  = 0;


    # if $is_under, we know we'll be exiting anyway, so no need
    # to continue to check $maxproc
    unless ($is_under) {
        # find out how much memory we are using
        my $proc_size_k = ($pm->rss - $pm->share) >> 10; # config is in KB
        $is_over = $proc_size_k > $maxproc;
    }
    return LJ::Request::OK unless $is_over || $is_under;

    # we'll proceed to die if we're one of the largest processes
    # on this machine

    unless ($ppid) {
        my $self = pid_info($$);
        $ppid = $self->[3];
    }

    my $pids = child_info($ppid);
    my @pids = keys %$pids;

    my %stats;
    my $sum_uniq = 0;
    foreach my $pid (@pids) {
        my $pm = $gtop->proc_mem($pid);
        $stats{$pid} = [ $pm->rss - $pm->share, $pm ];
        $sum_uniq += $stats{$pid}->[0];
    }

    @pids = (sort { $stats{$b}->[0] <=> $stats{$a}->[0] } @pids, 0, 0);

    if (grep { $$ == $_ } @pids[0,1]) {
        my $my_use_k = $stats{$$}[0] >> 10;
        terminate("system memory free = ${memfree}k; i'm big, using ${my_use_k}k");
    }

    return LJ::Request::OK;
}

sub terminate {
    my $message = shift;

    LJ::Request->log_error("Suicide [$$]: $message");

    # we should have logged by here, but be paranoid in any case
    Apache::LiveJournal::db_logger() unless LJ::Request->pnotes('did_lj_logging');

    # This is supposed to set MaxChildRequests to 1, then clear the
    # KeepAlive flag so that Apache will terminate after this request,
    # but it doesn't work.  We'll call it here just in case.
    LJ::Request->child_terminate;

    # We should call Apache::exit(Apache::Constants::DONE) here because
    # it makes sure that the child shuts down cleanly after fulfilling
    # its request and running logging handlers, etc.
    #
    # In practice Apache won't exit until the current request's KeepAlive
    # timeout is reached, so the Apache hangs around for the configured
    # amount of time before exiting.  Sinced we know that the request
    # is done and we've verified that logging as happend (above), we'll
    # just call CORE::exit(0) which works immediately.
    CORE::exit(0);
}

sub pid_info {
    my $pid = shift;

    open (F, "/proc/$pid/stat") or next;
    $_ = <F>;
    close(F);
    my @f = split;
    return \@f;
}

sub child_info {
    my $ppid = shift;
    opendir(D, "/proc") or return undef;
    my @pids = grep { /^\d+$/ } readdir(D);
    closedir(D);

    my %ret;
    foreach my $p (@pids) {
        next if (defined $known_parent{$p} &&
                 $known_parent{$p} != $ppid);
        my $ary = pid_info($p);
        my $this_ppid = $ary->[3];
        $known_parent{$p} = $this_ppid;
        next unless $this_ppid == $ppid;
        $ret{$p} = $ary;
    }
    return \%ret;
}

1;
