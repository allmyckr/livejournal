#!/usr/bin/perl

#
# Partial Stats
#

use strict;

package LJ::Stats;

%LJ::Stats::INFO = (
                    # jobname => { type => 'global' || 'clustered',
                    #              jobname => jobname
                    #              statname => statname || [statname1, statname2]
                    #              handler => sub {},
                    #              max_age => age }
                    );

sub LJ::Stats::register_stat {
    my $stat = shift;
    return undef unless ref $stat eq 'HASH';

    $stat->{'type'} = $stat->{'type'} eq 'clustered' ? 'clustered' : 'global';
    return undef unless $stat->{'jobname'};
    $stat->{'statname'} ||= $stat->{'jobname'};
    return undef unless ref $stat->{'handler'} eq 'CODE';
    delete $stat->{'max_age'} unless $stat->{'max_age'} > 0;

    # register in master INFO hash
    $LJ::Stats::INFO{$stat->{'jobname'}} = $stat;

    return 1;
};

sub LJ::Stats::run_stats {
    my @stats = @_ ? @_ : sort keys %LJ::Stats::INFO;

    foreach my $jobname (@stats) {

        my $stat = $LJ::Stats::INFO{$jobname};

        # stats calculated on global db reader
        if ($stat->{'type'} eq "global") {
            unless (LJ::Stats::need_calc($jobname)) {
                print "-I- Up-to-date: $jobname\n";
                next;
            }

            my $dbr = LJ::Stats::get_db("dbr");
            die "Can't get db reader handle."
                unless $dbr;

            print "-I- Running: $jobname\n";

            my $res = $stat->{'handler'}->($dbr);
            die "Error running '$jobname' handler on global reader."
                unless $res;

            # 2 cases:
            # - 'statname' is an arrayref, %res structure is ( 'statname' => { 'arg' => 'val' } )
            # - 'statname' is scalar, %res structure is ( 'arg' => 'val' )
            {
                if (ref $stat->{'statname'} eq 'ARRAY') {
                    foreach my $statname (@{$stat->{'statname'}}) {
                        foreach my $key (keys %{$res->{$statname}}) {
                            LJ::Stats::save_stat($statname, $key, $res->{$statname}->{$key});
                        }
                    }
                } else {
                    my $statname = $stat->{'statname'};
                    foreach my $key (keys %$res) {
                        LJ::Stats::save_stat($statname, $key, $res->{$key});
                    }
                }
            }

            LJ::Stats::save_calc($jobname);

            next;
        }

        # stats calculated per-cluster
        if ($stat->{'type'} eq "clustered") {

            foreach my $cid (@LJ::CLUSTERS) {
                unless (LJ::Stats::need_calc($jobname, $cid)) {
                    print "-I- Up-to-date: $jobname, cluster $cid\n";
                    next;
                }

                my $dbcr = LJ::Stats::get_db("dbcr", $cid);
                die "Can't get cluster $cid db handle."
                    unless $dbcr;

                print "-I- Running: $jobname, cluster $cid\n";

                my $res = $stat->{'handler'}->($dbcr, $cid);
                die "Error running '$jobname' handler on cluster $cid."
                    unless $res;

                # 2 cases:
                # - 'statname' is an arrayref, %res structure is ( 'statname' => { 'arg' => 'val' } )
                # - 'statname' is scalar, %res structure is ( 'arg' => 'val' )
                {
                    if (ref $stat->{'statname'} eq 'ARRAY') {
                        foreach my $statname (@{$stat->{'statname'}}) {
                            foreach my $key (keys %{$res->{$statname}}) {
                                LJ::Stats::save_part($statname, $cid, $key, $res->{$statname}->{$key});
                            }
                        }
                    } else {
                        my $statname = $stat->{'statname'};
                        foreach my $key (keys %$res) {
                            LJ::Stats::save_part($statname, $cid, $key, $res->{$key});
                          }
                    }
                }

                LJ::Stats::save_calc($jobname, $cid);
            }

            # save the summation(s) of the statname(s) we found above
            if (ref $stat->{'statname'} eq 'ARRAY') {
                foreach my $statname (@{$stat->{'statname'}}) {
                    LJ::Stats::save_sum($statname);
                }
            } else {
                LJ::Stats::save_sum($stat->{'statname'});
            }
        }
        
    }

    return 1;
};

# get raw dbr/dbh/cluster handle
sub LJ::Stats::get_db {
    my $type = shift;
    return undef unless $type;
    my $cid = shift;

    # global handles
    if ($type eq "dbr") {
        my @roles = $LJ::STATS_FORCE_SLOW ? ("slow") : ("slave", "master");
        my $db = LJ::get_dbh({raw=>1}, @roles);
        return $db if $db;
            
        # don't fall back to slave/master if STATS_FORCE_SLOW is on
        die "ERROR: Could not get handle for slow database role\n"
            if $LJ::STATS_FORCE_SLOW;

        return undef;
    }

    return LJ::get_dbh({raw=>1}, 'master')
        if $type eq "dbh";

    # cluster handles
    return undef unless $cid > 0;
    return LJ::get_cluster_master($cid)
        if $type eq "dbcm";
    return LJ::get_cluster_reader($cid)
        if $type eq "dbcr";

    return undef;
}

# save a given stat to the 'stats' table in the db
sub LJ::Stats::save_stat {
    my ($cat, $statkey, $val) = @_;
    return undef unless $cat && $statkey && $val;

    # replace/insert stats row
    my $dbh = LJ::Stats::get_db("dbh");
    $dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES (?, ?, ?)",
             undef, $cat, $statkey, $val);
    die $dbh->errstr if $dbh->err;

    return 1;
}

# note the last calctime of a given stat
sub LJ::Stats::save_calc {
    my ($jobname, $cid) = @_;
    return unless $jobname;

    my $dbh = LJ::Stats::get_db("dbh");
    $dbh->do("REPLACE INTO partialstats (jobname, clusterid, calctime) " .
             "VALUES (?,?,UNIX_TIMESTAMP())", undef, $jobname, $cid || 1);
    die $dbh->errstr if $dbh->err;

    return 1;
}

# save partial stats
sub LJ::Stats::save_part {
    my ($statname, $cid, $arg, $value) = @_;
    return undef unless $statname && $cid > 0;

    # replace/insert partialstats(data) row
    my $dbh = LJ::Stats::get_db("dbh");
    $dbh->do("REPLACE INTO partialstatsdata (statname, arg, clusterid, value) " .
             "VALUES (?,?,?,?)", undef, $statname, $arg, $cid, $value);
    die $dbh->errstr if $dbh->err;

    return 1;
};

# see if a given stat is stale
sub LJ::Stats::need_calc {
    my ($jobname, $cid) = @_;
    return undef unless $jobname;

    my $dbr = LJ::Stats::get_db("dbr");
    my $calctime = $dbr->selectrow_array("SELECT calctime FROM partialstats " .
                                         "WHERE jobname=? AND clusterid=?",
                                         undef, $jobname, $cid || 1);

    my $max = $LJ::Stats::INFO{$jobname}->{'max_age'} || 3600*6; # 6 hours default
    return ($calctime < time() - $max);
}

# sum up counts for all clusters
sub LJ::Stats::save_sum {
    my $statname = shift;
    return undef unless $statname;

    # get sum of this stat for all clusters
    my $dbr = LJ::Stats::get_db("dbr");
    my $sth = $dbr->prepare("SELECT arg, SUM(value) FROM partialstatsdata " .
                            "WHERE statname=? GROUP BY 1");
    $sth->execute($statname);
    while (my ($arg, $count) = $sth->fetchrow_array) {
        next unless $count;
        LJ::Stats::save_stat($statname, $arg, $count);
    }

    return 1;
}

# get number of pages, given a total row count
sub LJ::Stats::num_blocks {
    my $row_tot = shift;
    return 0 unless $row_tot;

    return int($row_tot / $LJ::STATS_BLOCK_SIZE) + (($row_tot % $LJ::STATS_BLOCK_SIZE) ? 1 : 0);
}

# get low/high ids for a BETWEEN query based on page number
sub LJ::Stats::get_block_bounds {
    my $block = shift;
    return (0, $LJ::Stats::BLOC_SIZE) unless $block;

    return (($block-1) * $LJ::STATS_BLOCK_SIZE, $block * $LJ::STATS_BLOCK_SIZE+1);
}

sub LJ::Stats::block_status_line {
    my ($block, $total) = @_;
    return "" if $total == 1; # who cares about percentage for one block?

    # status line gets called AFTER work is done, so we show percentage
    # for $block+1, that way the final line displays 100%
    my $pct = sprintf("%.2f", 100*($block / ($total || 1)));
    return "    [$pct%] Processing block $block of $total.\n";
}

1;
