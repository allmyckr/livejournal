#!/usr/bin/perl
#

package Apache::SendStats;

BEGIN {
    $LJ::HAVE_AVAIL = eval "use Apache::Availability qw(count_servers); 1;";
}

use strict;
use IO::Socket::INET;
use Apache::Constants qw(:common);
use Socket qw(SO_BROADCAST);

use vars qw(%udp_sock);

sub handler
{
    my $r = shift;
    return OK if $r->main;
    return OK unless $LJ::HAVE_AVAIL && $LJ::FREECHILDREN_BCAST;

    my $callback = $r->current_callback() if $r;
    my $cleanup = $callback eq "PerlCleanupHandler";
    my $childinit = $callback eq "PerlChildInitHandler";

    if ($LJ::TRACK_URL_ACTIVE)
    {
        my $key = "url_active:$LJ::SERVER_NAME:$$";
        if ($cleanup) {
            LJ::MemCache::delete($key);
        } else {
            LJ::MemCache::set($key, $r->uri . "(" . $r->method . "/" . scalar($r->args) . ")");
          }
    }

    my ($active, $free) = count_servers();

    $free += $cleanup;
    $free += $childinit;
    $active -= $cleanup if $active;

    my $list = ref $LJ::FREECHILDREN_BCAST ?
        $LJ::FREECHILDREN_BCAST : [ $LJ::FREECHILDREN_BCAST ];

    foreach my $host (@$list) {
        next unless $host =~ /^(\S+):(\d+)$/;
        my $bcast = $1;
        my $port = $2;
        my $sock = $udp_sock{$host};
        unless ($sock) {
            $udp_sock{$host} = $sock = IO::Socket::INET->new(Proto => 'udp');
            if ($sock) {
                $sock->sockopt(SO_BROADCAST, 1)
                    if $LJ::SENDSTATS_BCAST;
            } else {
                $r->log_error("SendStats: couldn't create socket: $host");
                next;
            }
        }

        my $ipaddr = inet_aton($bcast);
        my $portaddr = sockaddr_in($port, $ipaddr);
        my $message = "bcast_ver=1\nfree=$free\nactive=$active\n";
        my $res = $sock->send($message, 0, $portaddr);
        $r->log_error("SendStats: couldn't broadcast")
            unless $res;
    }

    return OK;
}

1;
