#!/usr/bin/perl
#

use strict;
package LJ::S2;

sub YearPage
{
    my ($u, $remote, $opts) = @_;

    my $p = Page($u, $opts->{'vhost'});
    $p->{'_type'} = "YearPage";
    $p->{'view'} = "archive";
    $p->{'weekdays'} = [ 1..7 ];

    my $dbs = LJ::get_dbs();
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $dbcr;
    if ($u->{'clusterid'}) {
        $dbcr = LJ::get_cluster_reader($u);
    }
    my $user = $u->{'user'};

    if ($u->{'journaltype'} eq "R" && $u->{'renamedto'} ne "") {
        $opts->{'redir'} = LJ::journal_base($u->{'renamedto'}, $opts->{'vhost'}) .
            "/calendar" . $opts->{'pathextra'};
        return 1;
    }

    if ($u->{'opt_blockrobots'}) {
        $p->{'head_content'} = "<meta name=\"robots\" content=\"noindex\" />\n";
    }
    if ($LJ::UNICODE) {
        $p->{'head_content'} .= '<meta http-equiv="Content-Type" content="text/html; charset='.$opts->{'saycharset'}."\" />\n";
    }

    my %FORM = ();
    LJ::decode_url_string($opts->{'args'}, \%FORM);

    my $count = LJ::S2::get_journal_day_counts($p);
    my @years = sort { $a <=> $b } keys %$count;
    my $maxyear = @years ? $years[-1] : undef;
    my $year = $FORM{'year'};  # old form was /users/<user>/calendar?year=1999

    # but the new form is purtier:  */calendar/2001
    if (! $year && $opts->{'pathextra'} =~ m!^/(\d\d\d\d)/?\b!) {
        $year = $1;
    }

    # else... default to the year they last posted.
    $year ||= $maxyear;  

    $p->{'year'} = $year;
    $p->{'years'} = [];
    foreach (@years) {
        push @{$p->{'years'}}, YearYear($_, "$p->{'base_url'}/calendar/$_", $_ == $p->{'year'});
    }

    $p->{'months'} = [];

    for my $month (1..12) {
        push @{$p->{'months'}}, YearMonth($p, {
            'month' => $month,
            'year' => $year,
        });
    }

    return $p;
}

sub YearMonth {
    my ($p, $calmon) = @_;

    my ($month, $year) = ($calmon->{'month'}, $calmon->{'year'});
    $calmon->{'_type'} = 'YearMonth';
    $calmon->{'weeks'} = [];
    $calmon->{'url'} = sprintf("$p->{'_u'}->{'_journalbase'}/$year/%02d/", $month);

    my $count = LJ::S2::get_journal_day_counts($p);
    my $has_entries = $count->{$year} && $count->{$year}->{$month} ? 1 : 0;
    $calmon->{'has_entries'} = $has_entries;

    my $start_monday = 0;  # FIXME: check some property to see if weeks start on monday
    my $week = undef;

    my $flush_week = sub {
        my $end_month = shift;
        return unless $week;
        push @{$calmon->{'weeks'}}, $week;
        if ($end_month) {
            $week->{'post_empty'} = 
                7 - $week->{'pre_empty'} - @{$week->{'days'}};
        }
        $week = undef;
    };

    my $push_day = sub {
        my $d = shift;
        unless ($week) {
            my $leading = $d->{'date'}->{'_dayofweek'}-1;
            if ($start_monday) {
                $leading = 6 if --$leading < 0;
            }
            $week = {
                '_type' => 'YearWeek',
                'days' => [],
                'pre_empty' => $leading,
                'post_empty' => 0,
            };
        }
        push @{$week->{'days'}}, $d;
        if ($week->{'pre_empty'} + @{$week->{'days'}} == 7) {
            $flush_week->();
            my $size = scalar @{$calmon->{'weeks'}};
        }
    };

    my $day_of_week = LJ::day_of_week($year, $month, 1);

    my $daysinmonth = LJ::days_in_month($month, $year);

    for my $day (1..$daysinmonth) {
        # so we don't auto-vivify years/months
        my $daycount = $has_entries ? $count->{$year}->{$month}->{$day} : 0;
        my $d = YearDay($p->{'_u'}, $year, $month, $day, 
                        $daycount, $day_of_week+1);
        $push_day->($d);
        $day_of_week = ($day_of_week + 1) % 7;
    }
    $flush_week->(1); # end of month flag
 
    return $calmon;
}

sub YearYear {
    my ($year, $url, $displayed) = @_;
    return { '_type' => "YearYear",
             'year' => $year, 'url' => $url, 'displayed' => $displayed };
}

sub YearDay {
    my ($u, $year, $month, $day, $count, $dow) = @_;
    my $d = {
        '_type' => 'YearDay',
        'day' => $day,
        'date' => Date($year, $month, $day, $dow),
        'num_entries' => $count
    };
    if ($count) {
        $d->{'url'} = sprintf("$u->{'_journalbase'}/$year/%02d/%02d/",
                              $month, $day);
    }
    return $d;
}

1;
