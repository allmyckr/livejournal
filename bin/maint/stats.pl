#!/usr/bin/perl
#

$maint{'genstats'} = sub
{
    &connect_db();
    my ($sth);

    print "-I- Getting usage by day in last month...\n";
    my ($nowtime, $time, $nowdate);
    $sth = $dbh->prepare("SELECT UNIX_TIMESTAMP(), DATE_FORMAT(NOW(), '%Y-%m-%d')");
    $sth->execute;
    ($nowtime, $nowdate) = $sth->fetchrow_array;

    print "Date is: $nowdate\n";
    
    for (my $days_back = 30; $days_back > 0; $days_back--) {
	print "  going back $days_back days... ";
	$time = $nowtime - 86400*$days_back;
	$dbh->do("SET \@d=DATE_FORMAT(FROM_UNIXTIME($time), \"%Y-%m-%d\")");
	$sth = $dbh->prepare("SELECT COUNT(*) FROM stats WHERE statcat='postsbyday' AND statkey=\@d");
	$sth->execute;
	my ($exist) = $sth->fetchrow_array;
	if ($exist) {
	    print "exists.\n";
	} else {
	    $sth = $dbh->prepare("SELECT \@d, COUNT(*) FROM log WHERE year=YEAR(\@d) AND month=MONTH(\@d) AND day=DAYOFMONTH(\@d)");
	    $sth->execute;
	    my ($date, $count) = $sth->fetchrow_array;
	    print "$date = $count entries\n";
	    $count += 0;
	    $dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ('postsbyday', \@d, $count)");	    
	}

    }

#    print "-I- Getting usage by week...\n";

    print "-I- Getting user stats...\n";


    my %account;
    my %userinfo;
    my %age;
    my %newbyday;
    my $now = time();
    my $count;
    $sth = $dbh->prepare("SELECT COUNT(*) FROM user");
    $sth->execute;
    my ($usertotal) = $sth->fetchrow_array;
    my $pagesize = 1000;
    my $pages = int($usertotal / $pagesize) + (($usertotal % $pagesize) ? 1 : 0);
    
    for (my $page=0; $page < $pages; $page++)
    {
	my $skip = $page*$pagesize;
	my $first = $skip+1;
	my $last = $skip+$pagesize;
	print "  getting records $first-$last...\n";
	$sth = $dbh->prepare("SELECT DATE_FORMAT(timecreate, '%Y-%m-%d') AS 'datereg', user, paidfeatures, FLOOR((TO_DAYS(NOW())-TO_DAYS(bdate))/365.25) AS 'age', UNIX_TIMESTAMP(timeupdate) AS 'timeupdate', status, allow_getljnews, allow_getpromos FROM user LIMIT $skip,$pagesize");
	$sth->execute;
	while (my $rec = $sth->fetchrow_hashref)
	{
	    my $co = $rec->{'country'};
	    if ($co) {
		$country{$co}++; 
		if ($co eq "US" && $rec->{'state'}) {
		    $stateus{$rec->{'state'}}++;
		}
	    }
	    
	    $account{$rec->{'paidfeatures'}}++;

	    unless ($rec->{'datereg'} eq $nowdate) {
		$newbyday{$rec->{'datereg'}}++;
	    }

	    if ($rec->{'age'} > 4 && $rec->{'age'} < 110) {
		$age{$rec->{'age'}}++;
	    }
	    
	    $userinfo{'total'}++;
	    $time = $rec->{'timeupdate'};
	    $userinfo{'updated'}++ if ($time);
	    $userinfo{'updated_last30'}++ if ($time > $now-60*60*24*30);
	    $userinfo{'updated_last7'}++ if ($time > $now-60*60*24*7);
	    $userinfo{'updated_last1'}++ if ($time > $now-60*60*24*1);
	    
	    if ($rec->{'status'} eq "A")
	    {
		for (qw(allow_getljnews allow_getpromos))
		{
		    $userinfo{$_}++ if ($rec->{$_} eq "Y");
		}
	    }
	    
	}
    }

    print "-I- Countries.\n";
    my %country;
    $sth = $dbh->prepare("SELECT value, COUNT(*) AS 'count' FROM userprop WHERE upropid=3 AND value<>'' GROUP BY 1 ORDER BY 2");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$country{$_->{'value'}} = $_->{'count'};
    }

    print "-I- US States.\n";
    my %stateus;
    $sth = $dbh->prepare("SELECT ua.value, COUNT(*) AS 'count' FROM userprop ua, userprop ub WHERE ua.userid=ub.userid AND ua.upropid=4 and ub.upropid=3 and ub.value='US' AND ub.value<>'' GROUP BY 1 ORDER BY 2");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$stateus{$_->{'value'}} = $_->{'count'};
    }


    print "-I- Gender.\n";
    my %gender;
    $sth = $dbh->prepare("SELECT up.value, COUNT(*) AS 'count' FROM userprop up, userproplist upl WHERE up.upropid=upl.upropid AND upl.name='gender' GROUP BY 1");
    $sth->execute;
    while ($_ = $sth->fetchrow_hashref) {
	$gender{$_->{'value'}} = $_->{'count'};
    }

    
    my %to_pop = ("userinfo" => \%userinfo,
		  "country" => \%country,
		  "stateus" => \%stateus,
		  "age" => \%age,
		  "gender" => \%gender,
		  "account" => \%account,
		  "newbyday" => \%newbyday,
		  );
    
    foreach my $cat (keys %to_pop)
    {
	print "  dumping $cat stats\n";
	my $qcat = $dbh->quote($cat);
	$dbh->do("DELETE FROM stats WHERE statcat=$qcat");
	if ($dbh->err) { die $dbh->errstr; }
	foreach (sort keys %{$to_pop{$cat}}) {
	    my $qkey = $dbh->quote($_);
	    my $qval = $to_pop{$cat}->{$_}+0;
	    $dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ($qcat, $qkey, $qval)");
	    if ($dbh->err) { die $dbh->errstr; }
	}
    }

    #### client usage stats

    print "-I- Clients.\n";
    $sth = $dbh->prepare("SELECT client, COUNT(*) AS 'count' FROM logins WHERE lastlogin > DATE_SUB(NOW(), INTERVAL 30 DAY) GROUP BY 1 ORDER BY 2");
    $sth->execute;

    $dbh->do("DELETE FROM stats WHERE statcat='client'");
    while ($_ = $sth->fetchrow_hashref) {
	my $qkey = $dbh->quote($_->{'client'});
	my $qval = $_->{'count'}+0;
	$dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ('client', $qkey, $qval)");
    }

#    print "-I- Overall Active Users\n";
#    $sth = $dbh->prepare("SELECT u.user, count(*) AS 'count' FROM log l, user u WHERE l.ownerid=u.userid AND u.user NOT LIKE 'test%' GROUP BY user ORDER BY 2 DESC LIMIT 15");
#    $sth->execute;

#    print "-I- Last Week Active Users\n";
#    $sth = $dbh->prepare("SELECT u.user, count(*) AS 'count' FROM log  l, user u WHERE l.ownerid=u.userid AND user NOT LIKE 'test%' AND logtime > DATE_SUB(NOW(), INTERVAL 7 DAY) GROUP BY user ORDER BY 2 DESC LIMIT 15");
#    $sth->execute;

    #### dump to text file
    print "-I- Dumping to a text file.\n";

    $sth = $dbh->prepare("SELECT statcat, statkey, statval FROM stats ORDER BY 1, 2");
    $sth->execute;
    open (OUT, ">$LJ::HTDOCS/stats/stats.txt");
    while (@_ = $sth->fetchrow_array) {
	print OUT join("\t", @_), "\n";
    }
    close OUT;

    #### do stat box stuff
    print "-I- Preparing stat box overviews.\n";
    my %statbox;
    my $v;

    ## total users
    $sth = $dbh->prepare("SELECT statval FROM stats WHERE statcat='userinfo' AND statkey='total'");
    $sth->execute;
    ($v) = $sth->fetchrow_array;
    $statbox{'totusers'} = $v;
    
    ## how many posts yesterday
    $sth = $dbh->prepare("SELECT statval FROM stats WHERE statcat='postsbyday' ORDER BY statkey DESC LIMIT 1");
    $sth->execute;
    ($v) = $sth->fetchrow_array;
    $statbox{'postyester'} = $v;

    foreach my $k (keys %statbox) {
	my $qk = $dbh->quote($k);
	my $qv = $dbh->quote($statbox{$k});
	$dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ('statbox', $qk, $qv)");
    }

    print "-I- Done.\n";

};

$maint{'genstats_weekly'} = sub
{
    &connect_db();
    my ($sth);
    my %supportrank;

    print "-I- Support rank.\n";
    $sth = $dbh->prepare("SELECT u.userid, SUM(sp.points) AS 'points' FROM user u, supportpoints sp WHERE u.userid=sp.userid GROUP BY 1 ORDER BY 2 DESC");
    my $rank = 0;
    my $lastpoints = 0;
    my $buildup = 0;
    $sth->execute;
    {
	while ($_ = $sth->fetchrow_hashref) 
	{
	    if ($lastpoints != $_->{'points'}) {
		$lastpoints = $_->{'points'};
		$rank += (1 + $buildup);
		$buildup = 0;
	    } else {
		$buildup++;
	    }
	    $supportrank{$_->{'userid'}} = $rank;
	}
    }

    $dbh->do("DELETE FROM stats WHERE statcat='supportrank_prev'");
    $dbh->do("UPDATE stats SET statcat='supportrank_prev' WHERE statcat='supportrank'");

    my %to_pop = (
		  "supportrank" => \%supportrank,
		  );
    
    foreach my $cat (keys %to_pop)
    {
	print "  dumping $cat stats\n";
	my $qcat = $dbh->quote($cat);
	$dbh->do("DELETE FROM stats WHERE statcat=$qcat");
	if ($dbh->err) { die $dbh->errstr; }
	foreach (sort keys %{$to_pop{$cat}}) {
	    my $qkey = $dbh->quote($_);
	    my $qval = $to_pop{$cat}->{$_}+0;
	    $dbh->do("REPLACE INTO stats (statcat, statkey, statval) VALUES ($qcat, $qkey, $qval)");
	    if ($dbh->err) { die $dbh->errstr; }
	}
    }

};

$maint{'build_randomuserset'} = sub
{
    ## this sets up the randomuserset table daily (or whenever) that htdocs/random.bml uses to
    ## find a random user that is both 1) publicly listed in the directory, and 2) updated
    ## within the past 24 hours.

    ## note that if a user changes their privacy setting to not be in the database, it'll take
    ## up to 24 hours for them to be removed from the random.bml listing, but that's acceptable.

    &connect_db();
    print "-I- Building randomuserset.\n";
    $dbh->do("REPLACE INTO randomuserset (userid, timeupdate) SELECT userid, timeupdate FROM user WHERE allow_infoshow='Y' AND timeupdate > DATE_SUB(NOW(), INTERVAL 1 DAY)");
    $dbh->do("DELETE FROM randomuserset WHERE timeupdate < DATE_SUB(NOW(), INTERVAL 1 DAY)");
    print "-I- Done.\n";
};

1;
