#!/usr/bin/perl
#
# Moves a user between clusters.
#

use strict;
require "$ENV{'LJHOME'}/cgi-bin/ljlib.pl";

my $dbh = LJ::get_dbh("master");

my $user = shift @ARGV;
my $dclust = shift @ARGV;

sub usage {
    die "Usage:\n  movecluster.pl <user> <destination cluster #>\n";
}

usage() unless $user;
usage() unless $dclust;

my $u = LJ::load_user($dbh, $user);
die "Non-existent user $user.\n" unless $u;

my $dbch = LJ::get_dbh("cluster$dclust!");
die "Undefined or down cluster \#$dclust\n" unless $dbch;

my $sclust = $u->{'clusterid'};

if ($sclust == $dclust) {
    die "User '$user' is already on cluster $dclust\n";
}

if ($sclust) {
    # TODO: intra-cluster moving we can deal with later.
    die "Moving between clusters isn't yet supported; only from cluster 0 to somewhere else.\n";
}

my $userid = $u->{'userid'};
print "Moving '$u->{'user'}' from cluster $sclust to $dclust:\n";
print "dbh = $dbh; dbch = $dbch\n";

my $recentpoint;
if ($LJ::USE_RECENT_TABLES) {
    $recentpoint = $dbh->selectrow_array("SELECT DATE_SUB(NOW(), INTERVAL $LJ::RECENT_DAYS DAY)");
}

# TODO: find readonly cap class, complain if not found
# TODO: set readonly cap bit on user
# TODO: record in table clustermoves: (userid, sclust, dclust, stime, status('IP','DONE'), ftime)
# TODO: wait 5 seconds?  for writes to stop?

$dbh->{'RaiseError'} = 1;
$dbch->{'RaiseError'} = 1;

my $last = time();
my $stmsg = sub {
    my $msg = shift;
    my $now = time();
    return if ($now < $last + 1);
    $last = $now;
    print $msg;
};

# check main tables on destination cluster for pre-existing data.  note that we
# don't check *text or *prop, etc... as those don't impact display of data, they
# only waste space.  but nothing should be there anyway, only if something's really
# fucked, so this'll catch that case and prevent possible screwup:
#die "Data in destination cluster's 'log2'\n" if
#    $dbch->selectrow_array("SELECT COUNT(*) FROM log2 WHERE journalid=$userid");
#die "Data in destination cluster's 'talk2'\n" if
#    $dbch->selectrow_array("SELECT COUNT(*) FROM talk2 WHERE journalid=$userid");

if ($sclust == 0) 
{
    my @itemids = reverse @{$dbh->selectcol_arrayref("SELECT itemid FROM log ".
						     "WHERE ownerid=$u->{'userid'} ".
						     "ORDER BY ownerid, rlogtime")};

    my $todo = @itemids;
    my $done = 0;
    my $stime = time();
    print "Total: $todo\n";
   
    # moving time, journal item at a time, and everything recursively under it
    foreach my $itemid (@itemids) {
	eval {
	    movefrom0_logitem($itemid);
	};
	if ($@) {
	    print "Caught an error: $@\n";
	    # TODO: unset readonly.
	    exit 0;
	}
	$done++;
	my $percent = $done/$todo;
	my $elapsed = time() - $stime;
	my $totaltime = $elapsed * (1 / $percent);
	my $timeremain = int($totaltime - $elapsed);
	$stmsg->(sprintf "$user: copy $done/$todo (%.2f%%) +${elapsed}s -${timeremain}s\n", 100*$percent);
    }

    # if everything's good (nothing's died yet), then delete all from source
    $done = 0;
    $stime = time();
    foreach my $itemid (@itemids) {
	deletefrom0_logitem($itemid);
	$done++;
	my $percent = $done/$todo;
	my $elapsed = time() - $stime;
	my $totaltime = $elapsed * (1 / $percent);
	my $timeremain = int($totaltime - $elapsed);
	$stmsg->(sprintf "$user: delete $done/$todo (%.2f%%) +${elapsed}s -${timeremain}s\n", 100*$percent);
    }

    $dbh->do("UPDATE user SET clusterid=$dclust WHERE userid=$userid");
    # TODO: unset read-only cap
}

sub deletefrom0_logitem
{
    my $itemid = shift;

    # delete all the comments
    my $talkids = $dbh->selectcol_arrayref("SELECT talkid FROM talk ".
					   "WHERE nodetype='L' AND nodeid=$itemid");

    my $talkidin = join(",", @$talkids);
    if ($talkidin) {
	foreach my $table (qw(talktext talkprop talk)) {
	    $dbh->do("DELETE FROM $table WHERE talkid IN ($talkidin)");
	}
    }

    $dbh->do("DELETE FROM logsec WHERE ownerid=$userid AND itemid=$itemid");
    foreach my $table (qw(logprop logtext logsubject log)) {
	$dbh->do("DELETE FROM $table WHERE itemid=$itemid");
    }
}


sub movefrom0_logitem
{
    my $itemid = shift;
    
    my $item = $dbh->selectrow_hashref("SELECT * FROM log WHERE itemid=$itemid");
    my $itemtext = $dbh->selectrow_hashref("SELECT subject, event FROM logtext WHERE itemid=$itemid");
    return 1 unless $item && $itemtext;   # however that could happen.

    # we need to allocate a new jitemid (journal-specific itemid) for this item now.
    $dbh->{'RaiseError'} = 0;
    $dbh->do("INSERT INTO oldids (area, oldid, userid, newid) ".
	     "VALUES ('L', $itemid, $userid, NULL)");
    my $jitemid = 0;
    if ($dbh->err) {
	$jitemid = $dbh->selectrow_array("SELECT newid FROM oldids WHERE area='L' AND oldid=$itemid");
    } else {
	$jitemid = $dbh->{'mysql_insertid'};
    }
    unless ($jitemid) {
	die "ERROR: could not allocate a new jitemid\n";
    }
    $dbh->{'RaiseError'} = 1;
    $item->{'jitemid'} = $jitemid;
    
    # copy item over:
    $dbch->do("REPLACE INTO log2 (journalid, jitemid, posterid, eventtime, logtime, compressed, security, allowmask, replycount, year, month, day, rlogtime, revttime) VALUES (" . join(",", map { $dbh->quote($item->{$_}) } qw(ownerid jitemid posterid eventtime logtime compressed security allowmask replycount year month day rlogtime revttime)) . ")");

    $dbch->do("REPLACE INTO logtext2 (journalid, jitemid, subject, event) VALUES (" . join(",", $userid, $jitemid, map { $dbh->quote($itemtext->{$_}) } qw(subject event)) . ")");

    $dbch->do("REPLACE INTO logsubject2 (journalid, jitemid, subject) VALUES (" . 
	      join(",", $userid, 
		   $jitemid, 
		   $dbh->quote($itemtext->{'subject'}) . ")"));

    # add disk usage info!  (this wasn't in cluster0 anywhere)
    my $bytes = length($itemtext->{'event'}) + length($itemtext->{'subject'});
    $dbch->do("REPLACE INTO dudata (userid, area, areaid, bytes) VALUES ($userid, 'L', $jitemid, $bytes)");

    # is it in recent_?
    if ($recentpoint && $item->{'logtime'} gt $recentpoint) {
	$dbch->do("REPLACE INTO recent_logtext2 (journalid, jitemid, logtime, subject, event) ".
		  "VALUES (" . join(",", $userid, $jitemid, $dbh->quote($item->{'logtime'}), 
				    map { $dbh->quote($itemtext->{$_}) } qw(subject event)) . ")");
    }

    # add the logsec item, if necessary:
    if ($item->{'security'} ne "public") {
	$dbch->do("REPLACE INTO logsec2 (journalid, jitemid, allowmask) VALUES (" . join(",", map { $dbh->quote($item->{$_}) } qw(ownerid jitemid allowmask)) . ")");
    }

    # copy its logprop over:
    my $logprops = $dbh->selectall_arrayref("SELECT propid, value FROM logprop WHERE itemid=$itemid");
    if ($logprops && @$logprops) {
	my $values = join(",", 
			  map { "(" . join(",", $userid, $jitemid, 
					   map { $dbh->quote($_) } @$_ ) . ")" } 
			  grep { $_->[1] } @$logprops); 
	$dbch->do("REPLACE INTO logprop2 (journalid, jitemid, propid, value) VALUES $values")
	    if $values;
    }
    
    # copy its talk shit over:
    my %newtalkids = (0 => 0);  # 0 maps back to 0 still
    my $talkids = $dbh->selectcol_arrayref("SELECT talkid FROM talk ".
					   "WHERE nodetype='L' AND nodeid=$itemid");
    foreach my $t (sort { $a <=> $b } @$talkids) {
	movefrom0_talkitem($t, $jitemid, \%newtalkids);
    }
}

sub movefrom0_talkitem
{
    my $talkid = shift;
    my $jitemid = shift;
    my $newtalkids = shift;

    my $item = $dbh->selectrow_hashref("SELECT * FROM talk WHERE talkid=$talkid");
    my $itemtext = $dbh->selectrow_hashref("SELECT subject, body FROM talktext WHERE talkid=$talkid");
    return 1 unless $item && $itemtext;   # however that could happen.

    # abort if this is a stranded entry.  (shouldn't happen, anyway.  even if it does, it's 
    # not like we're losing data:  the UI (talkread.bml) won't show it anyway)
    return unless defined $newtalkids->{$item->{'parenttalkid'}};

    # we need to allocate a new jitemid (journal-specific itemid) for this item now.
    $dbh->{'RaiseError'} = 0;
    $dbh->do("INSERT INTO oldids (area, oldid, userid, newid) ".
	     "VALUES ('T', $talkid, $userid, NULL)");
    my $jtalkid = 0;
    if ($dbh->err) {
	$jtalkid = $dbh->selectrow_array("SELECT newid FROM oldids WHERE area='T' AND oldid=$talkid");
    } else {
	$jtalkid = $dbh->{'mysql_insertid'};
    }
    unless ($jtalkid) {
	die "ERROR: could not allocate a new jtalkid\n";
    }
    $newtalkids->{$talkid} = $jtalkid;
    $dbh->{'RaiseError'} = 1;
    
    # copy item over:
    $dbch->do("REPLACE INTO talk2 (journalid, jtalkid, parenttalkid, nodeid, nodetype, posterid, datepost, state) ".
	     "VALUES (" . join(",", $userid, $jtalkid,
			       $newtalkids->{$item->{'parenttalkid'}},
			       $jitemid, "'L'",
			       map { $dbh->quote($item->{$_}) } qw(posterid datepost state)) . ")");

    $dbch->do("REPLACE INTO talktext2 (journalid, jtalkid, subject, body) VALUES (" . 
	      join(",", $userid, $jtalkid, map { $dbh->quote($itemtext->{$_}) } qw(subject body)) . ")");

    # add disk usage info!  (this wasn't in cluster0 anywhere)
    my $bytes = length($itemtext->{'body'}) + length($itemtext->{'subject'});
    $dbch->do("REPLACE INTO dudata (userid, area, areaid, bytes) VALUES ($userid, 'T', $jtalkid, $bytes)");

    # is it in recent_?
    if ($recentpoint && $item->{'datepost'} gt $recentpoint) {
	$dbch->do("REPLACE INTO recent_talktext2 (journalid, jtalkid, datepost, subject, body) ".
		  "VALUES (" . join(",", $userid, $jtalkid, $dbh->quote($item->{'datepost'}), 
				    map { $dbh->quote($itemtext->{$_}) } qw(subject body)) . ")");
    }

    # copy its logprop over:
    my $props = $dbh->selectall_arrayref("SELECT tpropid, value FROM talkprop WHERE talkid=$talkid");
    if ($props && @$props) {
	my $values = join(",", 
			  map { "(" . join(",", $userid, $jtalkid, 
					   map { $dbh->quote($_) } @$_ ) . ")" } 
			  grep { $_->[1] } @$props); 
	$dbch->do("REPLACE INTO talkprop2 (journalid, jtalkid, tpropid, value) VALUES $values")
	    if $values;
    }

}
    


1; # return true;

