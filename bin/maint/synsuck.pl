#!/usr/bin/perl
#

use strict;
use vars qw($dbh %maint);
use LWP::UserAgent;
use XML::RSS;
require "$ENV{'LJHOME'}/cgi-bin/ljprotocol.pl";

$maint{'synsuck'} = sub
{
    my $dbs = LJ::get_dbs();
    my $dbh = $dbs->{'dbh'};
    my $dbr = $dbs->{'reader'};
    my $sth;
    
    my $ua =  LWP::UserAgent->new("timeout" => 10);

    $sth = $dbh->prepare("SELECT u.user, s.userid, s.synurl, s.lastmod, s.etag ".
                         "FROM useridmap u, syndicated s ".
                         "WHERE u.userid=s.userid AND ".
                         "s.checknext < NOW() ORDER BY s.checknext");
    $sth->execute;
    while (my ($user, $userid, $synurl, $lastmod, $etag) = $sth->fetchrow_array)
    {
        my $delay = sub {
            my $minutes = shift;
            $dbh->do("UPDATE syndicated SET checknext=DATE_ADD(NOW(), ".
                     "INTERVAL $minutes MINUTE) WHERE userid=$userid");
        };

        print "Synsuck: $user ($synurl)\n";

        my $req = HTTP::Request->new("GET", $synurl);
        $req->header('If-Modified-Since', LJ::time_to_http($lastmod))
            if $lastmod;
        $req->header('If-None-Match', $etag)
            if $etag;

        my ($content, $too_big);
        my $res = $ua->request($req, sub {
            if (length($content) > 1024*150) { $too_big = 1; return; }
            $content .= $_[0];
        }, 4096);
        if ($too_big) { $delay->(60); next; }

        # check if not modified
        if ($res->status_line() =~ /^304/) {
            print "  not modified.\n";
            $delay->(60);
            next;
        }

        my $rss = new XML::RSS;
        eval {
            $rss->parse($content);
        };
        if ($@) {
            # parse error!
            print "Parse error!\n";
            $delay->(3*60);
            next;
        }

        # another sanity check
        unless (ref $rss->{'items'} eq "ARRAY") { $delay->(3*60); next; }

        my @items = reverse @{$rss->{'items'}};

        # take most recent 20
        splice(@items, 0, @items-20) if @items > 20;

        # delete existing items older than the age which can show on a
        # friends view.
        my $su = LJ::load_userid($dbs, $userid);
        my $udbh = LJ::get_cluster_master($su);
        if ($udbh) {
            my $secs = ($LJ::MAX_FRIENDS_VIEW_AGE || 3600*24*14)+0;  # 2 week default.
            my $sth = $udbh->prepare("SELECT jitemid, anum FROM log2 WHERE journalid=? AND ".
                                     "logtime < DATE_SUB(NOW(), INTERVAL $secs SECOND)");
            $sth->execute($userid);
            die $udbh->errstr if $udbh->err;
            while (my ($jitemid, $anum) = $sth->fetchrow_array) {
                print "DELETE itemid: $jitemid, anum: $anum... \n";
                if (LJ::delete_item2($dbh, $udbh, $userid, $jitemid, 0, $anum)) {
                    print "success.\n"; 
                } else {
                    print "fail.\n";
                }
            }
        } else {
            print "WARNING: syndicated user not on a cluster.  can't delete old stuff.\n";
        }
        
        # post these items
        my $newcount = 0;
        my $errorflag = 0;
        foreach my $it (@items) {
            my $dig = LJ::md5_struct($it)->b64digest;
            next if $dbh->selectrow_array("SELECT COUNT(*) FROM synitem WHERE ".
                                          "userid=$userid AND item=?", undef,
                                          $dig);
            $newcount++;
            print "$dig - $it->{'title'}\n";
            $it->{'description'} =~ s/^\s+//;
            $it->{'description'} =~ s/\s+$//;
            
            my @now = localtime();
            my $req = {
                'username' => $user,
                'ver' => 1,
                'subject' => $it->{'title'},
                'event' => "$it->{'link'}\n\n$it->{'description'}",
                'year' => $now[5]+1900,
                'mon' => $now[4]+1,
                'day' => $now[3],
                'hour' => $now[2],
                'min' => $now[1],
            };
            my $flags = {
                'nopassword' => 1,
            };

            my $err;
            my $res = LJ::Protocol::do_request($dbs, "postevent", $req, \$err, $flags);
            if ($res && ! $err) {
                sleep 1; # so 20 items in a row don't get the same logtime second value, so they sort correctly
                $dbh->do("INSERT INTO synitem (userid, item, dateadd) VALUES (?,?,NOW())",
                         undef, $userid, $dig);
            } else {
                print "  Error: $err\n";
                $errorflag = 1;
            }
        }

        # bail out if errors, and try again shortly
        if ($errorflag) {
            $delay->(30);
            next;
        }

        my $r_lastmod = LJ::http_to_time($res->header('Last-Modified'));
        my $r_etag = $res->header('ETag');

        # decide when to poll next (in minutes). 
        # FIXME: this is super lame.  (use hints in RSS file!)
        my $int = $newcount ? 30 : 60;
 
        $dbh->do("UPDATE syndicated SET checknext=DATE_ADD(NOW(), INTERVAL $int MINUTE), ".
                 "lastcheck=NOW(), lastmod=?, etag=? WHERE userid=$userid", undef,
                 $r_lastmod, $r_etag);

    }
};

1;
