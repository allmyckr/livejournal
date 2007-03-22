#
# LiveJournal user object
#
# 2004-07-21: we're transition from $u hashrefs to $u objects, currently
#             backed by hashrefs, to ease migration.  in the future,
#             more methods from ljlib.pl and other places will move here,
#             and the representation of a $u object will change to 'fields'.
#             at present, the motivation to moving to $u objects is to do
#             all database access for a given user through his/her $u object
#             so the queries can be tagged for use by the star replication
#             daemon.

use strict;

package LJ::User;
use Carp;
use lib "$ENV{'LJHOME'}/cgi-bin";
use List::Util ();
use LJ::Constants;
use LJ::MemCache;
use LJ::Session;

use Class::Autouse qw(
                      LJ::Subscription
                      LJ::SMS
                      LJ::SMS::Message
                      LJ::Identity
                      LJ::Auth
                      LJ::Jabber::Presence
                      LJ::S2
                      IO::Socket::INET
                      Time::Local
                      LJ::Event::Befriended
                      LJ::M::FriendsOf
                      );

sub new_from_row {
    my ($class, $row) = @_;
    my $u = bless $row, $class;

    # for selfassert method below:
    $u->{_orig_userid} = $u->{userid};
    $u->{_orig_user}   = $u->{user};

    return $u;
}

# returns LJ::User class of a random user, undef if we couldn't get one
#   my $random_u = LJ::User->load_random_user();
sub load_random_user {
    my $class = shift;

    # get a random database, but make sure to try them all if one is down or not
    # responding or similar
    my $dbcr;
    foreach (List::Util::shuffle(@LJ::CLUSTERS)) {
        $dbcr = LJ::get_cluster_reader($_);
        last if $dbcr;
    }
    die "Unable to get database cluster reader handle\n" unless $dbcr;

    # get a selection of users around a random time
    my $when = time() - int(rand($LJ::RANDOM_USER_PERIOD * 24 * 60 * 60)); # days -> seconds
    my $uids = $dbcr->selectcol_arrayref(qq{
            SELECT userid FROM random_user_set
            WHERE posttime > $when
            ORDER BY posttime
            LIMIT 10
        });
    die "Failed to execute query: " . $dbcr->errstr . "\n" if $dbcr->err;
    return undef unless $uids && @$uids;

    # try the users we got
    foreach my $uid (@$uids) {
        my $u = LJ::load_userid($uid)
            or next;

        # situational checks to ensure this user is a good one to show
        next unless $u->is_person;         # people accounts only
        next unless $u->is_visible;        # no suspended/deleted/etc users
        next if $u->prop('latest_optout'); # they have chosen to be excluded

        # they've passed the checks, return this user
        return $u;
    }

    # must have failed
    return undef;
}

# class method.  returns remote (logged in) user object.  or undef if
# no session is active.
sub remote {
    my ($class, $opts) = @_;
    return LJ::get_remote($opts);
}

# class method.  set the remote user ($u or undef) for the duration of this request.
# once set, it'll never be reloaded, unless "unset_remote" is called to forget it.
sub set_remote
{
    my ($class, $remote) = @_;
    $LJ::CACHED_REMOTE = 1;
    $LJ::CACHE_REMOTE = $remote;
    1;
}

# class method.  forgets the cached remote user.
sub unset_remote
{
    my $class = shift;
    $LJ::CACHED_REMOTE = 0;
    $LJ::CACHE_REMOTE = undef;
    1;
}

sub preload_props {
    my $u = shift;
    LJ::load_user_props($u, @_);
}

sub readonly {
    my $u = shift;
    return LJ::get_cap($u, "readonly");
}

# returns self (the $u object which can be used for $u->do) if
# user is writable, else 0
sub writer {
    my $u = shift;
    return $u if $u->{'_dbcm'} ||= LJ::get_cluster_master($u);
    return 0;
}

sub userpic {
    my $u = shift;
    return undef unless $u->{defaultpicid};
    return LJ::Userpic->new($u, $u->{defaultpicid});
}

# returns a true value if the user is underage; or if you give it an argument,
# will turn on/off that user's underage status.  can also take a second argument
# when you're setting the flag to also update the underage_status userprop
# which is used to record if a user was ever marked as underage.
sub underage {
    # has no bearing if this isn't on
    return undef unless LJ::class_bit("underage");

    # now get the args and continue
    my $u = shift;
    return LJ::get_cap($u, 'underage') unless @_;

    # now set it on or off
    my $on = shift() ? 1 : 0;
    if ($on) {
        $u->add_to_class("underage");
    } else {
        $u->remove_from_class("underage");
    }

    # now set their status flag if one was sent
    my $status = shift();
    if ($status || $on) {
        # by default, just records if user was ever underage ("Y")
        $u->underage_status($status || 'Y');
    }

    # add to statushistory
    if (my $shwhen = shift()) {
        my $text = $on ? "marked" : "unmarked";
        my $status = $u->underage_status;
        LJ::statushistory_add($u, undef, "coppa", "$text; status=$status; when=$shwhen");
    }

    # now fire off any hooks that are available
    LJ::run_hooks('set_underage', {
        u => $u,
        on => $on,
        status => $u->underage_status,
    });

    # return true if no failures
    return 1;
}

# get/set the gizmo account of a user
sub gizmo_account {
    my $u = shift;

    # parse out their account information
    my $acct = $u->prop( 'gizmo' );
    my ($validated, $gizmo);
    if ($acct && $acct =~ /^([01]);(.+)$/) {
        ($validated, $gizmo) = ($1, $2);
    }

    # setting the account
    # all account sets are initially unvalidated
    if (@_) {
        my $newgizmo = shift;
        $u->set_prop( 'gizmo' => "0;$newgizmo" );

        # purge old memcache keys
        LJ::MemCache::delete( "gizmo-ljmap:$gizmo" );
    }

    # return the information (either account + validation or just account)
    return wantarray ? ($gizmo, $validated) : $gizmo unless @_;
}

# get/set the validated status of a user's gizmo account
sub gizmo_account_validated {
    my $u = shift;

    my ($gizmo, $validated) = $u->gizmo_account;

    if ( defined $_[0] && $_[0] =~ /[01]/) {
        $u->set_prop( 'gizmo' => "$_[0];$gizmo" );
        return $_[0];
    }

    return $validated;
}

# log a line to our userlog
sub log_event {
    my $u = shift;

    my ($type, $info) = @_;
    return undef unless $type;
    $info ||= {};

    # now get variables we need; we use delete to remove them from the hash so when we're
    # done we can just encode what's left
    my $ip = delete($info->{ip}) || LJ::get_remote_ip() || undef;
    my $uniq = delete $info->{uniq};
    unless ($uniq) {
        eval {
            $uniq = Apache->request->notes('uniq');
        };
    }
    my $remote = delete($info->{remote}) || LJ::get_remote() || undef;
    my $targetid = (delete($info->{actiontarget})+0) || undef;
    my $extra = %$info ? join('&', map { LJ::eurl($_) . '=' . LJ::eurl($info->{$_}) } keys %$info) : undef;

    # now insert the data we have
    $u->do("INSERT INTO userlog (userid, logtime, action, actiontarget, remoteid, ip, uniq, extra) " .
           "VALUES (?, UNIX_TIMESTAMP(), ?, ?, ?, ?, ?, ?)", undef, $u->{userid}, $type,
           $targetid, $remote ? $remote->{userid} : undef, $ip, $uniq, $extra);
    return undef if $u->err;
    return 1;
}

# return or set the underage status userprop
sub underage_status {
    return undef unless LJ::class_bit("underage");

    my $u = shift;

    # return if they aren't setting it
    unless (@_) {
        return $u->prop("underage_status");
    }

    # set and return what it got set to
    $u->set_prop('underage_status', shift());
    return $u->{underage_status};
}

# returns a true value if user has a reserved 'ext' name.
sub external {
    my $u = shift;
    return $u->{user} =~ /^ext_/;
}

# this is for debugging/special uses where you need to instruct
# a user object on what database handle to use.  returns the
# handle that you gave it.
sub set_dbcm {
    my $u = shift;
    return $u->{'_dbcm'} = shift;
}

sub is_innodb {
    my $u = shift;
    return $LJ::CACHE_CLUSTER_IS_INNO{$u->{clusterid}}
    if defined $LJ::CACHE_CLUSTER_IS_INNO{$u->{clusterid}};

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";
    my (undef, $ctable) = $dbcm->selectrow_array("SHOW CREATE TABLE log2");
    die "Failed to auto-discover database type for cluster \#$u->{clusterid}: [$ctable]"
        unless $ctable =~ /^CREATE TABLE/;

    my $is_inno = ($ctable =~ /=InnoDB/i ? 1 : 0);
    return $LJ::CACHE_CLUSTER_IS_INNO{$u->{clusterid}} = $is_inno;
}

sub begin_work {
    my $u = shift;
    return 1 unless $u->is_innodb;

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->begin_work;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub commit {
    my $u = shift;
    return 1 unless $u->is_innodb;

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->commit;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

sub rollback {
    my $u = shift;
    return 1 unless $u->is_innodb;

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->rollback;
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

# get an $sth from the writer
sub prepare {
    my $u = shift;

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->prepare(@_);
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }
    return $rv;
}

# $u->do("UPDATE foo SET key=?", undef, $val);
sub do {
    my $u = shift;
    my $query = shift;

    my $uid = $u->{userid}+0
        or croak "Database update called on null user object";

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    $query =~ s!^(\s*\w+\s+)!$1/* uid=$uid */ !;

    my $rv = $dbcm->do($query, @_);
    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }

    $u->{_mysql_insertid} = $dbcm->{'mysql_insertid'} if $dbcm->{'mysql_insertid'};

    return $rv;
}

sub selectrow_array {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $set_err = sub {
        if ($u->{_dberr} = $dbcm->err) {
            $u->{_dberrstr} = $dbcm->errstr;
        }
    };

    if (wantarray()) {
        my @rv = $dbcm->selectrow_array(@_);
        $set_err->();
        return @rv;
    }

    my $rv = $dbcm->selectrow_array(@_);
    $set_err->();
    return $rv;
}

sub selectcol_arrayref {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->selectcol_arrayref(@_);

    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }

    return $rv;
}


sub selectall_hashref {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->selectall_hashref(@_);

    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }

    return $rv;
}

sub selectrow_hashref {
    my $u = shift;
    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    my $rv = $dbcm->selectrow_hashref(@_);

    if ($u->{_dberr} = $dbcm->err) {
        $u->{_dberrstr} = $dbcm->errstr;
    }

    return $rv;
}

sub err {
    my $u = shift;
    return $u->{_dberr};
}

sub errstr {
    my $u = shift;
    return $u->{_dberrstr};
}

sub quote {
    my $u = shift;
    my $text = shift;

    my $dbcm = $u->{'_dbcm'} ||= LJ::get_cluster_master($u)
        or die "Database handle unavailable";

    return $dbcm->quote($text);
}

sub mysql_insertid {
    my $u = shift;
    if ($u->isa("LJ::User")) {
        return $u->{_mysql_insertid};
    } elsif (LJ::isdb($u)) {
        my $db = $u;
        return $db->{'mysql_insertid'};
    } else {
        die "Unknown object '$u' being passed to LJ::User::mysql_insertid.";
    }
}

# <LJFUNC>
# name: LJ::User::dudata_set
# class: logging
# des: Record or delete disk usage data for a journal
# args: u, area, areaid, bytes
# area: One character: "L" for log, "T" for talk, "B" for bio, "P" for pic.
# areaid: Unique ID within $area, or '0' if area has no ids (like bio)
# bytes: Number of bytes item takes up.  Or 0 to delete record.
# returns: 1.
# </LJFUNC>
sub dudata_set {
    my ($u, $area, $areaid, $bytes) = @_;
    $bytes += 0; $areaid += 0;
    if ($bytes) {
        $u->do("REPLACE INTO dudata (userid, area, areaid, bytes) ".
               "VALUES (?, ?, $areaid, $bytes)", undef,
               $u->{userid}, $area);
    } else {
        $u->do("DELETE FROM dudata WHERE userid=? AND ".
               "area=? AND areaid=$areaid", undef,
               $u->{userid}, $area);
    }
    return 1;
}

sub make_login_session {
    my ($u, $exptype, $ipfixed) = @_;
    $exptype ||= 'short';
    return 0 unless $u;

    eval { Apache->request->notes('ljuser' => $u->{'user'}); };

    # create session and log user in
    my $sess_opts = {
        'exptype' => $exptype,
        'ipfixed' => $ipfixed,
    };

    my $sess = LJ::Session->create($u, %$sess_opts);
    $sess->update_master_cookie;

    LJ::User->set_remote($u);

    # restore scheme and language
    my $bl = LJ::Lang::get_lang($u->prop('browselang'));
    BML::set_language($bl->{'lncode'}) if $bl;

    # don't set/force the scheme for this page if we're on SSL.
    # we'll pick it up from cookies on subsequent pageloads
    # but if their scheme doesn't have an SSL equivalent,
    # then the post-login page throws security errors
    BML::set_scheme($u->prop('schemepref'))
        unless $LJ::IS_SSL;

    # run some hooks
    my @sopts;
    LJ::run_hooks("login_add_opts", {
        "u" => $u,
        "form" => {},
        "opts" => \@sopts
    });
    my $sopts = @sopts ? ":" . join('', map { ".$_" } @sopts) : "";
    $sess->flags($sopts);

    my $etime = $sess->expiration_time;
    LJ::run_hooks("post_login", {
        "u" => $u,
        "form" => {},
        "expiretime" => $etime,
    });

    # activity for cluster usage tracking
    LJ::mark_user_active($u, 'login');

    # activity for global account number tracking
    $u->note_activity('A');

    return 1;
}

# We have about 10 million different forms of activity tracking.
# This one is for tracking types of user activity on a per-hour basis
#
#    Example: $u had login activity during this out
#
sub note_activity {
    my ($u, $atype) = @_;
    croak ("invalid user") unless ref $u;
    croak ("invalid activity type") unless $atype;

    # If we have no memcache servers, this function would trigger
    # an insert for every logged-in pageview.  Probably not a problem
    # load-wise if the site isn't using memcache anyway, but if the
    # site is that small active user tracking probably doesn't matter
    # much either.  :/
    return undef unless @LJ::MEMCACHE_SERVERS;

    # Also disable via config flag
    return undef if $LJ::DISABLED{active_user_tracking};

    my $now    = time();
    my $uid    = $u->{userid}; # yep, lazy typist w/ rsi
    my $explen = 1800;         # 30 min, same for all types now

    my $memkey = [ $uid, "uactive:$atype:$uid" ];

    # get activity key from memcache
    my $atime = LJ::MemCache::get($memkey);

    # nothing to do if we got an $atime within the last hour
    return 1 if $atime && $atime > $now - $explen;

    # key didn't exist due to expiration, or was too old,
    # means we need to make an activity entry for the user
    my ($hr, $dy, $mo, $yr) = (gmtime($now))[2..5];
    $yr += 1900; # offset from 1900
    $mo += 1;    # 0-based

    # delayed insert in case the table is currently locked due to an analysis
    # running.  this way the apache won't be tied up waiting
    $u->do("INSERT IGNORE INTO active_user " .
           "SET year=?, month=?, day=?, hour=?, userid=?, type=?",
           undef, $yr, $mo, $dy, $hr, $uid, $atype);

    # set a new memcache key good for $explen
    LJ::MemCache::set($memkey, $now, $explen);

    return 1;
}

sub note_transition {
    my ($u, $what, $from, $to) = @_;
    croak "invalid user object" unless LJ::isu($u);

    return 1 if $LJ::DISABLED{user_transitions};

    # we don't want to insert if the requested transition is already
    # the last noted one for this user... in that case there has been
    # no transition at all
    my $last = $u->last_transition($what);
    return 1 if
        $last->{before} eq $from &&
        $last->{after}  eq $to;

    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master";

    # bleh, need backticks on the 'before' and 'after' columns since those
    # are MySQL reserved words
    $dbh->do("INSERT INTO usertrans " .
             "SET userid=?, time=UNIX_TIMESTAMP(), what=?, " .
             "`before`=?, `after`=?",
             undef, $u->{userid}, $what, $from, $to);
    die $dbh->errstr if $dbh->err;

    return 1;
}

sub transition_list {
    my ($u, $what) = @_;
    croak "invalid user object" unless LJ::isu($u);

    my $dbh = LJ::get_db_writer()
        or die "unable to contact global db master";

    # FIXME: return list of transition object singleton instances?
    my @list = ();
    my $sth = $dbh->prepare("SELECT time, `before`, `after` " .
                            "FROM usertrans WHERE userid=? AND what=?");
    $sth->execute($u->{userid}, $what);
    die $dbh->errstr if $dbh->err;

    while (my $trans = $sth->fetchrow_hashref) {

        # fill in a couple of properties here rather than
        # sending over the network from db
        $trans->{userid} = $u->{userid};
        $trans->{what}   = $what;

        push @list, $trans;
    }

    return wantarray() ? @list : \@list;
}

sub last_transition {
    my ($u, $what) = @_;
    croak "invalid user object" unless LJ::isu($u);

    $u->transition_list($what)->[-1];
}

sub tosagree_set
{
    my ($u, $err) = @_;
    return undef unless $u;

    unless (-f "$LJ::HOME/htdocs/inc/legal-tos") {
        $$err = "TOS include file could not be found";
        return undef;
    }

    my $rev;
    open (TOS, "$LJ::HOME/htdocs/inc/legal-tos");
    while ((!$rev) && (my $line = <TOS>)) {
        my $rcstag = "Revision";
        if ($line =~ /\$$rcstag:\s*(\S+)\s*\$/) {
            $rev = $1;
        }
    }
    close TOS;

    # if the required version of the tos is not available, error!
    my $rev_req = $LJ::REQUIRED_TOS{rev};
    if ($rev_req > 0 && $rev ne $rev_req) {
        $$err = "Required Terms of Service revision is $rev_req, but system version is $rev.";
        return undef;
    }

    my $newval = join(', ', time(), $rev);
    my $rv = $u->set_prop("legal_tosagree", $newval);

    # set in $u object for callers later
    $u->{legal_tosagree} = $newval if $rv;

    return $rv;
}

sub tosagree_verify {
    my $u = shift;
    return 1 unless $LJ::TOS_CHECK;

    my $rev_req = $LJ::REQUIRED_TOS{rev};
    return 1 unless $rev_req > 0;

    my $rev_cur = (split(/\s*,\s*/, $u->prop("legal_tosagree")))[1];
    return $rev_cur eq $rev_req;
}

# my $sess = $u->session           (returns current session)
# my $sess = $u->session($sessid)  (returns given session id for user)

sub session {
    my ($u, $sessid) = @_;
    $sessid = $sessid + 0;
    return $u->{_session} unless $sessid;  # should be undef, or LJ::Session hashref
    return LJ::Session->instance($u, $sessid);
}

# in list context, returns an array of LJ::Session objects which are active.
# in scalar context, returns hashref of sessid -> LJ::Sesssion, which are active
sub sessions {
    my $u = shift;
    my @sessions = LJ::Session->active_sessions($u);
    return @sessions if wantarray;
    my $ret = {};
    foreach my $s (@sessions) {
        $ret->{$s->id} = $s;
    }
    return $ret;
}

sub logout {
    my $u = shift;
    if (my $sess = $u->session) {
        $sess->destroy;
    }
    $u->_logout_common;
}

sub logout_all {
    my $u = shift;
    LJ::Session->destroy_all_sessions($u)
        or die "Failed to logout all";
    $u->_logout_common;
}

sub _logout_common {
    my $u = shift;
    LJ::Session->clear_master_cookie;
    LJ::User->set_remote(undef);
    delete $BML::COOKIE{'BMLschemepref'};
    eval { BML::set_scheme(undef); };
}

# returns a new LJ::Session object, or undef on failure
sub create_session
{
    my ($u, %opts) = @_;
    return LJ::Session->create($u, %opts);
}

# $u->kill_session(@sessids)
sub kill_sessions {
    my $u = shift;
    return LJ::Session->destroy_sessions($u, @_);
}

sub kill_all_sessions {
    my $u = shift
        or return 0;

    LJ::Session->destroy_all_sessions($u)
        or return 0;

    # forget this user, if we knew they were logged in
    if ($LJ::CACHE_REMOTE && $LJ::CACHE_REMOTE->{userid} == $u->{userid}) {
        LJ::Session->clear_master_cookie;
        LJ::User->set_remote(undef);
    }

    return 1;
}

sub kill_session {
    my $u = shift
        or return 0;
    my $sess = $u->session
        or return 0;

    $sess->destroy;

    if ($LJ::CACHE_REMOTE && $LJ::CACHE_REMOTE->{userid} == $u->{userid}) {
        LJ::Session->clear_master_cookie;
        LJ::User->set_remote(undef);
    }

    return 1;
}

# <LJFUNC>
# name: LJ::User::mogfs_userpic_key
# class: mogilefs
# des: Make a mogilefs key for the given pic for the user
# args: pic
# pic: Either the userpic hash or the picid of the userpic.
# returns: 1.
# </LJFUNC>
sub mogfs_userpic_key {
    my $self = shift or return undef;
    my $pic = shift or croak "missing required arg: userpic";

    my $picid = ref $pic ? $pic->{picid} : $pic+0;
    return "up:$self->{userid}:$picid";
}

# all reads/writes to talk2 must be done inside a lock, so there's
# no race conditions between reading from db and putting in memcache.
# can't do a db write in between those 2 steps.  the talk2 -> memcache
# is elsewhere (talklib.pl), but this $dbh->do wrapper is provided
# here because non-talklib things modify the talk2 table, and it's
# nice to centralize the locking rules.
#
# return value is return of $dbh->do.  $errref scalar ref is optional, and
# if set, gets value of $dbh->errstr
#
# write:  (LJ::talk2_do)
#   GET_LOCK
#    update/insert into talk2
#   RELEASE_LOCK
#    delete memcache
#
# read:   (LJ::Talk::get_talk_data)
#   try memcache
#   GET_LOCk
#     read db
#     update memcache
#   RELEASE_LOCK

sub talk2_do {
    my ($u, $nodetype, $nodeid, $errref, $sql, @args) = @_;
    return undef unless $nodetype =~ /^\w$/;
    return undef unless $nodeid =~ /^\d+$/;
    return undef unless $u->writer;

    my $dbcm = $u->{_dbcm};

    my $memkey = [$u->{'userid'}, "talk2:$u->{'userid'}:$nodetype:$nodeid"];
    my $lockkey = $memkey->[1];

    $dbcm->selectrow_array("SELECT GET_LOCK(?,10)", undef, $lockkey);
    my $ret = $u->do($sql, undef, @args);
    $$errref = $u->errstr if ref $errref && $u->err;
    $dbcm->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);

    LJ::MemCache::delete($memkey, 0) if int($ret);
    return $ret;
}

# log2_do
# see comments for talk2_do

sub log2_do {
    my ($u, $errref, $sql, @args) = @_;
    return undef unless $u->writer;

    my $dbcm = $u->{_dbcm};

    my $memkey = [$u->{'userid'}, "log2lt:$u->{'userid'}"];
    my $lockkey = $memkey->[1];

    $dbcm->selectrow_array("SELECT GET_LOCK(?,10)", undef, $lockkey);
    my $ret = $u->do($sql, undef, @args);
    $$errref = $u->errstr if ref $errref && $u->err;
    $dbcm->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockkey);

    LJ::MemCache::delete($memkey, 0) if int($ret);
    return $ret;
}

sub url {
    my $u = shift;
    $u->preload_props("url");
    if ($u->{'journaltype'} eq "I" && ! $u->{url}) {
        my $id = $u->identity;
        if ($id && $id->typeid == 0) {
            $u->set_prop("url", $id->[1]) if $id->[1];
            return $id->value;
        }
    }
    return $u->{url};
}

# returns LJ::Identity object
sub identity {
    my $u = shift;
    return $u->{_identity} if $u->{_identity};
    return undef unless $u->{'journaltype'} eq "I";

    my $memkey = [$u->{userid}, "ident:$u->{userid}"];
    my $ident = LJ::MemCache::get($memkey);
    if ($ident) {
        my $i = LJ::Identity->new(
                                  typeid => $ident->[0],
                                  value  => $ident->[1],
                                  );

        return $u->{_identity} = $i;
    }

    my $dbh = LJ::get_db_writer();
    $ident = $dbh->selectrow_arrayref("SELECT idtype, identity FROM identitymap ".
                                      "WHERE userid=? LIMIT 1", undef, $u->{userid});
    if ($ident) {
        LJ::MemCache::set($memkey, $ident);
        my $i = LJ::Identity->new(
                                  typeid => $ident->[0],
                                  value  => $ident->[1],
                                  );
        return $i;
    }
    return undef;
}

# returns a URL if account is an OpenID identity.  undef otherwise.
sub openid_identity {
    my $u = shift;
    my $ident = $u->identity;
    return undef unless $ident && $ident->typeid == 0;
    return $ident->value;
}

# returns username or identity display name, not escaped
sub display_name {
    my $u = shift;
    return $u->{'user'} unless $u->{'journaltype'} eq "I";

    my $id = $u->identity;
    return "[ERR:unknown_identity]" unless $id;

    my ($url, $name);
    if ($id->typeid == 0) {
        require Net::OpenID::Consumer;
        $url = $id->value;
        $name = Net::OpenID::VerifiedIdentity::DisplayOfURL($url, $LJ::IS_DEV_SERVER);
        $name = LJ::run_hook("identity_display_name", $name) || $name;
    }
    return $name;
}

sub ljuser_display {
    my $u = shift;
    my $opts = shift;

    return LJ::ljuser($u, $opts) unless $u->{'journaltype'} eq "I";

    my $id = $u->identity;
    return "<b>????</b>" unless $id;

    my $andfull = $opts->{'full'} ? "&amp;mode=full" : "";
    my $img = $opts->{'imgroot'} || $LJ::IMGPREFIX;
    my $strike = $opts->{'del'} ? ' text-decoration: line-through;' : '';
    my $profile_url = $opts->{'profile_url'} || '';
    my $journal_url = $opts->{'journal_url'} || '';

    my ($url, $name);

    if ($id->typeid == 0) {
        $url = $journal_url ne '' ? $journal_url : $id->value;
        $name = $u->display_name;

        $url ||= "about:blank";
        $name ||= "[no_name]";

        $url = LJ::ehtml($url);
        $name = LJ::ehtml($name);

        my $imgurl = "$img/openid-profile.gif";
        if (my $site = LJ::ExternalSite->find_matching_site($url)) {
            $imgurl = $site->icon_url;
        }

        my $profile = $profile_url ne '' ? $profile_url : "$LJ::SITEROOT/userinfo.bml?userid=$u->{userid}&amp;t=I$andfull";

        return "<span class='ljuser' lj:user='$name' style='white-space: nowrap;'><a href='$profile'><img src='$imgurl' alt='[info]' width='16' height='16' style='vertical-align: bottom; border: 0;' /></a><a href='$url' rel='nofollow'><b>$name</b></a></span>";

    } else {
        return "<b>????</b>";
    }
}

# class function
sub load_identity_user {
    my ($type, $ident, $vident) = @_;

    my $dbh = LJ::get_db_writer();
    my $uid = $dbh->selectrow_array("SELECT userid FROM identitymap WHERE idtype=? AND identity=?",
                                    undef, $type, $ident);
    return LJ::load_userid($uid) if $uid;

    # increment ext_ counter until we successfully create an LJ
    # account.  hard cap it at 10 tries. (arbitrary, but we really
    # shouldn't have *any* failures here, let alone 10 in a row)

    for (1..10) {
        my $extuser = 'ext_' . LJ::alloc_global_counter('E');

        my $name = $extuser;
        if ($type eq "O" && ref $vident) {
            $name = $vident->display;
        }

        $uid = LJ::create_account({
            caps => undef,
            user => $extuser,
            name => $name,
            journaltype => 'I',
        });
        last if $uid;
        select undef, undef, undef, .10;  # lets not thrash over this
    }
    return undef unless $uid &&
        $dbh->do("INSERT INTO identitymap (idtype, identity, userid) VALUES (?,?,?)",
                 undef, $type, $ident, $uid);

    my $u = LJ::load_userid($uid);

    # record create information
    my $remote = LJ::get_remote();
    $u->log_event('account_create', { remote => $remote });

    return $u;
}

# instance method:  returns userprop for a user.  currently from cache with no
# way yet to force master.
sub prop {
    my ($u, $prop) = @_;

    # some props have accessors which do crazy things, if so they need
    # to be redirected from this method, which only loads raw values
    if ({ map { $_ => 1 }
          qw(opt_showbday opt_showlocation opt_showmutualfriends
             view_control_strip show_control_strip opt_ctxpopup opt_embedplaceholders
             esn_inbox_default_expand)
        }->{$prop})
    {
        return $u->$prop;
    }

    return $u->raw_prop($prop);
}

sub raw_prop {
    my ($u, $prop) = @_;
    $u->preload_props($prop) unless exists $u->{$_};
    return $u->{$prop};
}

sub _lazy_migrate_infoshow {
    my ($u) = @_;
    return 1 if $LJ::DISABLED{infoshow_migrate};

    # 1) column exists, but value is migrated
    # 2) column has died from 'user')
    if ($u->{allow_infoshow} eq ' ' || ! $u->{allow_infoshow}) {
        return 1; # nothing to do
    }

    my $infoval = $u->{allow_infoshow} eq 'Y' ? undef : 'N';

    # need to migrate allow_infoshow => opt_showbday
    if ($infoval) {
        foreach my $prop (qw(opt_showbday opt_showlocation)) {
            $u->set_prop($prop => $infoval);
        }
    }

    # setting allow_infoshow to ' ' means we've migrated it
    LJ::update_user($u, { allow_infoshow => ' ' })
        or die "unable to update user after infoshow migration";
    $u->{allow_infoshow} = ' ';

    return 1;
}

# opt_showbday options
# F - Full Display of Birthday
# D - Only Show Month/Day
# Y - Only Show Year
# N - Do not display
sub opt_showbday {
    my $u = shift;
    # option not set = "yes", set to N = "no"
    $u->_lazy_migrate_infoshow;

    # migrate above did nothing
    # -- if user was already migrated in the past, we'll
    #    fall through and show their prop value
    # -- if user not migrated yet, we'll synthesize a prop
    #    value from infoshow without writing it
    if ($LJ::DISABLED{infoshow_migrate} && $u->{allow_infoshow} ne ' ') {
        return $u->{allow_infoshow} eq 'Y' ? undef : 'N';
    }
    if ($u->raw_prop('opt_showbday') =~ /^(D|F|N|Y)$/) {
        return $u->raw_prop('opt_showbday');
    } else {
        return 'F';
    }
}

# opt_showljtalk options based on user setting
# Y = Show the LJ Talk field on profile (default)
# N = Don't show the LJ Talk field on profile
sub opt_showljtalk {
    my $u = shift;

    # Check for valid value, or just return default of 'Y'.
    if ($u->raw_prop('opt_showljtalk') =~ /^(Y|N)$/) {
        return $u->raw_prop('opt_showljtalk');
    } else {
        return 'Y';
    }
}

# Show LJ Talk field on profile?  opt_showljtalk needs a value of 'Y'.
sub show_ljtalk {
    my $u = shift;
    croak "Invalid user object passed" unless LJ::isu($u);

    # Fail if the user wants to hide the LJ Talk field on their profile,
    # or doesn't even have the ability to show it.
    return 0 if $u->opt_showljtalk eq 'N' || $LJ::DISABLED{'ljtalk'} || !$u->is_person;

    # User either decided to show LJ Talk field or has left it at the default.
    return 1 if $u->opt_showljtalk eq 'Y';
}

# Hide the LJ Talk field on profile?  opt_showljtalk needs a value of 'N'.
sub hide_ljtalk {
    my $u = shift;
    croak "Invalid user object passed" unless LJ::isu($u);

    # ... The opposite of showing the field. :)
    return $u->show_ljtalk ? 0 : 1;
}

sub ljtalk_id {
    my $u = shift;
    croak "Invalid user object passed" unless LJ::isu($u);

    return $u->{'user'}.'@'.$LJ::USER_DOMAIN;
}

sub opt_showlocation {
    my $u = shift;
    # option not set = "yes", set to N = "no"
    $u->_lazy_migrate_infoshow;

    # see comments for opt_showbday
    if ($LJ::DISABLED{infoshow_migrate} && $u->{allow_infoshow} ne ' ') {
        return $u->{allow_infoshow} eq 'Y' ? undef : 'N';
    }
    if ($u->raw_prop('opt_showlocation') =~ /^(N|Y)$/) {
        return $u->raw_prop('opt_showlocation');
    } else {
        return 'Y';
    }
}

# opt_showonlinestatus options
# F = Mutual Friends
# Y = Everybody
# N = Nobody
sub opt_showonlinestatus {
    my $u = shift;

    if ($u->raw_prop('opt_showonlinestatus') =~ /^(F|N|Y)$/) {
        return $u->raw_prop('opt_showonlinestatus');
    } else {
        return 'F';
    }
}

sub can_show_location {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);
    return 0 if $u->underage;
    return 0 if $u->opt_showlocation eq 'N';
    return 1;
}

sub can_show_onlinestatus {
    my $u = shift;
    my $remote = shift;
    croak "invalid user object passed"
        unless LJ::isu($u);

    # Nobody can see online status of u
    return 0 if $u->opt_showonlinestatus eq 'N';
    # Everybody can see online status of u
    return 1 if $u->opt_showonlinestatus eq 'Y';
    # Only mutual friends of u can see online status
    if ($u->opt_showonlinestatus eq 'F') {
        return 0 unless $remote;
        return 1 if $u->is_mutual_friend($remote);
        return 0;
    }
    return 0;
}

# return user selected mail encoding or undef
sub mailencoding {
    my $u = shift;
    my $enc = $u->prop('mailencoding');

    return undef unless $enc;

    LJ::load_codes({ "encoding" => \%LJ::CACHE_ENCODINGS } )
        unless %LJ::CACHE_ENCODINGS;
    return $LJ::CACHE_ENCODINGS{$enc}
}

# Birthday logic -- show appropriate string based on opt_showbday
# This will return true if the actual birthday can be shown
sub can_show_bday {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);
    return 0 if $u->underage;
    return 0 unless $u->opt_showbday eq 'D' || $u->opt_showbday eq 'F';
    return 1;
}

# This will return true if the actual birth year can be shown
sub can_show_bday_year {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);
    return 0 if $u->underage;
    return 0 unless $u->opt_showbday eq 'Y' || $u->opt_showbday eq 'F';
    return 1;
}

# This will return true if month, day, and year can be shown
sub can_show_full_bday {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);
    return 0 if $u->underage;
    return 0 unless $u->opt_showbday eq 'F';
    return 1;
}

# This will format the birthdate based on the user prop
sub bday_string {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);
    return 0 if $u->underage;

    my $bdate = $u->{'bdate'};
    my ($year,$mon,$day) = split(/-/, $bdate);
    my $bday_string = '';

    if ($u->can_show_full_bday && $day > 0 && $mon > 0 && $year > 0) {
        $bday_string = $bdate;
    } elsif ($u->can_show_bday && $day > 0 && $mon > 0) {
        $bday_string = "$mon-$day";
    } elsif ($u->can_show_bday_year && $year > 0) {
        $bday_string = $year;
    }
    $bday_string =~ s/^0000-//;
    return $bday_string;
}

# Users age based off their profile birthdate
sub age {
    my $u = shift;
    croak "Invalid user object" unless LJ::isu($u);

    my $bdate = $u->{bdate};
    return unless length $bdate;

    my ($year, $mon, $day) = $bdate =~ m/^(\d\d\d\d)-(\d\d)-(\d\d)/;
    my $age = LJ::calc_age($year, $mon, $day);
    return $age if $age > 0;
    return;
}

# This returns the users age based on the init_bdate (users coppa validation birthdate)
sub init_age {
    my $u = shift;
    croak "Invalid user object" unless LJ::isu($u);

    my $init_bdate = $u->prop('init_bdate');
    return unless $init_bdate;

    my ($year, $mon, $day) = $init_bdate =~ m/^(\d\d\d\d)-(\d\d)-(\d\d)/;
    my $age = LJ::calc_age($year, $mon, $day);
    return $age if $age > 0;
    return;
}

# sets prop, and also updates $u's cached version
sub set_prop {
    my ($u, $prop, $value) = @_;
    return 0 unless LJ::set_userprop($u, $prop, $value);  # FIXME: use exceptions
    $u->{$prop} = $value;
}

sub journal_base {
    my $u = shift;
    return LJ::journal_base($u);
}

sub allpics_base {
    my $u = shift;
    return "$LJ::SITEROOT/allpics.bml?user=" . $u->user;
}

sub get_userpic_count {
    my $u = shift or return undef;
    my $count = scalar LJ::Userpic->load_user_userpics($u);

    return $count;
}

sub userpic_quota {
    my $u = shift or return undef;
    my $quota = $u->get_cap('userpics');

    return $quota;
}

sub friendsfriends_url {
    my $u = shift;
    croak "invalid user object passed" unless LJ::isu($u);

    return $u->journal_base . "/friendsfriends";
}

sub profile_url {
    my $u = shift;
    if ($u->{journaltype} eq "I") {
        return "$LJ::SITEROOT/userinfo.bml?userid=$u->{'userid'}&t=I";
    } else {
        return $u->journal_base . "/profile";
    }

}

# <LJFUNC>
# name: LJ::User::large_journal_icon
# des: get the large icon by journal type
# returns: HTML to display large journal icon
# </LJFUNC>
sub large_journal_icon {
    my $u = shift;
    croak "invalid user object"
        unless LJ::isu($u);

    my $wrap_img = sub {
        return "<img src='$LJ::IMGPREFIX/$_[0]' border='0' height='24' " .
            "width='24' style='padding: 0px 2px 0px 0px' />";
    };

    # hook will return image to use if it cares about
    # the $u it's been passed
    my $hook_img = LJ::run_hook("large_journal_icon", $u);
    return $wrap_img->($hook_img) if $hook_img;

    if ($u->is_comm) {
        return $wrap_img->("community24x24.gif");
    }

    if ($u->is_syndicated) {
        return $wrap_img->("syndicated24x24.gif");
    }

    if ($u->is_identity) {
        return $wrap_img->("openid24x24.gif");
    }

    # personal, news, or unknown fallthrough
    return $wrap_img->("userinfo24x24.gif");
}

# <LJFUNC>
# name: LJ::User::caps_icon
# des: get the icon for a user's cap
# returns: HTML with site-specific cap icon
# </LJFUNC>
sub caps_icon {
    my $u = shift;
    return LJ::user_caps_icon($u->{caps});
}

# <LJFUNC>
# name: LJ::User::get_friends_birthdays
# des: get the upcoming birthdays for friends of a user. shows birthdays 3 months away by default
#      pass in full => 1 to get all friends' birthdays
# returns: arrayref of [ month, day, user ] arrayrefs
# </LJFUNC>
sub get_friends_birthdays {
    my $u = shift;
    return undef unless LJ::isu($u);

    my %opts = @_;
    my $months_ahead = $opts{months_ahead} || 3;
    my $full = $opts{full};

    my $userid = $u->userid;

    # what day is it now?  server time... suck, yeah.
    my @time = localtime();
    my ($mnow, $dnow) = ($time[4]+1, $time[3]);

    my @friends = $u->friends;
    my @bdays;

    my $memkey = [$u->userid, 'frbdays:' . $u->userid . ':' . ($full ? 'full' : $months_ahead)];
    my $cached_bdays = LJ::MemCache::get($memkey);
    if ($cached_bdays) {
        @bdays = @$cached_bdays;
    } else {
        foreach my $friend (@friends) {
            my ($year, $month, $day) = split('-', $friend->{bdate});
            next unless $month > 0 && $day > 0;

            # skip over unless a few months away (except in full mode)
            unless ($full) {
                next unless ($mnow + $months_ahead > 12 && ($mnow + $months_ahead) % 12 > $month) ||
                    ($month >= $mnow && $day >= $dnow && $mnow + $months_ahead > $month);
            }

            if ($friend->can_show_bday) {
                push @bdays, [ $month, $day, $friend->user ];
            }
        }

        LJ::MemCache::set($memkey, \@bdays, 86400);
    }

    return sort {
        # month sort
        ($a->[0] <=> $b->[0]) ||
            # day sort
            ($a->[1] <=> $b->[1])
        } @bdays;
}


# get recent talkitems posted to this user
# args: maximum number of comments to retreive
# returns: array of hashrefs with jtalkid, nodetype, nodeid, parenttalkid, posterid, state
sub get_recent_talkitems {
    my ($u, $maxshow, %opts) = @_;

    $maxshow ||= 15;
    # don't do memcache by default, callers can request cached version
    my $memcache = $opts{memcache} || 0;

    return undef unless LJ::isu($u);

    my @recv;

    my $memkey = [$u->userid, 'rcntalk:' . $u->userid . ':' . $maxshow];
    if ($memcache) {
        my $recv_cached = LJ::MemCache::get($memkey);
        return @$recv_cached if $recv_cached;
    }

    my $max = $u->selectrow_array("SELECT MAX(jtalkid) FROM talk2 WHERE journalid=?",
                                     undef, $u->{userid});
    return undef unless $max;

    my $sth = $u->prepare("SELECT jtalkid, nodetype, nodeid, parenttalkid, ".
                          "       posterid, UNIX_TIMESTAMP(datepost) as 'datepostunix', state ".
                          "FROM talk2 ".
                          "WHERE journalid=? AND jtalkid > ?");
    $sth->execute($u->{'userid'}, $max - $maxshow);
    while (my $r = $sth->fetchrow_hashref) {
        push @recv, $r;
    }

    # memcache results for an hour
    LJ::MemCache::set($memkey, \@recv, 3600);

    return @recv;
}

sub record_login {
    my ($u, $sessid) = @_;

    my $too_old = time() - 86400 * 30;
    $u->do("DELETE FROM loginlog WHERE userid=? AND logintime < ?",
           undef, $u->{userid}, $too_old);

    my ($ip, $ua);
    eval {
        my $r  = Apache->request;
        $ip = LJ::get_remote_ip();
        $ua = $r->header_in('User-Agent');
    };

    return $u->do("INSERT INTO loginlog SET userid=?, sessid=?, logintime=UNIX_TIMESTAMP(), ".
                  "ip=?, ua=?", undef, $u->{userid}, $sessid, $ip, $ua);
}

# THIS IS DEPRECATED DO NOT USE
sub email {
    my ($u, $remote) = @_;
    return $u->emails_visible($remote);
}

sub email_raw {
    my $u = shift;
    $u->{_email} ||= LJ::MemCache::get_or_set([$u->{userid}, "email:$u->{userid}"], sub {
        my $dbh = LJ::get_db_writer() or die "Couldn't get db master";
        return $dbh->selectrow_array("SELECT email FROM email WHERE userid=?",
                                     undef, $u->id);
    });
    return $u->{_email} || $u->{email};  # the || is for old-style in-user-table
}

# in scalar context, returns user's email address.  given a remote user,
# bases decision based on whether $remote user can see it.  in list context,
# returns all emails that can be shown
sub email_visible {
    my ($u, $remote) = @_;

    return scalar $u->emails_visible($remote);
}

sub emails_visible {
    my ($u, $remote) = @_;

    return () if $u->{journaltype} =~ /[YI]/;

    # security controls
    return () unless
        $u->{'allow_contactshow'} eq "Y" ||
        ($u->{'allow_contactshow'} eq "F" && LJ::is_friend($u, $remote));

    my $whatemail = $u->prop("opt_whatemailshow");
    my $useremail_cap = LJ::get_cap($u, 'useremail');

    # some classes of users we want to have their contact info hidden
    # after so much time of activity, to prevent people from bugging
    # them for their account or trying to brute force it.
    my $hide_contactinfo = sub {
        my $hide_after = LJ::get_cap($u, "hide_email_after");
        return 0 unless $hide_after;
        my $memkey = [$u->{userid}, "timeactive:$u->{userid}"];
        my $active;
        unless (defined($active = LJ::MemCache::get($memkey))) {
            my $dbcr = LJ::get_cluster_def_reader($u) or return 0;
            $active = $dbcr->selectrow_array("SELECT timeactive FROM clustertrack2 ".
                                             "WHERE userid=?", undef, $u->{userid});
            LJ::MemCache::set($memkey, $active, 86400);
        }
        return $active && (time() - $active) > $hide_after * 86400;
    };

    return () if $u->{'opt_whatemailshow'} eq "N" ||
        $u->{'opt_whatemailshow'} eq "L" && ($u->prop("no_mail_alias") || ! $useremail_cap || ! $LJ::USER_EMAIL) ||
        $hide_contactinfo->();

    my @emails = ($u->email_raw);
    if ($u->{'opt_whatemailshow'} eq "L") {
        @emails = ();
    }
    if ($LJ::USER_EMAIL && $useremail_cap) {
        unless ($u->{'opt_whatemailshow'} eq "A" || $u->{'no_mail_alias'}) {
            push @emails, "$u->{'user'}\@$LJ::USER_DOMAIN";
        }
    }
    return wantarray ? @emails : $emails[0];
}

sub email_status {
    my $u = shift;
    return $u->{status};
}

sub is_validated {
    my $u = shift;
    return $u->email_status eq "A";
}

sub update_email_alias {
    my $u = shift;
    return unless $u && $u->get_cap("useremail");
    return if exists $LJ::FIXED_ALIAS{$u->{'user'}};

    return if $u->prop("no_mail_alias");

    my $dbh = LJ::get_db_writer();
    $dbh->do("REPLACE INTO email_aliases (alias, rcpt) VALUES (?,?)",
             undef, "$u->{'user'}\@$LJ::USER_DOMAIN", $u->email_raw);

    return 0 if $dbh->err;
    return 1;
}

sub can_receive_password {
    my ($u, $email) = @_;

    return 0 unless $u && $email;
    return 1 if lc($email) eq lc($u->email_raw);

    my $dbh = LJ::get_db_reader();
    return $dbh->selectrow_array("SELECT COUNT(*) FROM infohistory ".
                                 "WHERE userid=? AND what='email' ".
                                 "AND oldvalue=? AND other='A'",
                                 undef, $u->id, $email);
}

sub share_contactinfo {
    my ($u, $remote) = @_;
    return 0 if $u->{journaltype} eq "Y" || $u->underage;
    return $u->{'allow_contactshow'} eq "Y" ||
        ($u->{'allow_contactshow'} eq "F" && LJ::is_friend($u, $remote));
}

# <LJFUNC>
# name: LJ::User::activate_userpics
# des: Sets/unsets userpics as inactive based on account caps
# returns: nothing
# </LJFUNC>
sub activate_userpics {
    my $u = shift;

    # this behavior is optional, but enabled by default
    return 1 if $LJ::ALLOW_PICS_OVER_QUOTA;

    return undef unless LJ::isu($u);

    # can't get a cluster read for expunged users since they are clusterid 0,
    # so just return 1 to the caller from here and act like everything went fine
    return 1 if $u->is_expunged;

    my $userid = $u->{'userid'};

    # active / inactive lists
    my @active = ();
    my @inactive = ();
    my $allow = LJ::get_cap($u, "userpics");

    # get a database handle for reading/writing
    my $dbh = LJ::get_db_writer();
    my $dbcr = LJ::get_cluster_def_reader($u);

    # select all userpics and build active / inactive lists
    my $sth;
    if ($u->{'dversion'} > 6) {
        return undef unless $dbcr;
        $sth = $dbcr->prepare("SELECT picid, state FROM userpic2 WHERE userid=?");
    } else {
        return undef unless $dbh;
        $sth = $dbh->prepare("SELECT picid, state FROM userpic WHERE userid=?");
    }
    $sth->execute($userid);
    while (my ($picid, $state) = $sth->fetchrow_array) {
        next if $state eq 'X'; # expunged, means userpic has been removed from site by admins
        if ($state eq 'I') {
            push @inactive, $picid;
        } else {
            push @active, $picid;
        }
    }

    # inactivate previously activated userpics
    if (@active > $allow) {
        my $to_ban = @active - $allow;

        # find first jitemid greater than time 2 months ago using rlogtime index
        # ($LJ::EndOfTime - UnixTime)
        my $jitemid = $dbcr->selectrow_array("SELECT jitemid FROM log2 USE INDEX (rlogtime) " .
                                             "WHERE journalid=? AND rlogtime > ? LIMIT 1",
                                             undef, $userid, $LJ::EndOfTime - time() + 86400*60);

        # query all pickws in logprop2 with jitemid > that value
        my %count_kw = ();
        my $propid = LJ::get_prop("log", "picture_keyword")->{'id'};
        my $sth = $dbcr->prepare("SELECT value, COUNT(*) FROM logprop2 " .
                                 "WHERE journalid=? AND jitemid > ? AND propid=?" .
                                 "GROUP BY value");
        $sth->execute($userid, $jitemid, $propid);
        while (my ($value, $ct) = $sth->fetchrow_array) {
            # keyword => count
            $count_kw{$value} = $ct;
        }

        my $keywords_in = join(",", map { $dbh->quote($_) } keys %count_kw);

        # map pickws to picids for freq hash below
        my %count_picid = ();
        if ($keywords_in) {
            my $sth;
            if ($u->{'dversion'} > 6) {
                $sth = $dbcr->prepare("SELECT k.keyword, m.picid FROM userkeywords k, userpicmap2 m ".
                                      "WHERE k.keyword IN ($keywords_in) AND k.kwid=m.kwid AND k.userid=m.userid " .
                                      "AND k.userid=?");
            } else {
                $sth = $dbh->prepare("SELECT k.keyword, m.picid FROM keywords k, userpicmap m " .
                                     "WHERE k.keyword IN ($keywords_in) AND k.kwid=m.kwid " .
                                     "AND m.userid=?");
            }
            $sth->execute($userid);
            while (my ($keyword, $picid) = $sth->fetchrow_array) {
                # keyword => picid
                $count_picid{$picid} += $count_kw{$keyword};
            }
        }

        # we're only going to ban the least used, excluding the user's default
        my @ban = (grep { $_ != $u->{'defaultpicid'} }
                   sort { $count_picid{$a} <=> $count_picid{$b} } @active);

        @ban = splice(@ban, 0, $to_ban) if @ban > $to_ban;
        my $ban_in = join(",", map { $dbh->quote($_) } @ban);
        if ($u->{'dversion'} > 6) {
            $u->do("UPDATE userpic2 SET state='I' WHERE userid=? AND picid IN ($ban_in)",
                   undef, $userid) if $ban_in;
        } else {
            $dbh->do("UPDATE userpic SET state='I' WHERE userid=? AND picid IN ($ban_in)",
                     undef, $userid) if $ban_in;
        }
    }

    # activate previously inactivated userpics
    if (@inactive && @active < $allow) {
        my $to_activate = $allow - @active;
        $to_activate = @inactive if $to_activate > @inactive;

        # take the $to_activate newest (highest numbered) pictures
        # to reactivated
        @inactive = sort @inactive;
        my @activate_picids = splice(@inactive, -$to_activate);

        my $activate_in = join(",", map { $dbh->quote($_) } @activate_picids);
        if ($activate_in) {
            if ($u->{'dversion'} > 6) {
                $u->do("UPDATE userpic2 SET state='N' WHERE userid=? AND picid IN ($activate_in)",
                       undef, $userid);
            } else {
                $dbh->do("UPDATE userpic SET state='N' WHERE userid=? AND picid IN ($activate_in)",
                         undef, $userid);
            }
        }
    }

    # delete userpic info object from memcache
    LJ::MemCache::delete([$userid, "upicinf:$userid"]);

    return 1;
}

# ensure that this user does not have more than the maximum number of subscriptions
# allowed by their cap, and enable subscriptions up to their current limit
sub enable_subscriptions {
    my $u = shift;

    # first thing, disable everything they don't have caps for
    # and make sure everything is enabled that should be enabled
    map { $_->available_for_user($u) ? $_->enable : $_->disable } $u->find_subscriptions(method => 'Inbox');

    my $max_subs = $u->get_cap('subscriptions');
    my @inbox_subs = grep { $_->active && $_->enabled } $u->find_subscriptions(method => 'Inbox');

    if ((scalar @inbox_subs) > $max_subs) {
        # oh no, too many subs.
        # disable the oldest subscriptions that are "tracking" subscriptions
        my @tracking = grep { $_->is_tracking_category } @inbox_subs;

        # oldest subs first
        @tracking = sort {
            return $a->createtime <=> $b->createtime;
        } @tracking;

        my $need_to_deactivate = (scalar @inbox_subs) - $max_subs;

        for (1..$need_to_deactivate) {
            my $sub_to_deactivate = shift @tracking;
            $sub_to_deactivate->deactivate if $sub_to_deactivate;
        }
    } else {
        # make sure all subscriptions are activated
        my $need_to_activate = $max_subs - (scalar @inbox_subs);

        # get deactivated subs
        @inbox_subs = grep { $_->active && $_->available_for_user } $u->find_subscriptions(method => 'Inbox');

        for (1..$need_to_activate) {
            my $sub_to_activate = shift @inbox_subs;
            $sub_to_activate->activate if $sub_to_activate;
        }
    }
}

# revert S2 style to the default if the user is using a layout/theme layer that they don't have permission to use
sub revert_style {
    my $u = shift;

    # FIXME: both of these solutions suck
    # - ensure that LJ::S2 is loaded via Class::Autouse by calling a method on it
    LJ::S2->can("dostuff");

    # - also require LJ::customize
    require "customizelib.pl";

    my $default_style = LJ::run_hook('get_default_style', $u) || $LJ::DEFAULT_STYLE;

    my %style = LJ::S2::get_style($u, "verify");
    my $public = LJ::S2::get_public_layers();
    my @custom_layouts = LJ::cmize::s2_custom_layer_list($u, 'layout', 'core');
    my @custom_themes = LJ::cmize::s2_custom_layer_list($u, 'theme', 'layout');
    my $layout = $public->{$style{'layout'}};
    my $theme = $public->{$style{'theme'}};
    my $default_layout_uniq = exists $default_style->{'layout'} ? $default_style->{'layout'} : '';
    my $style_exists = 0;
    my $using_custom_layer = 0;

    # check to see if the user is using a custom layout or theme
    # if so, we want to let them keep using it
    foreach my $custom_layout (@custom_layouts) {
        if ($custom_layout == $style{'layout'}) {
            $using_custom_layer = 1;
        }
    }
    foreach my $custom_theme (@custom_themes) {
        if ($custom_theme == $style{'theme'}) {
            $using_custom_layer = 1;
        }
    }

    # if the user cannot use the layout, switch to the default style (if it's defined)
    # if the user can use the layout but not the theme, switch to the default theme of that layout
    if ($default_layout_uniq ne '' && ! $using_custom_layer && ! LJ::S2::can_use_layer($u, $layout->{'uniq'})) {

        # look for a style that uses the default layout, and use it if it exists
        my $uniq = (split("/", $default_layout_uniq))[0] || $public->{$default_layout_uniq->{'s2lid'}};
        my $userstyles = LJ::S2::load_user_styles($u);
        foreach (keys %$userstyles) {
            next unless $userstyles->{$_} eq "wizard-$uniq";

            $style_exists = 1;
            $u->set_prop("s2_style", $_);

            my $stylelayers = LJ::S2::get_style_layers($u, $u->prop('s2_style'));
            foreach my $layer (qw(user theme i18nc i18n core)) {
                $style{$layer} = exists $stylelayers->{$layer} ? $stylelayers->{$layer} : 0;
            }

            last;
        }

        # set the layers that are defined by $default_style
        while (my ($layer, $name) = each %$default_style) {
            next if $name eq "";
            next unless $public->{$name};
            my $id = $public->{$name}->{'s2lid'};
            $style{$layer} = $id if $id;
        }

        # make sure core was set
        $style{'core'} = $public->{$default_layout_uniq->{'b2lid'}}
            if $style{'core'} == 0;

        # make sure the other layers were set
        foreach my $layer (qw(user theme i18nc i18n)) {
            $style{$layer} = 0 unless $style{$layer} || $style_exists;
        }

        # create the style
        if ($style_exists) {
            LJ::cmize::s2_implicit_style_create($u, %style);
        } else {
            LJ::cmize::s2_implicit_style_create({ 'force' => 1 }, $u, %style);
        }

    } elsif (! $using_custom_layer && LJ::S2::can_use_layer($u, $layout->{'uniq'}) && ! LJ::S2::can_use_layer($u, $theme->{'uniq'})) {
        $style{'theme'} = 0;

        # create the style
        LJ::cmize::s2_implicit_style_create($u, %style);
    }
}

sub uncache_prop {
    my ($u, $name) = @_;
    my $prop = LJ::get_prop("user", $name) or die; # FIXME: use exceptions
    LJ::MemCache::delete([$u->{userid}, "uprop:$u->{userid}:$prop->{id}"]);
    delete $u->{$name};
    return 1;
}

sub set_draft_text {
    my ($u, $draft) = @_;
    my $old = $u->draft_text;

    $LJ::_T_DRAFT_RACE->() if $LJ::_T_DRAFT_RACE;

    # try to find a shortcut that makes the SQL shorter
    my @methods;  # list of [ $subref, $cost ]

    # one method is just setting it all at once.  which incurs about
    # 75 bytes of SQL overhead on top of the length of the draft,
    # not counting the escaping
    push @methods, [ "set", sub { $u->set_prop('entry_draft', $draft); 1 },
                     75 + length $draft ];

    # stupid case, setting the same thing:
    push @methods, [ "noop", sub { 1 }, 0 ] if $draft eq $old;

    # simple case: appending
    if (length $old && $draft =~ /^\Q$old\E(.+)/s) {
        my $new = $1;
        my $appending = sub {
            my $prop = LJ::get_prop("user", "entry_draft") or die; # FIXME: use exceptions
            my $rv = $u->do("UPDATE userpropblob SET value = CONCAT(value, ?) WHERE userid=? AND upropid=? AND LENGTH(value)=?",
                            undef, $new, $u->{userid}, $prop->{id}, length $old);
            return 0 unless $rv > 0;
            $u->uncache_prop("entry_draft");
            return 1;
        };
        push @methods, [ "append", $appending, 40 + length $new ];
    }

    # TODO: prepending/middle insertion (the former being just the latter), as well
    # appending, wihch we could then get rid of

    # try the methods in increasing order
    foreach my $m (sort { $a->[2] <=> $b->[2] } @methods) {
        my $func = $m->[1];
        if ($func->()) {
            $LJ::_T_METHOD_USED->($m->[0]) if $LJ::_T_METHOD_USED; # for testing
            return 1;
        }
    }
    return 0;
}

sub draft_text {
    my ($u) = @_;
    return $u->prop('entry_draft');
}

sub notable_interests {
    my ($u, $n) = @_;
    $n ||= 20;

    # arrayref of arrayrefs of format [intid, intname, intcount];
    my $ints = LJ::get_interests($u)
        or return ();

    my @ints = sort { $b->[2] <=> $a->[2] } @$ints;
    @ints = @ints[0..$n-1] if @ints > $n;
    return map { $_->[1] } @ints;
}

# returns $n number of communities that $u is a member of, sorted by update time (most recent to least recent)
sub notable_communities {
    my ($u, $n) = @_;
    $n ||= 3;

    my $friends = $u->friends;

    my $fro_m = LJ::M::FriendsOf->new(
        $u,
        sloppy => 1, # approximate if no summary info
        friends => { map {$_ => 1} keys %$friends },
    );

    my $update_times = LJ::get_timeupdate_multi( map { $_->id } $fro_m->member_of );

    my @ret_commids;
    my $count = 1;
    foreach my $commid (sort {$update_times->{$b} <=> $update_times->{$a}} keys %$update_times) {
        last if $count > $n;
        push @ret_commids, $commid;
        $count++;
    }

    my $us = LJ::load_userids(@ret_commids);

    return map { $us->{$_} } @ret_commids;
}

# returns the max capability ($cname) for all the classes
# the user is a member of
sub get_cap {
    my ($u, $cname) = @_;
    return 1 if $LJ::T_HAS_ALL_CAPS;
    return LJ::get_cap($u, $cname);
}

# tests to see if a user is in a specific named class. class
# names are site-specific.
sub in_class {
    my ($u, $class) = @_;
    return LJ::caps_in_group($u->{caps}, $class);
}

sub add_to_class {
    my ($u, $class) = @_;
    my $bit = LJ::class_bit($class);
    die "unknown class '$class'" unless defined $bit;

    # call add_to_class hook before we modify the
    # current $u, so it can make inferences from the
    # old $u caps vs the new we say we'll be adding
    if (LJ::are_hooks('add_to_class')) {
        LJ::run_hook('add_to_class', $u, $class);
    }

    return LJ::modify_caps($u, [$bit], []);
}

sub remove_from_class {
    my ($u, $class) = @_;
    my $bit = LJ::class_bit($class);
    die "unknown class '$class'" unless defined $bit;

    # call remove_from_class hook before we modify the
    # current $u, so it can make inferences from the
    # old $u caps vs what we'll be removing
    if (LJ::are_hooks('remove_from_class')) {
        LJ::run_hook('remove_from_class', $u, $class);
    }

    return LJ::modify_caps($u, [], [$bit]);
}

sub cache {
    my ($u, $key) = @_;
    my $val = $u->selectrow_array("SELECT value FROM userblobcache WHERE userid=? AND bckey=?",
                                  undef, $u->{userid}, $key);
    return undef unless defined $val;
    if (my $thaw = eval { Storable::thaw($val); }) {
        return $thaw;
    }
    return $val;
}

sub set_cache {
    my ($u, $key, $value, $expr) = @_;
    my $now = time();
    $expr ||= $now + 86400;
    $expr += $now if $expr < 315532800;  # relative to absolute time
    $value = Storable::nfreeze($value) if ref $value;
    $u->do("REPLACE INTO userblobcache (userid, bckey, value, timeexpire) VALUES (?,?,?,?)",
           undef, $u->{userid}, $key, $value, $expr);
}

# returns array of LJ::Entry objects, ignoring security
sub recent_entries {
    my ($u, %opts) = @_;
    my $remote = delete $opts{'filtered_for'} || LJ::get_remote();
    my $count  = delete $opts{'count'}        || 50;
    die "unknown options" if %opts;

    my $err;
    my @recent = LJ::get_recent_items({
        itemshow  => $count,
        err       => \$err,
        userid    => $u->{userid},
        clusterid => $u->{clusterid},
        remote    => $remote,
    });
    die "Error loading recent items: $err" if $err;

    my @objs;
    foreach my $ri (@recent) {
        my $entry = LJ::Entry->new($u, jitemid => $ri->{itemid});
        push @objs, $entry;
        # FIXME: populate the $entry with security/posterid/alldatepart/ownerid/rlogtime
    }
    return @objs;
}

# front-end to recent_entries, which forces the remote user to be
# the owner, so we get everything.
sub all_recent_entries {
    my $u = shift;
    my %opts = @_;
    $opts{filtered_for} = $u;
    return $u->recent_entries(%opts);
}

sub sms_active_number {
    my $u = shift;
    return LJ::SMS->uid_to_num($u, verified_only => 1);
}

sub sms_pending_number {
    my $u = shift;
    my $num = LJ::SMS->uid_to_num($u, verified_only => 0);
    return undef unless $num;
    return $num if LJ::SMS->num_is_pending($num);
    return undef;
}

# this method returns any mapped number for the user,
# regardless of its verification status
sub sms_mapped_number {
    my $u = shift;
    return LJ::SMS->uid_to_num($u, verified_only => 0);
}

sub sms_active {
    my $u = shift;

    # active if the user has a verified sms number
    return LJ::SMS->configured_for_user($u);
}

sub sms_pending {
    my $u = shift;

    # pending if user has an unverified number
    return LJ::SMS->pending_for_user($u);
}

sub sms_register_time_remaining {
    my $u = shift;

    return LJ::SMS->num_register_time_remaining($u);
}

sub sms_num_instime {
    my $u = shift;

    return LJ::SMS->num_instime($u->sms_mapped_number);
}

sub set_sms_number {
    my ($u, $num, %opts) = @_;
    my $verified = delete $opts{verified};

    # these two are only checked if $num, because it's possible
    # to just pass ($u, undef, undef) to delete the mapping
    if ($num) {
        croak "invalid number" unless $num =~ /^\+\d+$/;
        croak "invalid verified flag" unless $verified =~ /^[YN]$/;
    }

    return LJ::SMS->replace_mapping($u, $num, $verified);
}

sub set_sms_number_verified {
    my ($u, $verified) = @_;

    return LJ::SMS->set_number_verified($u, $verified);
}

sub sms_message_count {
    my $u = shift;
    return LJ::SMS->message_count($u, @_);
}

sub sms_sent_message_count {
    my $u = shift;
    return LJ::SMS->sent_message_count($u, @_);
}

sub delete_sms_number {
    my $u = shift;
    return LJ::SMS->replace_mapping($u, undef);
}

# opts:
#   no_quota = don't check user quota or deduct from their quota for sending a message
sub send_sms {
    my ($u, $msg, %opts) = @_;

    return 0 unless $u;

    croak "invalid user object for object method"
        unless LJ::isu($u);
    croak "invalid LJ::SMS::Message object to send"
        unless $msg && $msg->isa("LJ::SMS::Message");

    my $ret = $msg->send(%opts);

    return $ret;
}

sub send_sms_text {
    my ($u, $msgtext, %opts) = @_;

    my $msg = LJ::SMS::Message->new(
                                    owner => $u,
                                    to    => $u,
                                    type  => 'outgoing',
                                    body_text => $msgtext,
                                    );

    # if user specified a class_key for send, set it on
    # the msg object
    if ($opts{class_key}) {
        $msg->class_key($opts{class_key});
    }

    $msg->send(%opts);
}

sub sms_quota_remaining {
    my ($u, $type) = @_;

    return LJ::SMS->sms_quota_remaining($u, $type);
}

sub add_sms_quota {
    my ($u, $qty, $type) = @_;

    return LJ::SMS->add_sms_quota($u, $qty, $type);
}

sub set_sms_quota {
    my ($u, $qty, $type) = @_;

    return LJ::SMS->set_sms_quota($u, $qty, $type);
}

sub max_sms_bytes {
    my $u = shift;
    return LJ::SMS->max_sms_bytes($u);
}

sub max_sms_substr {
    my ($u, $text, %opts) = @_;
    return LJ::SMS->max_sms_substr($u, $text, %opts);
}

sub subtract_sms_quota {
    my ($u, $qty, $type) = @_;

    return LJ::SMS->subtract_sms_quota($u, $qty, $type);
}

sub is_syndicated {
    my $u = shift;
    return $u->{journaltype} eq "Y";
}

sub is_community {
    my $u = shift;
    return $u->{journaltype} eq "C";
}
*is_comm = \&is_community;

sub is_shared {
    my $u = shift;
    return $u->{journaltype} eq "S";
}

sub is_news {
    my $u = shift;
    return $u->{journaltype} eq "N";
}

sub is_person {
    my $u = shift;
    return $u->{journaltype} eq "P";
}

sub is_identity {
    my $u = shift;
    return $u->{journaltype} eq "I";
}

*has_friend = \&is_friend;
sub is_friend {
    my $ua = shift;
    my $ub = shift;

    return LJ::is_friend($ua, $ub);
}

sub is_mutual_friend {
    my $ua = shift;
    my $ub = shift;

    return 1 if ($ua->is_friend($ub) && $ub->is_friend($ua));
    return 0;
}

sub who_invited {
    my $u = shift;
    my $inviterid = LJ::load_rel_user($u, 'I');

    return LJ::load_userid($inviterid);
}

# front-end to LJ::cmd_buffer_add, which has terrible interface
#   cmd: scalar
#   args: hashref
sub cmd_buffer_add {
    my ($u, $cmd, $args) = @_;
    $args ||= {};
    return LJ::cmd_buffer_add($u->{clusterid}, $u->{userid}, $cmd, $args);
}

sub subscriptions {
    my $u = shift;
    return LJ::Subscription->subscriptions_of_user($u);
}

sub subscription_count {
    my $u = shift;
    return scalar LJ::Subscription->subscriptions_of_user($u);
}

# this is the count used to check the maximum subscription count
sub active_inbox_subscription_count {
    my $u = shift;
    return scalar ( grep { $_->active && $_->enabled } $u->find_subscriptions(method => 'Inbox') );
}

sub max_subscriptions {
    my $u = shift;
    return $u->get_cap('subscriptions');
}

sub can_add_inbox_subscription {
    my $u = shift;
    return $u->active_inbox_subscription_count >= $u->max_subscriptions ? 0 : 1;
}

# subscribe to an event
sub subscribe {
    my ($u, %opts) = @_;
    croak "No subscription options" unless %opts;

    return LJ::Subscription->create($u, %opts);
}

sub subscribe_entry_comments_via_sms {
    my ($u, $entry) = @_;
    croak "Invalid LJ::Entry passed"
        unless $entry && $entry->isa("LJ::Entry");

    # don't subscribe if user is over subscription limit
    return unless $u->can_add_inbox_subscription;

    my %sub_args =
        ( event   => "LJ::Event::JournalNewComment",
          journal => $u,
          arg1    => $entry->ditemid, );

    $u->subscribe
        ( method  => "LJ::NotificationMethod::SMS",
          %sub_args, );

    $u->subscribe
        ( method  => "LJ::NotificationMethod::Inbox",
          %sub_args, );

    return 1;
}

# search for a subscription
*find_subscriptions = \&has_subscription;
sub has_subscription {
    my ($u, %params) = @_;
    croak "No parameters" unless %params;

    return LJ::Subscription->find($u, %params);
}

# interim solution while legacy/ESN notifications are both happening:
# checks possible subscriptions to see if user will get an ESN notification
# THIS IS TEMPORARY. should only be called by talklib.
# params: journal, arg1 (entry ditemid), arg2 (comment talkid)
sub gets_notified {
    my ($u, %params) = @_;

    $params{event} = "LJ::Event::JournalNewComment";
    $params{method} = "LJ::NotificationMethod::Email";

    my $has_sub;

    # did they subscribe to the parent comment?
    $has_sub = LJ::Subscription->find($u, %params);
    return $has_sub if $has_sub;

    # remove the comment-specific parameter, then check for an entry subscription
    $params{arg2} = 0;
    $has_sub = LJ::Subscription->find($u, %params);
    return $has_sub if $has_sub;

    # remove the entry-specific parameter, then check if they're subscribed to the entire journal
    $params{arg1} = 0;
    $has_sub = LJ::Subscription->find($u, %params);
    return $has_sub;
}

# delete all of a user's subscriptions
sub delete_all_subscriptions {
    my $u = shift;
    my @subs = $u->subscriptions;
    $_->delete foreach @subs;
}

# What journals can this user post to?
sub can_post_to {
    my $u = shift;

    my @res;

    my $ids = LJ::load_rel_target($u, 'P');
    my $us = LJ::load_userids(@$ids);
    foreach (values %$us) {
        next unless $_->is_visible;
        push @res, $_;
    }

    return sort { $a->{user} cmp $b->{user} } @res;
}

sub delete_and_purge_completely {
    my $u = shift;
    # TODO: delete from user tables
    # TODO: delete from global tables
    my $dbh = LJ::get_db_writer();

    my @tables = qw(user friends useridmap reluser priv_map infohistory email password);
    foreach my $table (@tables) {
        $dbh->do("DELETE FROM $table WHERE userid=?", undef, $u->id);
    }

    $dbh->do("DELETE FROM friends WHERE friendid=?", undef, $u->id);
    $dbh->do("DELETE FROM reluser WHERE targetid=?", undef, $u->id);

    $dbh->do("DELETE FROM community WHERE userid=?", undef, $u->id)
        if $u->is_community;
    $dbh->do("DELETE FROM syndicated WHERE userid=?", undef, $u->id)
        if $u->is_syndicated;

    return 1;
}

# Returns 'rich' or 'plain' depending on user's
# setting of which editor they would like to use
# and what they last used
sub new_entry_editor {
    my $u = shift;

    my $editor = $u->prop('entry_editor');
    return 'plain' if $editor eq 'always_plain'; # They said they always want plain
    return 'rich' if $editor eq 'always_rich'; # They said they always want rich
    return $editor if $editor =~ /(rich|plain)/; # What did they last use?
    return $LJ::DEFAULT_EDITOR; # Use config default
}

# do some internal consistency checks on self.  die if problems,
# else returns 1.
sub selfassert {
    my $u = shift;
    LJ::assert_is($u->{userid}, $u->{_orig_userid})
        if $u->{_orig_userid};
    LJ::assert_is($u->{user}, $u->{_orig_user})
        if $u->{_orig_user};
    return 1;
}

# Returns the NotificationInbox for this user
*inbox = \&notification_inbox;
sub notification_inbox {
    my $u = shift;
    return LJ::NotificationInbox->new($u);
}

sub new_message_count {
    my $u = shift;
    my $inbox = $u->notification_inbox;
    my $count = $inbox->unread_count;

    return $count || 0;
}

sub add_friend {
    my ($u, $target, $opts) = @_;
    $opts->{nonotify} = 1 if $u->is_friend($target);
    return LJ::add_friend($u, $target, $opts);
}

sub friend_and_watch {
    my ($u, $target, $opts) = @_;
    $opts->{defaultview} = 1;
    $u->add_friend($target, $opts);
}

sub remove_friend {
    my ($u, $target) = @_;
    return LJ::remove_friend($u, $target);
}

sub view_control_strip {
    my $u = shift;

    LJ::run_hook('control_strip_propcheck', $u, 'view_control_strip') unless $LJ::DISABLED{control_strip_propcheck};

    my $prop = $u->raw_prop('view_control_strip');
    return 0 if $prop =~ /^off/;

    return 'dark' if $prop eq 'forced';

    return $prop;
}

sub show_control_strip {
    my $u = shift;

    LJ::run_hook('control_strip_propcheck', $u, 'show_control_strip') unless $LJ::DISABLED{control_strip_propcheck};

    my $prop = $u->raw_prop('show_control_strip');
    return 0 if $prop =~ /^off/;

    return 'dark' if $prop eq 'forced';

    return $prop;
}

# when was this account created?
# returns unixtime
sub timecreate {
    my $u = shift;
    my $dbr = LJ::get_db_reader() or die "No db";
    my $when = $dbr->selectrow_array("SELECT timecreate FROM userusage WHERE userid=?", undef, $u->{userid});
    return undef unless $when;
    return LJ::mysqldate_to_time($when);
}

# can this user use ESN?
sub can_use_esn {
    my $u = shift;
    return 0 if $LJ::DISABLED{esn};
    my $disable = $LJ::DISABLED{esn_ui};
    return 1 unless $disable;

    if (ref $disable eq 'CODE') {
        return $disable->($u) ? 0 : 1;
    }

    return $disable ? 0 : 1;
}

sub can_use_sms {
    my $u = shift;
    return LJ::SMS->can_use_sms($u);
}

sub ajax_auth_token {
    my $u = shift;
    return LJ::Auth->ajax_auth_token($u, @_);
}

sub check_ajax_auth_token {
    my $u = shift;
    return LJ::Auth->check_ajax_auth_token($u, @_);
}

# returns username
*username = \&user;
sub user {
    my $u = shift;
    return $u->{user};
}

sub user_url_arg {
    my $u = shift;
    return "I,$u->{userid}" if $u->{journaltype} eq "I";
    return $u->{user};
}

# returns username for display
sub display_username {
    my $u = shift;
    return $u->display_name if $u->is_identity;
    return $u->{user};
}

# returns the user-specified name of a journal exactly as entered
sub name_orig {
    my $u = shift;
    return $u->{name};
}

# returns the user-specified name of a journal in valid UTF-8
sub name_raw {
    my $u = shift;
    LJ::text_out(\$u->{name});
    return $u->{name};
}

# returns the user-specified name of a journal in valid UTF-8
# and with HTML escaped
sub name_html {
    my $u = shift;
    return LJ::ehtml($u->name_raw);
}

# userid
*userid = \&id;
sub id {
    my $u = shift;
    return $u->{userid};
}

sub clusterid {
    my $u = shift;
    return $u->{clusterid};
}

sub bio {
    my $u = shift;
    return LJ::get_bio($u);
}

# if bio_absent is set to "yes", bio won't be updated
sub set_bio {
    my ($u, $text, $bio_absent) = @_;
    $bio_absent = "" unless $bio_absent;

    my $oldbio = $u->bio;
    my $newbio = $bio_absent eq "yes" ? $oldbio : $text;
    my $has_bio = ($newbio =~ /\S/) ? "Y" : "N";

    my %update = (
        'has_bio' => $has_bio,
    );
    LJ::update_user($u, \%update);

    # update their bio text
    if (($oldbio ne $text) && $bio_absent ne "yes") {
        if ($has_bio eq "N") {
            $u->do("DELETE FROM userbio WHERE userid=?", undef, $u->id);
            $u->dudata_set('B', 0, 0);
        } else {
            $u->do("REPLACE INTO userbio (userid, bio) VALUES (?, ?)",
                   undef, $u->id, $text);
            $u->dudata_set('B', 0, length($text));
        }
        LJ::MemCache::set([$u->id, "bio:" . $u->id], $text);
    }
}

sub opt_ctxpopup {
    my $u = shift;

    # if unset, default to on
    my $prop = $u->raw_prop('opt_ctxpopup') || 'Y';

    return $prop eq 'Y';
}

sub opt_embedplaceholders {
    my $u = shift;

    my $prop = $u->raw_prop('opt_embedplaceholders');

    if (defined $prop) {
        return $prop;
    } else {
        my $imagelinks = $u->prop('opt_imagelinks');
        return $imagelinks;
    }
}

sub opt_showmutualfriends {
    my $u = shift;
    return $u->raw_prop('opt_showmutualfriends') ? 1 : 0;
}

# only certain journaltypes can show mutual friends
sub show_mutualfriends {
    my $u = shift;

    return 0 unless $u->journaltype =~ /[PSI]/;
    return $u->opt_showmutualfriends ? 1 : 0;
}

# find what servers a user is logged in to, and send them an IM
# returns true if sent, false if failure or user not logged on
# Please do not call from web context
sub send_im {
    my ($self, %opts) = @_;

    croak "Can't call in web context" if LJ::is_web_context();

    my $from = delete $opts{from};
    my $msg  = delete $opts{message} or croak "No message specified";

    croak "No from or bot jid defined" unless $from || $LJ::JABBER_BOT_JID;

    my @resources = keys %{LJ::Jabber::Presence->get_resources($self)} or return 0;

    my $res = $resources[0] or return 0; # FIXME: pick correct server based on priority?
    my $pres = LJ::Jabber::Presence->new($self, $res) or return 0;
    my $ip = $LJ::JABBER_SERVER_IP || '127.0.0.1';

    my $sock = IO::Socket::INET->new(PeerAddr => "${ip}:5200")
        or return 0;

    my $vhost = $LJ::DOMAIN;

    my $to_jid   = $self->user   . '@' . $LJ::DOMAIN;
    my $from_jid = $from ? $from->user . '@' . $LJ::DOMAIN : $LJ::JABBER_BOT_JID;

    my $emsg = LJ::exml($msg);
    my $stanza = LJ::eurl(qq{<message to="$to_jid" from="$from_jid"><body>$emsg</body></message>});

    print $sock "send_stanza $vhost $to_jid $stanza\n";

    my $start_time = time();

    while (1) {
        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        select(my $rout=$rin, undef, undef, 1);
        if (vec($rout, fileno($sock), 1)) {
            my $ln = <$sock>;
            return 1 if $ln =~ /^OK/;
        }

        last if time() > $start_time + 5;
    }

    return 0;
}

# returns whether or not the user is online on jabber
sub jabber_is_online {
    my $u = shift;

    return keys %{LJ::Jabber::Presence->get_resources($u)} ? 1 : 0;
}

sub esn_inbox_default_expand {
    my $u = shift;

    my $prop = $u->raw_prop('esn_inbox_default_expand');
    return $prop ne 'N';
}

sub rate_log
{
    my ($u, $ratename, $count, $opts) = @_;
    LJ::rate_log($u, $ratename, $count, $opts);
}

sub statusvis {
    my $u = shift;
    return $u->{statusvis};
}

# TODO: Handle more special cases such as logging to statushistory on suspend, etc.
sub set_statusvis {
    my ($u, $statusvis) = @_;

    croak "Invalid statusvis: $statusvis"
        unless $statusvis =~ /^(?:
            V|       # visible
            D|       # deleted
            X|       # expunged
            S|       # suspended
            L|       # locked
            M|       # memorial
            R        # renamed
                                )$/x;

    # log the change to userlog
    $u->log_event('accountstatus', {
            # remote looked up by log_event
            old => $u->statusvis,
            new => $statusvis,
        });

    # do update
    my $res = LJ::update_user($u, { statusvis => $statusvis,
                                    raw => 'statusvisdate=NOW()' });

    # run any account cancellation hooks
    if ($statusvis eq 'D') {
        LJ::run_hooks("account_delete", $u);
      }

    return $res;
}

sub set_visible {
    my $u = shift;
    return $u->set_statusvis('V');
}

sub set_deleted {
    my $u = shift;
    return $u->set_statusvis('D');
}

sub set_expunged {
    my $u = shift;
    return $u->set_statusvis('X');
}

sub set_suspended {
    my $u = shift;
    return $u->set_statusvis('S');
}

sub set_locked {
    my $u = shift;
    return $u->set_statusvis('L');
}

sub set_memorial {
    my $u = shift;
    return $u->set_statusvis('M');
}

sub set_renamed {
    my $u = shift;
    return $u->set_statusvis('R');
}

# returns if this user is considered visible
sub is_visible {
    my $u = shift;
    return $u->statusvis eq 'V';
}

sub is_deleted {
    my $u = shift;
    return $u->statusvis eq 'D';
}

sub is_expunged {
    my $u = shift;
    return $u->statusvis eq 'X' || $u->clusterid == 0;
}

sub is_suspended {
    my $u = shift;
    return $u->statusvis eq 'S';
}

sub is_locked {
    my $u = shift;
    return $u->statusvis eq 'L';
}

sub is_memorial {
    my $u = shift;
    return $u->statusvis eq 'M';
}

sub is_renamed {
    my $u = shift;
    return $u->statusvis eq 'R';
}

sub caps {
    my $u = shift;
    return $u->{caps};
}

sub number_of_posts {
    my $u = shift;
    my $memkey = [$u->{userid}, "log2ct:$u->{userid}"];
    my $expire = time() + 3600*24*2; # 2 days
    return LJ::MemCache::get_or_set($memkey, sub {
        return $u->selectrow_array("SELECT COUNT(*) FROM log2 WHERE journalid=?",
                                   undef, $u->{userid});
    }, $expire);
}

# return the number of posts that the user actually posted themselves
sub number_of_posted_posts {
    my $u = shift;

    my $num = $u->number_of_posts;
    $num-- if LJ::run_hook('user_has_auto_post', $u);

    return $num;
}

# <LJFUNC>
# des: Given a user object and some options, return the number of posts or the
#      posts IDs(jitemids) that match.
# returns: number of matching posts OR IDs of matching posts(default)
# args: u, opts
# des-opts: 'security' - [public|private|usemask]
#           'allowmask' - integer for friends-only or custom groups
#           'start_date' - UTC date after which to look for match
#           'end_date' - UTC date before which to look for match
#           'return' - if 'count' just return the count
#           TODO: Add caching?
# </LJFUNC>
sub get_post_ids {
    my ($u, %opts) = @_;

    my $query = 'SELECT';
    my @vals; # parameters to query

    if ($opts{'start_date'} || $opts{'end_date'}) {
        croak "start or end date not defined"
            if (!$opts{'start_date'} || !$opts{'end_date'});

        if (!($opts{'start_date'} >= 0) || !($opts{'end_date'} >= 0) ||
            !($opts{'start_date'} <= $LJ::EndOfTime) ||
            !($opts{'end_date'} <= $LJ::EndOfTime) ) {
            return undef;
        }
    }

    # return count or jitemids
    if ($opts{'return'} eq 'count') {
        $query .= " COUNT(*)";
    } else {
        $query .= " jitemid";
    }

    # from the journal entries table for this user
    $query .= " FROM log2 WHERE journalid=?";
    push(@vals, $u->{userid});

    # filter by security
    if ($opts{'security'}) {
        $query .= " AND security=?";
        push(@vals, $opts{'security'});
        # If friends-only or custom
        if ($opts{'security'} eq 'usemask' && $opts{'allowmask'}) {
            $query .= " AND allowmask=?";
            push(@vals, $opts{'allowmask'});
        }
    }

    # filter by date, use revttime as it is indexed
    if ($opts{'start_date'} && $opts{'end_date'}) {
        # revttime is reverse event time
        my $s_date = $LJ::EndOfTime - $opts{'start_date'};
        my $e_date = $LJ::EndOfTime - $opts{'end_date'};
        $query .= " AND revttime<?";
        push(@vals, $s_date);
        $query .= " AND revttime>?";
        push(@vals, $e_date);
    }

    # return count or jitemids
    if ($opts{'return'} eq 'count') {
        return $u->selectrow_array($query, undef, @vals);
    } else {
        my $jitemids = $u->selectcol_arrayref($query, undef, @vals) || [];
        die $u->errstr if $u->err;
        return @$jitemids;
    }
}

sub get_post_count {
    my ($u, %opts) = @_;

    $opts{return} = 'count';

    return $u->get_post_ids(%opts);
}

sub password {
    my $u = shift;
    $u->{_password} ||= LJ::MemCache::get_or_set([$u->{userid}, "pw:$u->{userid}"], sub {
        my $dbh = LJ::get_db_writer() or die "Couldn't get db master";
        return $dbh->selectrow_array("SELECT password FROM password WHERE userid=?",
                                     undef, $u->id);
    });
    return $u->{_password} || $u->{password};  # the || is for old-style in-user-table
}

sub journaltype {
    my $u = shift;
    return $u->{journaltype};
}

sub friends {
    my $u = shift;
    my @friendids = $u->friend_uids;
    my $users = LJ::load_userids(@friendids);
    return values %$users if wantarray;
    return $users;
}

# the count of friends that the user has added
# -- eg, not initial friends auto-added for them
sub friends_added_count {
    my $u = shift;

    my %initial = ( map { $_ => 1 } @LJ::INITIAL_FRIENDS, @LJ::INITIAL_OPTIONAL_FRIENDS, $u->user );

    # return count of friends who were not initial
    return scalar grep { ! $initial{$_->user} } $u->friends;
}

sub set_password {
    my ($u, $password) = @_;
    return LJ::set_password($u->id, $password);
}

sub set_email {
    my ($u, $email) = @_;
    return LJ::set_email($u->id, $email);
}

# returns array of friendof uids.  by default, limited at 50,000 items.
sub friendof_uids {
    my ($u, %args) = @_;
    my $limit = int(delete $args{limit}) || 50000;
    Carp::croak("unknown option") if %args;

    return $u->_friend_friendof_uids(limit => $limit, mode => "friendofs");
}

# returns array of friend uids.  by default, limited at 50,000 items.
sub friend_uids {
    my ($u, %args) = @_;
    my $limit = int(delete $args{limit}) || 50000;
    Carp::croak("unknown option") if %args;

    return $u->_friend_friendof_uids(limit => $limit, mode => "friends");
}


# helper method since the logic for both friends and friendofs is so similar
sub _friend_friendof_uids {
    my ($u, %args) = @_;
    my $limit = int(delete $args{limit}) || 50000;
    my $mode = delete $args{mode};
    Carp::croak("unknown option") if %args;

    my $sql;
    my $memkey;

    if ($mode eq "friends") {
        $sql = "SELECT friendid FROM friends WHERE userid=? LIMIT $limit";
        $memkey = [$u->id, "friends2:" . $u->id];
    } elsif ($mode eq "friendofs") {
        $sql = "SELECT userid FROM friends WHERE friendid=? LIMIT $limit";
        $memkey = [$u->id, "friendofs2:" . $u->id];
    } else {
        Carp::croak("mode must either be 'friends' or 'friendofs'");
    }

    if (my $pack = LJ::MemCache::get($memkey)) {
        my ($slimit, @uids) = unpack("N*", $pack);
        # value in memcache is good if stored limit (from last time)
        # is >= the limit currently being requested.  we just made
        # have to truncate it to match the requested limit
        if ($slimit >= $limit) {
            @uids = @uids[0..$limit-1] if @uids > $limit;
            return @uids;
        }

        # value in memcache is also good if number of items is less
        # than the stored limit... because then we know it's the full
        # set that got stored, not a truncated version.
        return @uids if @uids < $slimit;
    }

    my $dbh = LJ::get_db_writer();
    my $uids = $dbh->selectcol_arrayref($sql, undef, $u->id);
    LJ::MemCache::add($memkey, pack("N*", $limit, @$uids), 3600) if $uids;

    return @$uids;
}


sub fb_push {
    my $u = shift;
    return unless $u && $u->get_cap("fb_account");
    return Apache::LiveJournal::Interface::FotoBilder::push_user_info( $u->id );
}

sub grant_priv {
    my ($u, $priv, $arg) = @_;
    $arg ||= "";
    my $dbh = LJ::get_db_writer();

    return 1 if LJ::check_priv($u, $priv, $arg);

    my $privid = $dbh->selectrow_array("SELECT prlid FROM priv_list".
                                       " WHERE privcode = ?", undef, $priv);
    $dbh->do("INSERT INTO priv_map (userid, prlid, arg) VALUES (?, ?, ?)",
             undef, $u->id, $privid, $arg);
    return 0 if $dbh->err;

    undef $u->{'_privloaded'}; # to force reloading of privs later
    return 1;
}

sub revoke_priv {
    my ($u, $priv, $arg) = @_;
    $arg ||="";
    my $dbh = LJ::get_db_writer();

    return 1 unless LJ::check_priv($u, $priv, $arg);

    my $privid = $dbh->selectrow_array("SELECT prlid FROM priv_list".
                                       " WHERE privcode = ?", undef, $priv);
    $dbh->do("DELETE FROM priv_map WHERE userid = ? AND prlid = ? AND arg = ?",
             undef, $u->id, $privid, $arg);
    return 0 if $dbh->err;

    undef $u->{'_privloaded'}; # to force reloading of privs later
    undef $u->{'_priv'};
    return 1;
}

sub revoke_priv_all {
    my ($u, $priv) = @_;
    my $dbh = LJ::get_db_writer();

    my $privid = $dbh->selectrow_array("SELECT prlid FROM priv_list".
                                       " WHERE privcode = ?", undef, $priv);
    $dbh->do("DELETE FROM priv_map WHERE userid = ? AND prlid = ?",
             undef, $u->id, $privid);
    return 0 if $dbh->err;

    undef $u->{'_privloaded'}; # to force reloading of privs later
    undef $u->{'_priv'};
    return 1;
}

# must be called whenever birthday, location, journal modtime, journaltype, etc.
# changes.  see LJ/Directory/PackedUserRecord.pm
sub invalidate_directory_record {
    my $u = shift;

    # Future: ?
    # LJ::try_our_best_to("invalidate_directory_record", $u->id);
    # then elsewhere, map that key to subref.  if primary run fails,
    # put in schwartz, then have one worker (misc-deferred) to
    # redo...

    my $dbh = LJ::get_db_writer();
    $dbh->do("UPDATE usersearch_packdata SET good_until=0 WHERE userid=?",
             undef, $u->id);
}

# Used to promote communities in interest search results
sub render_promo_of_community {
    my ($comm, $style) = @_;

    return undef unless $comm;

    $style ||= 'Vertical';

    # get the ljuser link
    my $commljuser = $comm->ljuser_display;

    # link to journal
    my $journal_base = $comm->journal_base;

    # get default userpic if any
    my $userpic = $comm->userpic;
    my $userpic_html = '';
    if ($userpic) {
        my $userpic_url = $userpic->url;
        $userpic_html = qq { <a href="$journal_base"><img src="$userpic_url" /></a> };
    }

    my $blurb = $comm->prop('comm_promo_blurb') || '';

    my $join_link = "$LJ::SITEROOT/community/join.bml?comm=$comm->{user}";
    my $watch_link = "$LJ::SITEROOT/friends/add.bml?user=$comm->{user}";
    my $read_link = $comm->journal_base;

    LJ::need_res("stc/lj_base.css");

    # if horizontal, userpic needs to come before everything
    my $box_class;
    my $comm_display;

    if (lc $style eq 'horizontal') {
        $box_class = 'Horizontal';
        $comm_display = qq {
            <div class="Userpic">$userpic_html</div>
            <div class="Title">LJ Community Promo</div>
            <div class="CommLink">$commljuser</div>
        };
    } else {
        $box_class = 'Vertical';
        $comm_display = qq {
            <div class="Title">LJ Community Promo</div>
            <div class="CommLink">$commljuser</div>
            <div class="Userpic">$userpic_html</div>
        };
    }


    my $html = qq {
        <div class="CommunityPromoBox">
            <div class="$box_class">
                $comm_display
                <div class="Blurb">$blurb</div>
                <div class="Links"><a href="$join_link">Join</a> | <a href="$watch_link">Watch</a> |
                    <a href="$read_link">Read</a></div>

                <div class='ljclear'>&nbsp;</div>
            </div>
        </div>
    };

    return $html;
}

# Check to see if the user can use eboxes at all
sub can_use_ebox {
    my $u = shift;

    return ref $LJ::DISABLED{ebox} ? !$LJ::DISABLED{ebox}->($u) : !$LJ::DISABLED{ebox};
}

# Allow users to choose eboxes if:
# 1. The entire ebox feature isn't disabled AND
# 2. The option to choose eboxes isn't disabled OR
# 3. The option to choose eboxes is disabled AND
# 4. The user already has eboxes turned on
sub can_use_ebox_ui {
    my $u = shift;
    my $allow_ebox = 1;

    if ($LJ::DISABLED{ebox_option}) {
        $allow_ebox = $u->prop('journal_box_entries');
    }

    return $u->can_use_ebox && $allow_ebox;
}

# return hashref with intname => intid
sub interests {
    my $u = shift;
    my $uints = LJ::get_interests($u);
    my %interests;

    foreach my $int (@$uints) {
        $interests{$int->[1]} = $int->[0];  # $interests{name} = intid
    }

    return \%interests;
}

sub interest_count {
    my $u = shift;

    # FIXME: fall back to SELECT COUNT(*) if not cached already?
    return scalar @{LJ::get_interests($u, { justids => 1 })};
}

sub set_interests {
    my $u = shift;
    LJ::set_interests($u, @_);
}

# this will return a hash of information about this user.
# this is useful for javascript endpoints which need to dump
# JSON data about users.
sub info_for_js {
    my $u = shift;

    my %ret = (
               username         => $u->user,
               display_username => $u->display_username,
               display_name     => $u->display_name,
               userid           => $u->userid,
               url_journal      => $u->journal_base,
               url_profile      => $u->profile_url,
               url_allpics      => $u->allpics_base,
               ljuser_tag       => $u->ljuser_display,
               is_comm          => $u->is_comm,
               is_person        => $u->is_person,
               is_syndicated    => $u->is_syndicated,
               is_identity      => $u->is_identity,
               is_shared        => $u->is_shared,
               );

    my $up = $u->userpic;

    if ($up) {
        $ret{url_userpic} = $up->url;
        $ret{userpic_w}   = $up->width;
        $ret{userpic_h}   = $up->height;
    }

    return %ret;
}

sub postreg_completed {
    my $u = shift;

    return 0 unless $u->bio;
    return 0 unless $u->interest_count;
    return 1;
}

# return if $target is banned from $u's journal
*has_banned = \&is_banned;
sub is_banned {
    my ($u, $target) = @_;
    return LJ::is_banned($target->userid, $u->userid);
}

# return if $target is in $fgroupid
sub user_in_friend_group {
    my ($u, $target, $fgroupid) = @_;
    return 0 unless $u->is_friend($target);

    my $grpmask = 1 << $fgroupid;
    my $frmask = LJ::get_groupmask($u, $target);
    return 0 unless $grpmask && $frmask;

    return $grpmask & $frmask;
}

# returns if this user's polls are clustered
sub polls_clustered {
    my $u = shift;
    return $u->dversion >= 8;
}

sub dversion {
    my $u = shift;
    return $u->{dversion};
}

# take a user on dversion 7 and upgrade them to dversion 8 (clustered polls)
sub upgrade_to_dversion_8 {
    my $u = shift;

    my $ok = LJ::Poll->make_polls_clustered($u);

    LJ::update_user($u, { 'dversion' => 8 }) if $ok;

    return $ok;
}

# can this user add any more friends?
sub can_add_friends {
    my ($u, $err, $opts) = @_;

    # have they reached their friend limit?
    my $fr_count = $opts->{'numfriends'} || $u->friend_uids;
    my $maxfriends = $u->get_cap('maxfriends');
    if ($fr_count >= $maxfriends) {
        $$err = "You have reached your limit of $maxfriends friends.";
        return 0;
    }

    # are they trying to add friends too quickly?
    unless ($u->rate_log('addfriend', 1)) {
        $$err = "You are trying to add too many friends in too short a period of time.";
        return 0;
    }

    return 1;
}

package LJ;

use Carp;

# <LJFUNC>
# name: LJ::get_authas_list
# des: Get a list of usernames a given user can authenticate as
# returns: an array of usernames
# args: u, opts?
# des-opts: Optional hashref.  keys are:
#           - type: 'P' to only return users of journaltype 'P'
#           - cap:  cap to filter users on
# </LJFUNC>
sub get_authas_list {
    my ($u, $opts) = @_;

    # used to accept a user type, now accept an opts hash
    $opts = { 'type' => $opts } unless ref $opts;

    # Two valid types, Personal or Community
    $opts->{'type'} = undef unless $opts->{'type'} =~ m/^(P|C)$/;

    my $ids = LJ::load_rel_target($u, 'A');
    return undef unless $ids;

    # load_userids_multiple
    my %users;
    LJ::load_userids_multiple([ map { $_, \$users{$_} } @$ids ], [$u]);

    return map { $_->{'user'} }
               grep { ! $opts->{'cap'} || LJ::get_cap($_, $opts->{'cap'}) }
               grep { ! $opts->{'type'} || $opts->{'type'} eq $_->{'journaltype'} }

               # unless overridden, hide non-visible journals. always display the user's acct
               grep { $opts->{'showall'} || $_->is_visible || LJ::u_equals($_, $u) }

               # can't work as an expunged account
               grep { !$_->is_expunged && $_->{clusterid} > 0 }
               $u,  sort { $a->{'user'} cmp $b->{'user'} } values %users;
}

# <LJFUNC>
# name: LJ::get_postto_list
# des: Get a list of usernames a given user can post to
# returns: an array of usernames
# args: u, opts?
# des-opts: Optional hashref.  keys are:
#           - type: 'P' to only return users of journaltype 'P'
#           - cap:  cap to filter users on
# </LJFUNC>
sub get_postto_list {
    my ($u, $opts) = @_;

    # used to accept a user type, now accept an opts hash
    $opts = { 'type' => $opts } unless ref $opts;

    # only one valid type right now
    $opts->{'type'} = 'P' if $opts->{'type'};

    my $ids = LJ::load_rel_target($u, 'P');
    return undef unless $ids;

    # load_userids_multiple
    my %users;
    LJ::load_userids_multiple([ map { $_, \$users{$_} } @$ids ], [$u]);

    return $u->{'user'}, sort map { $_->{'user'} }
                         grep { ! $opts->{'cap'} || LJ::get_cap($_, $opts->{'cap'}) }
                         grep { ! $opts->{'type'} || $opts->{'type'} eq $_->{'journaltype'} }
                         grep { $_->clusterid > 0 }
                         grep { $_->is_visible }
                         values %users;
}

# <LJFUNC>
# name: LJ::can_view
# des: Checks to see if the remote user can view a given journal entry.
#      <b>Note:</b> This is meant for use on single entries at a time,
#      not for calling many times on every entry in a journal.
# returns: boolean; 1 if remote user can see item
# args: remote, item
# des-item: Hashref from the 'log' table.
# </LJFUNC>
sub can_view
{
    &nodb;
    my $remote = shift;
    my $item = shift;

    # public is okay
    return 1 if $item->{'security'} eq "public";

    # must be logged in otherwise
    return 0 unless $remote;

    my $userid = int($item->{'ownerid'} || $item->{'journalid'});
    my $remoteid = int($remote->{'userid'});

    # owners can always see their own.
    return 1 if ($userid == $remoteid);

    # other people can't read private
    return 0 if ($item->{'security'} eq "private");

    # should be 'usemask' security from here out, otherwise
    # assume it's something new and return 0
    return 0 unless ($item->{'security'} eq "usemask");

    # if it's usemask, we have to refuse non-personal journals,
    # so we have to load the user
    return 0 unless $remote->{'journaltype'} eq 'P' || $remote->{'journaltype'} eq 'I';

    # TAG:FR:ljlib:can_view  (turn off bit 0 for just watching?  hmm.)
    my $gmask = LJ::get_groupmask($userid, $remoteid);
    my $allowed = (int($gmask) & int($item->{'allowmask'}));
    return $allowed ? 1 : 0;  # no need to return matching mask
}

# <LJFUNC>
# name: LJ::wipe_major_memcache
# des:  invalidate all major memcache items associated with a given user
# args: u
# returns: nothing
# </LJFUNC>
sub wipe_major_memcache
{
    my $u = shift;
    my $userid = LJ::want_userid($u);
    foreach my $key ("userid","bio","talk2ct","talkleftct","log2ct",
                     "log2lt","memkwid","dayct","s1overr","s1uc","fgrp",
                     "friends","friendofs","tu","upicinf","upiccom",
                     "upicurl", "intids", "memct", "lastcomm")
    {
        LJ::memcache_kill($userid, $key);
    }
}

# <LJFUNC>
# name: LJ::load_user_props
# des: Given a user hashref, loads the values of the given named properties
#      into that user hashref.
# args: dbarg?, u, opts?, propname*
# des-opts: hashref of opts.  set key 'cache' to use memcache.
# des-propname: the name of a property from the userproplist table.
# </LJFUNC>
sub load_user_props
{
    &nodb;

    my $u = shift;
    return unless isu($u);
    return if $u->is_expunged;

    my $opts = ref $_[0] ? shift : {};
    my (@props) = @_;

    my ($sql, $sth);
    LJ::load_props("user");

    ## user reference
    my $uid = $u->{'userid'}+0;
    $uid = LJ::get_userid($u->{'user'}) unless $uid;

    my $mem = {};
    my $use_master = 0;
    my $used_slave = 0;  # set later if we ended up using a slave

    if (@LJ::MEMCACHE_SERVERS) {
        my @keys;
        foreach (@props) {
            next if exists $u->{$_};
            my $p = LJ::get_prop("user", $_);
            die "Invalid userprop $_ passed to LJ::load_user_props." unless $p;
            push @keys, [$uid,"uprop:$uid:$p->{'id'}"];
        }
        $mem = LJ::MemCache::get_multi(@keys) || {};
        $use_master = 1;
    }

    $use_master = 1 if $opts->{'use_master'};

    my @needwrite;  # [propid, propname] entries we need to save to memcache later

    my %loadfrom;
    my %multihomed; # ( $propid => 0/1 ) # 0 if we haven't loaded it, 1 if we have
    unless (@props) {
        # case 1: load all props for a given user.
        # multihomed props are stored on userprop and userproplite2, but since they
        # should always be in sync, it doesn't matter which gets loaded first, the
        # net results should be the same.  see doc/designnotes/multihomed_props.txt
        # for more information.
        $loadfrom{'userprop'} = 1;
        $loadfrom{'userproplite'} = 1;
        $loadfrom{'userproplite2'} = 1;
        $loadfrom{'userpropblob'} = 1;
    } else {
        # case 2: load only certain things
        foreach (@props) {
            next if exists $u->{$_};
            my $p = LJ::get_prop("user", $_);
            die "Invalid userprop $_ passed to LJ::load_user_props." unless $p;
            if (defined $mem->{"uprop:$uid:$p->{'id'}"}) {
                $u->{$_} = $mem->{"uprop:$uid:$p->{'id'}"};
                next;
            }
            push @needwrite, [ $p->{'id'}, $_ ];
            my $source = $p->{'indexed'} ? "userprop" : "userproplite";
            if ($p->{datatype} eq 'blobchar') {
                $source = "userpropblob"; # clustered blob
            }
            elsif ($p->{'cldversion'} && $u->{'dversion'} >= $p->{'cldversion'}) {
                $source = "userproplite2";  # clustered
            }
            elsif ($p->{multihomed}) {
                $multihomed{$p->{id}} = 0;
                $source = "userproplite2";
            }
            push @{$loadfrom{$source}}, $p->{'id'};
        }
    }

    foreach my $table (qw{userproplite userproplite2 userpropblob userprop}) {
        next unless exists $loadfrom{$table};
        my $db;
        if ($use_master) {
            $db = ($table =~ m{userprop(lite2|blob)}) ?
                LJ::get_cluster_master($u) :
                LJ::get_db_writer();
        }
        unless ($db) {
            $db = ($table =~ m{userprop(lite2|blob)}) ?
                LJ::get_cluster_reader($u) :
                LJ::get_db_reader();
            $used_slave = 1;
        }
        $sql = "SELECT upropid, value FROM $table WHERE userid=$uid";
        if (ref $loadfrom{$table}) {
            $sql .= " AND upropid IN (" . join(",", @{$loadfrom{$table}}) . ")";
        }
        $sth = $db->prepare($sql);
        $sth->execute;
        while (my ($id, $v) = $sth->fetchrow_array) {
            delete $multihomed{$id} if $table eq 'userproplite2';
            $u->{$LJ::CACHE_PROPID{'user'}->{$id}->{'name'}} = $v;
        }

        # push back multihomed if necessary
        if ($table eq 'userproplite2') {
            push @{$loadfrom{userprop}}, $_ foreach keys %multihomed;
        }
    }

    # see if we failed to get anything above and need to hit the master.
    # this usually happens the first time a multihomed prop is hit.  this
    # code will propogate that prop down to the cluster.
    if (%multihomed) {

        # verify that we got the database handle before we try propogating data
        if ($u->writer) {
            my @values;
            foreach my $id (keys %multihomed) {
                my $pname = $LJ::CACHE_PROPID{user}{$id}{name};
                if (defined $u->{$pname} && $u->{$pname}) {
                    push @values, "($uid, $id, " . $u->quote($u->{$pname}) . ")";
                } else {
                    push @values, "($uid, $id, '')";
                }
            }
            $u->do("REPLACE INTO userproplite2 VALUES " . join ',', @values);
        }
    }

    # Add defaults to user object.

    # defaults for S1 style IDs in config file are magic: really
    # uniq strings representing style IDs, so on first use, we need
    # to map them
    unless ($LJ::CACHED_S1IDMAP) {

        my $pubsty = LJ::S1::get_public_styles();
        foreach (values %$pubsty) {
            my $k = "s1_$_->{'type'}_style";
            next unless $LJ::USERPROP_DEF{$k} eq "$_->{'type'}/$_->{'styledes'}";

            $LJ::USERPROP_DEF{$k} = $_->{'styleid'};
        }

        $LJ::CACHED_S1IDMAP = 1;
    }

    # If this was called with no @props, then the function tried
    # to load all metadata.  but we don't know what's missing, so
    # try to apply all defaults.
    unless (@props) { @props = keys %LJ::USERPROP_DEF; }

    foreach my $prop (@props) {
        next if (defined $u->{$prop});
        $u->{$prop} = $LJ::USERPROP_DEF{$prop};
    }

    unless ($used_slave) {
        my $expire = time() + 3600*24;
        foreach my $wr (@needwrite) {
            my ($id, $name) = ($wr->[0], $wr->[1]);
            LJ::MemCache::set([$uid,"uprop:$uid:$id"], $u->{$name} || "", $expire);
        }
    }
}

# simple interface to LJ::load_userids_multiple.  takes userids,
# returns hashref with keys ids, values $u refs.
sub load_userids
{
    my %u;
    LJ::load_userids_multiple([ map { $_ => \$u{$_} } @_ ]);
    return \%u;
}

# <LJFUNC>
# name: LJ::load_userids_multiple
# des: Loads a number of users at once, efficiently.
# info: loads a few users at once, their userids given in the keys of $map
#       listref (not hashref: can't have dups).  values of $map listref are
#       scalar refs to put result in.  $have is an optional listref of user
#       object caller already has, but is too lazy to sort by themselves.
# args: dbarg?, map, have, memcache_only?
# des-map: Arrayref of pairs (userid, destination scalarref)
# des-have: Arrayref of user objects caller already has
# des-memcache_only: Flag to only retrieve data from memcache
# returns: Nothing.
# </LJFUNC>
sub load_userids_multiple
{
    &nodb;
    # the $have parameter is deprecated, as is $memcache_only, but it's still preserved for now.
    # actually this whole API is crap.  use LJ::load_userids() instead.
    my ($map, undef, $memcache_only) = @_;

    my $sth;
    my @have;
    my %need;
    while (@$map) {
        my $id = shift @$map;
        my $ref = shift @$map;
        next unless int($id);
        push @{$need{$id}}, $ref;

        if ($LJ::REQ_CACHE_USER_ID{$id}) {
            push @have, $LJ::REQ_CACHE_USER_ID{$id};
        }
    }

    my $satisfy = sub {
        my $u = shift;
        next unless ref $u eq "LJ::User";

        # this could change the $u returned to an
        # existing one we already have loaded in memory,
        # once it's been upgraded.  then everybody points
        # to the same one.
        $u = _set_u_req_cache($u);

        foreach (@{$need{$u->{'userid'}}}) {
            # check if existing target is defined and not what we already have.
            if (my $eu = $$_) {
                LJ::assert_is($u->{userid}, $eu->{userid});
            }
            $$_ = $u;
        }

        delete $need{$u->{'userid'}};
    };

    unless ($LJ::_PRAGMA_FORCE_MASTER) {
        foreach my $u (@have) {
            $satisfy->($u);
        }

        if (%need) {
            foreach (LJ::memcache_get_u(map { [$_,"userid:$_"] } keys %need)) {
                $satisfy->($_);
            }
        }
    }

    if (%need && ! $memcache_only) {
        my $db = @LJ::MEMCACHE_SERVERS || $LJ::_PRAGMA_FORCE_MASTER ?
            LJ::get_db_writer() : LJ::get_db_reader();

        _load_user_raw($db, "userid", [ keys %need ], sub {
            my $u = shift;
            LJ::memcache_set_u($u);
            $satisfy->($u);
        });
    }
}

# des-db:  $dbh/$dbr
# des-key:  either "userid" or "user"  (the WHERE part)
# des-vals: value or arrayref of values for key to match on
# des-hoook: optional code ref to run for each $u
# returns: last $u found
sub _load_user_raw
{
    my ($db, $key, $vals, $hook) = @_;
    $hook ||= sub {};
    $vals = [ $vals ] unless ref $vals eq "ARRAY";

    my $use_isam;
    unless ($LJ::CACHE_NO_ISAM{user} || scalar(@$vals) > 10) {
        eval { $db->do("HANDLER user OPEN"); };
        if ($@ || $db->err) {
            $LJ::CACHE_NO_ISAM{user} = 1;
        } else {
            $use_isam = 1;
        }
    }

    my $last;

    if ($use_isam) {
        $key = "PRIMARY" if $key eq "userid";
        foreach my $v (@$vals) {
            my $sth = $db->prepare("HANDLER user READ `$key` = (?) LIMIT 1");
            $sth->execute($v);
            my $row = $sth->fetchrow_hashref;
            if ($row) {
                my $u = LJ::User->new_from_row($row);
                $hook->($u);
                $last = $u;
            }
        }
        $db->do("HANDLER user close");
    } else {
        my $in = join(", ", map { $db->quote($_) } @$vals);
        my $sth = $db->prepare("SELECT * FROM user WHERE $key IN ($in)");
        $sth->execute;
        while (my $row = $sth->fetchrow_hashref) {
            my $u = LJ::User->new_from_row($row);
            $hook->($u);
            $last = $u;
        }
    }

    return $last;
}

sub _set_u_req_cache {
    my $u = shift or die "no u to set";

    # if we have an existing user singleton, upgrade it with
    # the latested data, but keep using its address
    if (my $eu = $LJ::REQ_CACHE_USER_ID{$u->{'userid'}}) {
        LJ::assert_is($eu->{userid}, $u->{userid});
        $eu->selfassert;
        $u->selfassert;

        $eu->{$_} = $u->{$_} foreach keys %$u;
        $u = $eu;
    }
    $LJ::REQ_CACHE_USER_NAME{$u->{'user'}} = $u;
    $LJ::REQ_CACHE_USER_ID{$u->{'userid'}} = $u;
    return $u;
}

sub load_user_or_identity {
    my $arg = shift;

    my $user = LJ::canonical_username($arg);
    return LJ::load_user($user) if $user;

    # return undef if not dot in arg (can't be a URL)
    return undef unless $arg =~ /\./;

    my $dbh = LJ::get_db_writer();
    my $url = lc($arg);
    $url = "http://$url" unless $url =~ m!^http://!;
    $url .= "/" unless $url =~ m!/$!;
    my $uid = $dbh->selectrow_array("SELECT userid FROM identitymap WHERE idtype=? AND identity=?",
                                    undef, 'O', $url);
    return LJ::load_userid($uid) if $uid;
    return undef;
}

# load either a username, or a "I,<userid>" parameter.
sub load_user_arg {
    my ($arg) = @_;
    my $user = LJ::canonical_username($arg);
    return LJ::load_user($user) if length $user;
    if ($arg =~ /^I,(\d+)$/) {
        my $u = LJ::load_userid($1);
        return $u if $u->is_identity;
    }
    return; # undef/()
}

# <LJFUNC>
# name: LJ::load_user
# des: Loads a user record given a username.
# info: From the [dbarg[user]] table.
# args: dbarg?, user, force?
# des-user: Username of user to load.
# des-force: if set to true, won't return cached user object and will
#            query a dbh
# returns: Hashref with keys being columns of [dbtable[user]] table.
# </LJFUNC>
sub load_user
{
    &nodb;
    my ($user, $force) = @_;

    $user = LJ::canonical_username($user);
    return undef unless length $user;

    my $get_user = sub {
        my $use_dbh = shift;
        my $db = $use_dbh ? LJ::get_db_writer() : LJ::get_db_reader();
        my $u = _load_user_raw($db, "user", $user)
            or return undef;

        # set caches since we got a u from the master
        LJ::memcache_set_u($u) if $use_dbh;

        return _set_u_req_cache($u);
    };

    # caller is forcing a master, return now
    return $get_user->("master") if $force || $LJ::_PRAGMA_FORCE_MASTER;

    my $u;

    # return process cache if we have one
    if ($u = $LJ::REQ_CACHE_USER_NAME{$user}) {
        $u->selfassert;
        return $u;
    }

    # check memcache
    {
        my $uid = LJ::MemCache::get("uidof:$user");
        $u = LJ::memcache_get_u([$uid, "userid:$uid"]) if $uid;
        return _set_u_req_cache($u) if $u;
    }

    # try to load from master if using memcache, otherwise from slave
    $u = $get_user->(scalar @LJ::MEMCACHE_SERVERS);
    return $u if $u;

    # setup LDAP handler if this is the first time
    if ($LJ::LDAP_HOST && ! $LJ::AUTH_EXISTS) {
        require LJ::LDAP;
        $LJ::AUTH_EXISTS = sub {
            my $user = shift;
            my $rec = LJ::LDAP::load_ldap_user($user);
            return $rec ? $rec : undef;
        };
    }

    # if user doesn't exist in the LJ database, it's possible we're using
    # an external authentication source and we should create the account
    # implicitly.
    my $lu;
    if (ref $LJ::AUTH_EXISTS eq "CODE" && ($lu = $LJ::AUTH_EXISTS->($user)))
    {
        my $name = ref $lu eq "HASH" ? ($lu->{'nick'} || $lu->{name} || $user) : $user;
        if (LJ::create_account({
            'user' => $user,
            'name' => $name,
            'email' => ref $lu eq "HASH" ? $lu->email_raw : "",
            'password' => "",
        }))
        {
            # this should pull from the master, since it was _just_ created
            return $get_user->("master");
        }
    }

    return undef;
}

# <LJFUNC>
# name: LJ::u_equals
# des: Compares two user objects to see if they're the same user.
# args: userobj1, userobj2
# des-userobj1: First user to compare.
# des-userobj2: Second user to compare.
# returns: Boolean, true if userobj1 and userobj2 are defined and have equal userids.
# </LJFUNC>
sub u_equals {
    my ($u1, $u2) = @_;
    return $u1 && $u2 && $u1->{'userid'} == $u2->{'userid'};
}

# <LJFUNC>
# name: LJ::load_userid
# des: Loads a user record given a userid.
# info: From the [dbarg[user]] table.
# args: dbarg?, userid, force?
# des-userid: Userid of user to load.
# des-force: if set to true, won't return cached user object and will
#            query a dbh
# returns: Hashref with keys being columns of [dbtable[user]] table.
# </LJFUNC>
sub load_userid
{
    &nodb;
    my ($userid, $force) = @_;
    return undef unless $userid;

    my $get_user = sub {
        my $use_dbh = shift;
        my $db = $use_dbh ? LJ::get_db_writer() : LJ::get_db_reader();
        my $u = _load_user_raw($db, "userid", $userid)
            or return undef;

        LJ::memcache_set_u($u) if $use_dbh;
        return _set_u_req_cache($u);
    };

    # user is forcing master, return now
    return $get_user->("master") if $force || $LJ::_PRAGMA_FORCE_MASTER;

    my $u;

    # check process cache
    $u = $LJ::REQ_CACHE_USER_ID{$userid};
    if ($u) {
        $u->selfassert;
        return $u;
    }

    # check memcache
    $u = LJ::memcache_get_u([$userid,"userid:$userid"]);
    return _set_u_req_cache($u) if $u;

    # get from master if using memcache
    return $get_user->("master") if @LJ::MEMCACHE_SERVERS;

    # check slave
    $u = $get_user->();
    return $u if $u;

    # if we didn't get a u from the reader, fall back to master
    return $get_user->("master");
}

sub memcache_get_u
{
    my @keys = @_;
    my @ret;
    foreach my $ar (values %{LJ::MemCache::get_multi(@keys) || {}}) {
        my $row = LJ::MemCache::array_to_hash("user", $ar)
            or next;
        my $u = LJ::User->new_from_row($row);
        push @ret, $u;
    }
    return wantarray ? @ret : $ret[0];
}

sub memcache_set_u
{
    my $u = shift;
    return unless $u;
    my $expire = time() + 1800;
    my $ar = LJ::MemCache::hash_to_array("user", $u);
    return unless $ar;
    LJ::MemCache::set([$u->{'userid'}, "userid:$u->{'userid'}"], $ar, $expire);
    LJ::MemCache::set("uidof:$u->{user}", $u->{userid});
}

# <LJFUNC>
# name: LJ::get_bio
# des: gets a user bio, from db or memcache
# args: u, force
# des-force: true to get data from cluster master
# returns: string
# </LJFUNC>
sub get_bio {
    my ($u, $force) = @_;
    return unless $u && $u->{'has_bio'} eq "Y";

    my $bio;

    my $memkey = [$u->{'userid'}, "bio:$u->{'userid'}"];
    unless ($force) {
        my $bio = LJ::MemCache::get($memkey);
        return $bio if defined $bio;
    }

    # not in memcache, fall back to disk
    my $db = @LJ::MEMCACHE_SERVERS || $force ?
      LJ::get_cluster_def_reader($u) : LJ::get_cluster_reader($u);
    $bio = $db->selectrow_array("SELECT bio FROM userbio WHERE userid=?",
                                undef, $u->{'userid'});

    # set in memcache
    LJ::MemCache::add($memkey, $bio);

    return $bio;
}

# <LJFUNC>
# name: LJ::journal_base
# des: Returns URL of a user's journal.
# info: The tricky thing is that users with underscores in their usernames
#       can't have some_user.site.com as a hostname, so that's changed into
#       some-user.site.com.
# args: uuser, vhost?
# des-uuser: User hashref or username of user whose URL to make.
# des-vhost: What type of URL.  Acceptable options are "users", to make a
#            http://user.site.com/ URL; "tilde" to make http://site.com/~user/;
#            "community" for http://site.com/community/user; or the default
#            will be http://site.com/users/user.  If unspecifed and uuser
#            is a user hashref, then the best/preferred vhost will be chosen.
# returns: scalar; a URL.
# </LJFUNC>
sub journal_base
{
    my ($user, $vhost) = @_;

    if (! isu($user) && LJ::are_hooks("journal_base")) {
        my $u = LJ::load_user($user);
        $user = $u if $u;
    }

    if (isu($user)) {
        my $u = $user;

        my $hookurl = LJ::run_hook("journal_base", $u, $vhost);
        return $hookurl if $hookurl;

        $user = $u->{'user'};
        unless (defined $vhost) {
            if ($LJ::FRONTPAGE_JOURNAL eq $user) {
                $vhost = "front";
            } elsif ($u->{'journaltype'} eq "P") {
                $vhost = "";
            } elsif ($u->{'journaltype'} eq "C") {
                $vhost = "community";
            }

        }
    }

    if ($vhost eq "users") {
        my $he_user = $user;
        $he_user =~ s/_/-/g;
        return "http://$he_user.$LJ::USER_DOMAIN";
    } elsif ($vhost eq "tilde") {
        return "$LJ::SITEROOT/~$user";
    } elsif ($vhost eq "community") {
        return "$LJ::SITEROOT/community/$user";
    } elsif ($vhost eq "front") {
        return $LJ::SITEROOT;
    } elsif ($vhost =~ /^other:(.+)/) {
        return "http://$1";
    } else {
        return "$LJ::SITEROOT/users/$user";
    }
}


# loads all of the given privs for a given user into a hashref
# inside the user record ($u->{_privs}->{$priv}->{$arg} = 1)
# <LJFUNC>
# name: LJ::load_user_privs
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub load_user_privs
{
    &nodb;
    my $remote = shift;
    my @privs = @_;
    return unless $remote and @privs;

    # return if we've already loaded these privs for this user.
    @privs = grep { ! $remote->{'_privloaded'}->{$_} } @privs;
    return unless @privs;

    my $dbr = LJ::get_db_reader();
    return unless $dbr;
    foreach (@privs) { $remote->{'_privloaded'}->{$_}++; }
    @privs = map { $dbr->quote($_) } @privs;
    my $sth = $dbr->prepare("SELECT pl.privcode, pm.arg ".
                            "FROM priv_map pm, priv_list pl ".
                            "WHERE pm.prlid=pl.prlid AND ".
                            "pl.privcode IN (" . join(',',@privs) . ") ".
                            "AND pm.userid=$remote->{'userid'}");
    $sth->execute;
    while (my ($priv, $arg) = $sth->fetchrow_array) {
        unless (defined $arg) { $arg = ""; }  # NULL -> ""
        $remote->{'_priv'}->{$priv}->{$arg} = 1;
    }
}

# <LJFUNC>
# name: LJ::check_priv
# des: Check to see if a user has a certain privilege.
# info: Usually this is used to check the privs of a $remote user.
#       See [func[LJ::get_remote]].  As such, a $u argument of undef
#       is okay to pass: 0 will be returned, as an unknown user can't
#       have any rights.
# args: dbarg?, u, priv, arg?
# des-priv: Priv name to check for (see [dbtable[priv_list]])
# des-arg: Optional argument.  If defined, function only returns true
#          when $remote has a priv of type $priv also with arg $arg, not
#          just any priv of type $priv, which is the behavior without
#          an $arg. Arg can be "*", for all args.
# returns: boolean; true if user has privilege
# </LJFUNC>
sub check_priv
{
    &nodb;
    my ($u, $priv, $arg) = @_;
    return 0 unless $u;

    LJ::load_user_privs($u, $priv)
        unless $u->{'_privloaded'}->{$priv};

    # no access if they don't have the priv
    return 0 unless defined $u->{'_priv'}->{$priv};

    # at this point we know they have the priv
    return 1 unless defined $arg;

    # check if they have the right arguments
    return 1 if defined $u->{'_priv'}->{$priv}->{$arg};
    return 1 if defined $u->{'_priv'}->{$priv}->{"*"};

    # don't have the right argument
    return 0;
}

#
#
# <LJFUNC>
# name: LJ::remote_has_priv
# class:
# des: Check to see if the given remote user has a certain priviledge
# info: DEPRECATED.  should use load_user_privs + check_priv
# args:
# des-:
# returns:
# </LJFUNC>
sub remote_has_priv
{
    &nodb;
    my $remote = shift;
    my $privcode = shift;     # required.  priv code to check for.
    my $ref = shift;  # optional, arrayref or hashref to populate
    return 0 unless ($remote);

    ### authentication done.  time to authorize...

    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT pm.arg FROM priv_map pm, priv_list pl WHERE pm.prlid=pl.prlid AND pl.privcode=? AND pm.userid=?");
    $sth->execute($privcode, $remote->{'userid'});

    my $match = 0;
    if (ref $ref eq "ARRAY") { @$ref = (); }
    if (ref $ref eq "HASH") { %$ref = (); }
    while (my ($arg) = $sth->fetchrow_array) {
        $match++;
        if (ref $ref eq "ARRAY") { push @$ref, $arg; }
        if (ref $ref eq "HASH") { $ref->{$arg} = 1; }
    }
    return $match;
}

# $dom: 'L' == log, 'T' == talk, 'M' == modlog, 'S' == session,
#       'R' == memory (remembrance), 'K' == keyword id,
#       'P' == phone post, 'C' == pending comment
#       'O' == pOrtal box id, 'V' == 'vgift', 'E' == ESN subscription id
#       'Q' == Notification Inbox, 'G' == 'SMS messaGe'
#       'D' == 'moDule embed contents'
#
# FIXME: both phonepost and vgift are ljcom.  need hooks. but then also
#        need a sepate namespace.  perhaps a separate function/table?
sub alloc_user_counter
{
    my ($u, $dom, $opts) = @_;
    $opts ||= {};

    ##################################################################
    # IF YOU UPDATE THIS MAKE SURE YOU ADD INITIALIZATION CODE BELOW #
    return undef unless $dom =~ /^[LTMPSRKCOVEQGD]$/;                #
    ##################################################################

    my $dbh = LJ::get_db_writer();
    return undef unless $dbh;

    my $newmax;
    my $uid = $u->{'userid'}+0;
    return undef unless $uid;
    my $memkey = [$uid, "auc:$uid:$dom"];

    # in a master-master DB cluster we need to be careful that in
    # an automatic failover case where one cluster is slightly behind
    # that the same counter ID isn't handed out twice.  use memcache
    # as a sanity check to record/check latest number handed out.
    my $memmax = int(LJ::MemCache::get($memkey) || 0);

    my $rs = $dbh->do("UPDATE usercounter SET max=LAST_INSERT_ID(GREATEST(max,$memmax)+1) ".
                      "WHERE journalid=? AND area=?", undef, $uid, $dom);
    if ($rs > 0) {
        $newmax = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");

        # if we've got a supplied callback, lets check the counter
        # number for consistency.  If it fails our test, wipe
        # the counter row and start over, initializing a new one.
        # callbacks should return true to signal 'all is well.'
        if ($opts->{callback} && ref $opts->{callback} eq 'CODE') {
            my $rv = 0;
            eval { $rv = $opts->{callback}->($u, $newmax) };
            if ($@ or ! $rv) {
                $dbh->do("DELETE FROM usercounter WHERE " .
                         "journalid=? AND area=?", undef, $uid, $dom);
                return LJ::alloc_user_counter($u, $dom);
            }
        }

        LJ::MemCache::set($memkey, $newmax);
        return $newmax;
    }

    if ($opts->{recurse}) {
        # We shouldn't ever get here if all is right with the world.
        return undef;
    }

    my $qry_map = {
        # for entries:
        'log'         => "SELECT MAX(jitemid) FROM log2     WHERE journalid=?",
        'logtext'     => "SELECT MAX(jitemid) FROM logtext2 WHERE journalid=?",
        'talk_nodeid' => "SELECT MAX(nodeid)  FROM talk2    WHERE nodetype='L' AND journalid=?",
        # for comments:
        'talk'     => "SELECT MAX(jtalkid) FROM talk2     WHERE journalid=?",
        'talktext' => "SELECT MAX(jtalkid) FROM talktext2 WHERE journalid=?",
    };

    my $consider = sub {
        my @tables = @_;
        foreach my $t (@tables) {
            my $res = $u->selectrow_array($qry_map->{$t}, undef, $uid);
            $newmax = $res if $res > $newmax;
        }
    };

    # Make sure the counter table is populated for this uid/dom.
    if ($dom eq "L") {
        # back in the ol' days IDs were reused (because of MyISAM)
        # so now we're extra careful not to reuse a number that has
        # foreign junk "attached".  turns out people like to delete
        # each entry by hand, but we do lazy deletes that are often
        # too lazy and a user can see old stuff come back alive
        $consider->("log", "logtext", "talk_nodeid");
    } elsif ($dom eq "T") {
        # just paranoia, not as bad as above.  don't think we've ever
        # run into cases of talktext without a talk, but who knows.
        # can't hurt.
        $consider->("talk", "talktext");
    } elsif ($dom eq "M") {
        $newmax = $u->selectrow_array("SELECT MAX(modid) FROM modlog WHERE journalid=?",
                                      undef, $uid);
    } elsif ($dom eq "S") {
        $newmax = $u->selectrow_array("SELECT MAX(sessid) FROM sessions WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "R") {
        $newmax = $u->selectrow_array("SELECT MAX(memid) FROM memorable2 WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "K") {
        $newmax = $u->selectrow_array("SELECT MAX(kwid) FROM userkeywords WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "P") {
        my $userblobmax = $u->selectrow_array("SELECT MAX(blobid) FROM userblob WHERE journalid=? AND domain=?",
                                              undef, $uid, LJ::get_blob_domainid("phonepost"));
        my $ppemax = $u->selectrow_array("SELECT MAX(blobid) FROM phonepostentry WHERE userid=?",
                                         undef, $uid);
        $newmax = ($ppemax > $userblobmax) ? $ppemax : $userblobmax;
    } elsif ($dom eq "C") {
        $newmax = $u->selectrow_array("SELECT MAX(pendid) FROM pendcomments WHERE jid=?",
                                      undef, $uid);
    } elsif ($dom eq "O") {
        $newmax = $u->selectrow_array("SELECT MAX(pboxid) FROM portal_config WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "V") {
        $newmax = $u->selectrow_array("SELECT MAX(giftid) FROM vgifts WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "E") {
        $newmax = $u->selectrow_array("SELECT MAX(subid) FROM subs WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "Q") {
        $newmax = $u->selectrow_array("SELECT MAX(qid) FROM notifyqueue WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "G") {
        $newmax = $u->selectrow_array("SELECT MAX(msgid) FROM sms_msg WHERE userid=?",
                                      undef, $uid);
    } elsif ($dom eq "D") {
        $newmax = $u->selectrow_array("SELECT MAX(moduleid) FROM embedcontent WHERE userid=?",
                                      undef, $uid);
    } else {
        die "No user counter initializer defined for area '$dom'.\n";
    }
    $newmax += 0;
    $dbh->do("INSERT IGNORE INTO usercounter (journalid, area, max) VALUES (?,?,?)",
             undef, $uid, $dom, $newmax) or return undef;

    # The 2nd invocation of the alloc_user_counter sub should do the
    # intended incrementing.
    return LJ::alloc_user_counter($u, $dom, { recurse => 1 });
}

# <LJFUNC>
# name: LJ::make_user_active
# des:  Record user activity per cluster to
#       make per-activity cluster stats easier.
# args: userobj, type
# arg-userid: source userobj ref
# arg-type: currently unused
# </LJFUNC>
sub mark_user_active {
    my ($u, $type) = @_;  # not currently using type
    return 0 unless $u;   # do not auto-vivify $u
    my $uid = $u->{userid};
    return 0 unless $uid && $u->{clusterid};

    # Update the clustertrack table, but not if we've done it for this
    # user in the last hour.  if no memcache servers are configured
    # we don't do the optimization and just always log the activity info
    if (@LJ::MEMCACHE_SERVERS == 0 ||
        LJ::MemCache::add("rate:tracked:$uid", 1, 3600)) {

        return 0 unless $u->writer;
        $u->do("REPLACE INTO clustertrack2 SET ".
               "userid=?, timeactive=?, clusterid=?", undef,
               $uid, time(), $u->{clusterid}) or return 0;
    }
    return 1;
}

# <LJFUNC>
# name: LJ::infohistory_add
# des: Add a line of text to the infohistory table for an account.
# args: uuid, what, value, other?
# des-uuid: User id or user object to insert infohistory for.
# des-what: What type of history being inserted (15 chars max).
# des-value: Value for the item (255 chars max).
# des-other: Extra information (30 chars max).
# returns: 1 on success, 0 on error.
# </LJFUNC>
sub infohistory_add {
    my ($uuid, $what, $value, $other) = @_;
    $uuid = LJ::want_userid($uuid);
    return unless $uuid && $what && $value;

    # get writer and insert
    my $dbh = LJ::get_db_writer();
    my $gmt_now = LJ::mysql_time(time(), 1);
    $dbh->do("INSERT INTO infohistory (userid, what, timechange, oldvalue, other) VALUES (?, ?, ?, ?, ?)",
             undef, $uuid, $what, $gmt_now, $value, $other);
    return $dbh->err ? 0 : 1;
}

# <LJFUNC>
# name: LJ::set_userprop
# des: Sets/deletes a userprop by name for a user.
# info: This adds or deletes from the
#       [dbtable[userprop]]/[dbtable[userproplite]] tables.  One
#       crappy thing about this interface is that it doesn't allow
#       a batch of userprops to be updated at once, which is the
#       common thing to do.
# args: dbarg?, uuserid, propname, value, memonly?
# des-uuserid: The userid of the user or a user hashref.
# des-propname: The name of the property.  Or a hashref of propname keys and corresponding values.
# des-value: The value to set to the property.  If undefined or the
#            empty string, then property is deleted.
# des-memonly: if true, only writes to memcache, and not to database.
# </LJFUNC>
sub set_userprop
{
    &nodb;
    my ($u, $propname, $value, $memonly) = @_;
    $u = ref $u ? $u : LJ::load_userid($u);
    my $userid = $u->{'userid'}+0;

    my $hash = ref $propname eq "HASH" ? $propname : { $propname => $value };

    my %action;  # $table -> {"replace"|"delete"} -> [ "($userid, $propid, $qvalue)" | propid ]
    my %multihomed;  # { $propid => $value }

    foreach $propname (keys %$hash) {
        LJ::run_hook("setprop", prop => $propname,
                     u => $u, value => $value);

        my $p = LJ::get_prop("user", $propname) or
            die "Invalid userprop $propname passed to LJ::set_userprop.";
        if ($p->{multihomed}) {
            # collect into array for later handling
            $multihomed{$p->{id}} = $hash->{$propname};
            next;
        }
        my $table = $p->{'indexed'} ? "userprop" : "userproplite";
        if ($p->{datatype} eq 'blobchar') {
            $table = 'userpropblob';
        }
        elsif ($p->{'cldversion'} && $u->{'dversion'} >= $p->{'cldversion'}) {
            $table = "userproplite2";
        }
        unless ($memonly) {
            my $db = $action{$table}->{'db'} ||= (
                $table !~ m{userprop(lite2|blob)}
                    ? LJ::get_db_writer()
                    : $u->writer );
            return 0 unless $db;
        }
        $value = $hash->{$propname};
        if (defined $value && $value) {
            push @{$action{$table}->{"replace"}}, [ $p->{'id'}, $value ];
        } else {
            push @{$action{$table}->{"delete"}}, $p->{'id'};
        }
    }

    my $expire = time() + 3600*24;
    foreach my $table (keys %action) {
        my $db = $action{$table}->{'db'};
        if (my $list = $action{$table}->{"replace"}) {
            if ($db) {
                my $vals = join(',', map { "($userid,$_->[0]," . $db->quote($_->[1]) . ")" } @$list);
                $db->do("REPLACE INTO $table (userid, upropid, value) VALUES $vals");
            }
            LJ::MemCache::set([$userid,"uprop:$userid:$_->[0]"], $_->[1], $expire) foreach (@$list);
        }
        if (my $list = $action{$table}->{"delete"}) {
            if ($db) {
                my $in = join(',', @$list);
                $db->do("DELETE FROM $table WHERE userid=$userid AND upropid IN ($in)");
            }
            LJ::MemCache::set([$userid,"uprop:$userid:$_"], "", $expire) foreach (@$list);
        }
    }

    # if we had any multihomed props, set them here
    if (%multihomed) {
        my $dbh = LJ::get_db_writer();
        return 0 unless $dbh && $u->writer;
        while (my ($propid, $pvalue) = each %multihomed) {
            if (defined $pvalue && $pvalue) {
                # replace data into master
                $dbh->do("REPLACE INTO userprop VALUES (?, ?, ?)",
                         undef, $userid, $propid, $pvalue);
            } else {
                # delete data from master, but keep in cluster
                $dbh->do("DELETE FROM userprop WHERE userid = ? AND upropid = ?",
                         undef, $userid, $propid);
            }

            # fail out?
            return 0 if $dbh->err;

            # put data in cluster
            $pvalue ||= '';
            $u->do("REPLACE INTO userproplite2 VALUES (?, ?, ?)",
                   undef, $userid, $propid, $pvalue);
            return 0 if $u->err;

            # set memcache
            LJ::MemCache::set([$userid,"uprop:$userid:$propid"], $pvalue, $expire);
        }
    }

    return 1;
}

# <LJFUNC>
# name: LJ::get_shared_journals
# des: Gets an array of shared journals a user has access to.
# returns: An array of shared journals.
# args: u
# </LJFUNC>
sub get_shared_journals
{
    my $u = shift;
    my $ids = LJ::load_rel_target($u, 'A') || [];

    # have to get usernames;
    my %users;
    LJ::load_userids_multiple([ map { $_, \$users{$_} } @$ids ], [$u]);
    return sort map { $_->{'user'} } values %users;
}

# <LJFUNC>
# class: component
# name: LJ::ljuser
# des: Make link to userinfo/journal of user.
# info: Returns the HTML for a userinfo/journal link pair for a given user
#       name, just like LJUSER does in BML.  This is for files like cleanhtml.pl
#       and ljpoll.pl which need this functionality too, but they aren't run as BML.
# args: user, opts?
# des-user: Username to link to, or user hashref.
# des-opts: Optional hashref to control output.  Key 'full' when true causes
#           a link to the mode=full userinfo.   Key 'type' when 'C' makes
#           a community link, when 'Y' makes a syndicated account link,
#           when 'N' makes a news account link, otherwise makes a user account
#           link. If user parameter is a hashref, its 'journaltype' overrides
#           this 'type'.  Key 'del', when true, makes a tag for a deleted user.
#           If user parameter is a hashref, its 'statusvis' overrides 'del'.
#           Key 'no_follow', when true, disables traversal of renamed users.
# returns: HTML with a little head image & bold text link.
# </LJFUNC>
sub ljuser
{
    my $user = shift;
    my $opts = shift;

    my $andfull = $opts->{'full'} ? "?mode=full" : "";
    my $img = $opts->{'imgroot'} || $LJ::IMGPREFIX;
    my $profile_url = $opts->{'profile_url'} || '';
    my $journal_url = $opts->{'journal_url'} || '';
    my $profile;

    my $make_tag = sub {
        my ($fil, $url, $x, $y) = @_;
        $y ||= $x;  # make square if only one dimension given
        my $strike = $opts->{'del'} ? ' text-decoration: line-through;' : '';

        # Backwards check, because we want it to default to on
        my $bold = (exists $opts->{'bold'} and $opts->{'bold'} == 0) ? 0 : 1;
        my $ljusername = $bold ? "<b>$user</b>" : "$user";

        my $link_color = "";
        # Make sure it's really a color
        if ($opts->{'link_color'} && $opts->{'link_color'} =~ /^#([a-fA-F0-9]{3}|[a-fA-F0-9]{6})$/) {
            $link_color = " style='color: " . $opts->{'link_color'} . ";'";
        }

        $profile = $profile_url ne '' ? $profile_url : $profile . $andfull;
        $url = $journal_url ne '' ? $journal_url : $url;

        return "<span class='ljuser' lj:user='$user' style='white-space: nowrap;$strike'><a href='$profile'><img src='$img/$fil' alt='[info]' width='$x' height='$y' style='vertical-align: bottom; border: 0;' /></a><a href='$url'$link_color>$ljusername</a></span>";
    };

    my $u = isu($user) ? $user : LJ::load_user($user);

    # Traverse the renames to the final journal
    if ($u) {
        my $hops = 0;
        while ($u->{'journaltype'} eq 'R'
               and ! $opts->{'no_follow'} && $hops++ < 5) {
            my $rt = $u->prop("renamedto");
            last unless length $rt;
            $u = LJ::load_user($rt);
        }
    }

    # if invalid user, link to dummy userinfo page
    if (! $u) {
        $user = LJ::canonical_username($user);
        $profile = "$LJ::SITEROOT/userinfo.bml?user=$user";
        return $make_tag->('userinfo.gif', "$LJ::SITEROOT/userinfo.bml?user=$user", 17);
    }

    $profile = $u->profile_url;

    my $type = $u->{'journaltype'};

    # Mark accounts as deleted that aren't visible, memorial, or locked
    $opts->{'del'} = 1 unless $u->is_visible || $u->is_memorial || $u->is_locked;
    $user = $u->{'user'};

    my $url = $u->journal_base . "/";

    if (my ($icon, $size) = LJ::run_hook("head_icon", $u)) {
        return $make_tag->($icon, $url, $size || 16) if $icon;
    }

    if ($type eq 'C') {
        return $make_tag->('community.gif', $url, 16);
    } elsif ($type eq 'Y') {
        return $make_tag->('syndicated.gif', $url, 16);
    } elsif ($type eq 'N') {
        return $make_tag->('newsinfo.gif', $url, 16);
    } elsif ($type eq 'I') {
        return $u->ljuser_display($opts);
    } else {
        return $make_tag->('userinfo.gif', $url, 17);
    }
}

sub set_email {
    my ($userid, $email) = @_;

    my $dbh = LJ::get_db_writer();
    if ($LJ::DEBUG{'write_emails_to_user_table'}) {
        $dbh->do("UPDATE user SET email=? WHERE userid=?", undef,
                 $email, $userid);
    }
    $dbh->do("REPLACE INTO email (userid, email) VALUES (?, ?)",
             undef, $userid, $email);

    # update caches
    LJ::memcache_kill($userid, "userid");
    LJ::MemCache::delete([$userid, "email:$userid"]);
    my $cache = $LJ::REQ_CACHE_USER_ID{$userid} or return;
    $cache->{'_email'} = $email;
}

sub set_password {
    my ($userid, $password) = @_;

    my $dbh = LJ::get_db_writer();
    if ($LJ::DEBUG{'write_passwords_to_user_table'}) {
        $dbh->do("UPDATE user SET password=? WHERE userid=?", undef,
                 $password, $userid);
    }
    $dbh->do("REPLACE INTO password (userid, password) VALUES (?, ?)",
             undef, $userid, $password);

    # update caches
    LJ::memcache_kill($userid, "userid");
    LJ::MemCache::delete([$userid, "pw:$userid"]);
    my $cache = $LJ::REQ_CACHE_USER_ID{$userid} or return;
    $cache->{'_password'} = $password;
}

sub update_user
{
    my ($arg, $ref) = @_;
    my @uid;

    if (ref $arg eq "ARRAY") {
        @uid = @$arg;
    } else {
        @uid = want_userid($arg);
    }
    @uid = grep { $_ } map { $_ + 0 } @uid;
    return 0 unless @uid;

    my @sets;
    my @bindparams;
    my $used_raw = 0;
    while (my ($k, $v) = each %$ref) {
        if ($k eq "raw") {
            $used_raw = 1;
            push @sets, $v;
        } elsif ($k eq 'email') {
            set_email($_, $v) foreach @uid;
        } elsif ($k eq 'password') {
            set_password($_, $v) foreach @uid;
        } else {
            push @sets, "$k=?";
            push @bindparams, $v;
        }
    }
    return 1 unless @sets;
    my $dbh = LJ::get_db_writer();
    return 0 unless $dbh;
    {
        local $" = ",";
        my $where = @uid == 1 ? "userid=$uid[0]" : "userid IN (@uid)";
        $dbh->do("UPDATE user SET @sets WHERE $where", undef,
                 @bindparams);
        return 0 if $dbh->err;
    }
    if (@LJ::MEMCACHE_SERVERS) {
        LJ::memcache_kill($_, "userid") foreach @uid;
    }

    if ($used_raw) {
        # for a load of userids from the master after update
        # so we pick up the values set via the 'raw' option
        require_master(sub { LJ::load_userids(@uid) });
    } else {
        foreach my $uid (@uid) {
            while (my ($k, $v) = each %$ref) {
                my $cache = $LJ::REQ_CACHE_USER_ID{$uid} or next;
                $cache->{$k} = $v;
            }
        }
    }

    return 1;
}

# <LJFUNC>
# name: LJ::get_timezone
# des: Gets the timezone offset for the user.
# args: u, offsetref, fakedref
# des-u: user object.
# des-offsetref: reference to scalar to hold timezone offset;
# des-fakedref: reference to scalar to hold whether this timezone was
#               faked.  0 if it is the timezone specified by the user.
# returns: nonzero if successful.
# </LJFUNC>
sub get_timezone {
    my ($u, $offsetref, $fakedref) = @_;

    # See if the user specified their timezone
    if (my $tz = $u->prop('timezone')) {
        # If we eval fails, we'll fall through to guessing instead
        my $dt = eval {
            DateTime->from_epoch(
                                 epoch => time(),
                                 time_zone => $tz,
                                 );
        };

        if ($dt) {
            $$offsetref = $dt->offset() / (60 * 60); # Convert from seconds to hours
            $$fakedref  = 0 if $fakedref;

            return 1;
        }
    }

    # Either the user hasn't set a timezone or we failed at
    # loading it.  We guess their current timezone's offset
    # by comparing the gmtime of their last post with the time
    # they specified on that post.

    my $dbcr = LJ::get_cluster_def_reader($u);
    return 0 unless $dbcr;

    $$fakedref = 1 if $fakedref;

    # grab the times on the last post that wasn't backdated.
    # (backdated is rlogtime == $LJ::EndOfTime)
    if (my $last_row = $dbcr->selectrow_hashref(
        qq{
            SELECT rlogtime, eventtime
            FROM log2
            WHERE journalid = ? AND rlogtime <> ?
            ORDER BY rlogtime LIMIT 1
        }, undef, $u->{userid}, $LJ::EndOfTime)) {
        my $logtime = $LJ::EndOfTime - $last_row->{'rlogtime'};
        my $eventtime = LJ::mysqldate_to_time($last_row->{'eventtime'}, 1);
        my $hourdiff = ($eventtime - $logtime) / 3600;

        # if they're up to a quarter hour behind, round up.
        $hourdiff = $hourdiff > 0 ? int($hourdiff + 0.25) : int($hourdiff - 0.25);

        # if the offset is more than 24h in either direction, then the last
        # entry is probably unreliable. don't use any offset at all.
        $$offsetref = (-24 < $hourdiff && $hourdiff < 24) ? $hourdiff : 0;
    }

    return 1;
}

# returns undef on error, or otherwise arrayref of arrayrefs,
# each of format [ year, month, day, count ] for all days with
# non-zero count.  examples:
#  [ [ 2003, 6, 5, 3 ], [ 2003, 6, 8, 4 ], ... ]
#
sub get_daycounts
{
    my ($u, $remote, $not_memcache) = @_;
    # NOTE: $remote not yet used.  one of the oldest LJ shortcomings is that
    # it's public how many entries users have per-day, even if the entries
    # are protected.  we'll be fixing that with a new table, but first
    # we're moving everything to this API.

    my $uid = LJ::want_userid($u) or return undef;

    my @days;
    my $memkey = [$uid,"dayct:$uid"];
    unless ($not_memcache) {
        my $list = LJ::MemCache::get($memkey);
        return $list if $list;
    }

    my $dbcr = LJ::get_cluster_def_reader($u) or return undef;
    my $sth = $dbcr->prepare("SELECT year, month, day, COUNT(*) ".
                             "FROM log2 WHERE journalid=? GROUP BY 1, 2, 3");
    $sth->execute($uid);
    while (my ($y, $m, $d, $c) = $sth->fetchrow_array) {
        # we force each number from string scalars (from DBI) to int scalars,
        # so they store smaller in memcache
        push @days, [ int($y), int($m), int($d), int($c) ];
    }
    LJ::MemCache::add($memkey, \@days);
    return \@days;
}

# <LJFUNC>
# name: LJ::set_interests
# des: Change a user's interests
# args: dbarg?, u, old, new
# arg-old: hashref of old interests (hashing being interest => intid)
# arg-new: listref of new interests
# returns: 1 on success, undef on failure
# </LJFUNC>
sub set_interests
{
    my ($u, $old, $new) = @_;

    $u = LJ::want_user($u);
    my $userid = $u->{'userid'};
    return undef unless $userid;

    return undef unless ref $old eq 'HASH';
    return undef unless ref $new eq 'ARRAY';

    my $dbh = LJ::get_db_writer();
    my %int_new = ();
    my %int_del = %$old;  # assume deleting everything, unless in @$new

    # user interests go in a different table than user interests,
    # though the schemas are the same so we can run the same queries on them
    my $uitable = $u->{'journaltype'} eq 'C' ? 'comminterests' : 'userinterests';

    # track if we made changes to refresh memcache later.
    my $did_mod = 0;

    my @valid_ints = LJ::validate_interest_list(@$new);
    foreach my $int (@valid_ints)
    {
        $int_new{$int} = 1 unless $old->{$int};
        delete $int_del{$int};
    }

    ### were interests removed?
    if (%int_del)
    {
        ## easy, we know their IDs, so delete them en masse
        my $intid_in = join(", ", values %int_del);
        $dbh->do("DELETE FROM $uitable WHERE userid=$userid AND intid IN ($intid_in)");
        $dbh->do("UPDATE interests SET intcount=intcount-1 WHERE intid IN ($intid_in)");
        $did_mod = 1;
    }

    ### do we have new interests to add?
    if (%int_new)
    {
        $did_mod = 1;

        ## difficult, have to find intids of interests, and create new ints for interests
        ## that nobody has ever entered before
        my $int_in = join(", ", map { $dbh->quote($_); } keys %int_new);
        my %int_exist;
        my @new_intids = ();  ## existing IDs we'll add for this user

        ## find existing IDs
        my $sth = $dbh->prepare("SELECT interest, intid FROM interests WHERE interest IN ($int_in)");
        $sth->execute;
        while (my ($intr, $intid) = $sth->fetchrow_array) {
            push @new_intids, $intid;       # - we'll add this later.
            delete $int_new{$intr};         # - so we don't have to make a new intid for
                                            #   this next pass.
        }

        if (@new_intids) {
            my $sql = "";
            foreach my $newid (@new_intids) {
                if ($sql) { $sql .= ", "; }
                else { $sql = "REPLACE INTO $uitable (userid, intid) VALUES "; }
                $sql .= "($userid, $newid)";
            }
            $dbh->do($sql);

            my $intid_in = join(", ", @new_intids);
            $dbh->do("UPDATE interests SET intcount=intcount+1 WHERE intid IN ($intid_in)");
        }
    }

    ### do we STILL have interests to add?  (must make new intids)
    if (%int_new)
    {
        foreach my $int (keys %int_new)
        {
            my $intid;
            my $qint = $dbh->quote($int);

            $dbh->do("INSERT INTO interests (intid, intcount, interest) ".
                     "VALUES (NULL, 1, $qint)");
            if ($dbh->err) {
                # somebody beat us to creating it.  find its id.
                $intid = $dbh->selectrow_array("SELECT intid FROM interests WHERE interest=$qint");
                $dbh->do("UPDATE interests SET intcount=intcount+1 WHERE intid=$intid");
            } else {
                # newly created
                $intid = $dbh->{'mysql_insertid'};
            }
            if ($intid) {
                ## now we can actually insert it into the userinterests table:
                $dbh->do("INSERT INTO $uitable (userid, intid) ".
                         "VALUES ($userid, $intid)");
            }
        }
    }

    ### if journaltype is community, clean their old userinterests from 'userinterests'
    if ($u->{'journaltype'} eq 'C') {
        $dbh->do("DELETE FROM userinterests WHERE userid=?", undef, $u->{'userid'});
    }

    LJ::memcache_kill($u, "intids") if $did_mod;
    return 1;
}

sub validate_interest_list {
    my $interrors = ref $_[0] eq "ARRAY" ? shift : [];
    my @ints = @_;

    my @valid_ints = ();
    foreach my $int (@ints) {
        $int = lc($int);       # FIXME: use utf8?
        $int =~ s/^i like //;  # *sigh*
        next unless $int;

        # Specific interest failures
        my ($bytes,$chars) = LJ::text_length($int);
        my @words = split(/\s+/, $int);
        my $word_ct = scalar @words;

        my $error_string = '';
        if ($int =~ /[\<\>]/) {
            $int = LJ::ehtml($int);
            $error_string .= '.invalid';
        } else {
            $error_string .= '.bytes' if $bytes > LJ::BMAX_INTEREST;
            $error_string .= '.chars' if $chars > LJ::CMAX_INTEREST;
            $error_string .= '.words' if $word_ct > 4;
        }

        if ($error_string) {
            $error_string = "error.interest$error_string";
            push @$interrors, [ $error_string,
                                { int => $int,
                                  bytes => $bytes,
                                  bytes_max => LJ::BMAX_INTEREST,
                                  chars => $chars,
                                  chars_max => LJ::CMAX_INTEREST,
                                  words => $word_ct,
                                  words_max => 4
                                }
                              ];
            next;
        }
        push @valid_ints, $int;
    }
    return @valid_ints;
}
sub interest_string_to_list {
    my $intstr = shift;

    $intstr =~ s/^\s+//;  # strip leading space
    $intstr =~ s/\s+$//;  # strip trailing space
    $intstr =~ s/\n/,/g;  # newlines become commas
    $intstr =~ s/\s+/ /g; # strip duplicate spaces from the interest

    # final list is ,-sep
    return grep { length } split (/\s*,\s*/, $intstr);
}

# $opts is optional, with keys:
#    forceids => 1   : don't use memcache for loading the intids
#    forceints => 1   : don't use memcache for loading the interest rows
#    justids => 1 : return arrayref of intids only, not names/counts
# returns otherwise an arrayref of interest rows, sorted by interest name
sub get_interests
{
    my ($u, $opts) = @_;
    $opts ||= {};
    return undef unless $u;
    my $uid = $u->{userid};
    my $uitable = $u->{'journaltype'} eq 'C' ? 'comminterests' : 'userinterests';

    # FIXME: should do caching on $u

    # load the ids
    my $ids;
    my $mk_ids = [$uid, "intids:$uid"];
    $ids = LJ::MemCache::get($mk_ids) unless $opts->{'forceids'};
    unless ($ids && ref $ids eq "ARRAY") {
        $ids = [];
        my $dbh = LJ::get_db_writer();
        my $sth = $dbh->prepare("SELECT intid FROM $uitable WHERE userid=?");
        $sth->execute($uid);
        push @$ids, $_ while ($_) = $sth->fetchrow_array;
        LJ::MemCache::add($mk_ids, $ids, 3600*12);
    }
    return $ids if $opts->{'justids'};

    # load interest rows
    my %need;
    $need{$_} = 1 foreach @$ids;
    my @ret;

    unless ($opts->{'forceints'}) {
        if (my $mc = LJ::MemCache::get_multi(map { [$_, "introw:$_"] } @$ids)) {
            while (my ($k, $v) = each %$mc) {
                next unless $k =~ /^introw:(\d+)/;
                delete $need{$1};
                push @ret, $v;
            }
        }
    }

    if (%need) {
        my $ids = join(",", map { $_+0 } keys %need);
        my $dbr = LJ::get_db_reader();
        my $sth = $dbr->prepare("SELECT intid, interest, intcount FROM interests ".
                                "WHERE intid IN ($ids)");
        $sth->execute;
        my $memc_store = 0;
        while (my ($intid, $int, $count) = $sth->fetchrow_array) {
            # minimize latency... only store 25 into memcache at a time
            # (too bad we don't have set_multi.... hmmmm)
            my $aref = [$intid, $int, $count];
            if ($memc_store++ < 25) {
                # if the count is fairly high, keep item in memcache longer,
                # since count's not so important.
                my $expire = $count < 10 ? 3600*12 : 3600*48;
                LJ::MemCache::add([$intid, "introw:$intid"], $aref, $expire);
            }
            push @ret, $aref;
        }
    }

    @ret = sort { $a->[1] cmp $b->[1] } @ret;
    return \@ret;
}

# <LJFUNC>
# name: LJ::modify_caps
# des: Given a list of caps to add and caps to remove, updates a user's caps
# args: uuid, cap_add, cap_del, res
# arg-cap_add: arrayref of bit numbers to turn on
# arg-cap_del: arrayref of bit numbers to turn off
# arg-res: hashref returned from 'modify_caps' hook
# returns: updated u object, retrieved from $dbh, then 'caps' key modified
#          otherwise, returns 0 unless all  hooks run properly
# </LJFUNC>
sub modify_caps {
    my ($argu, $cap_add, $cap_del, $res) = @_;
    my $userid = LJ::want_userid($argu);
    return undef unless $userid;

    $cap_add ||= [];
    $cap_del ||= [];
    my %cap_add_mod = ();
    my %cap_del_mod = ();

    # convert capnames to bit numbers
    if (LJ::are_hooks("get_cap_bit")) {
        foreach my $bit (@$cap_add, @$cap_del) {
            next if $bit =~ /^\d+$/;

            # bit is a magical reference into the array
            $bit = LJ::run_hook("get_cap_bit", $bit);
        }
    }

    # get a u object directly from the db
    my $u = LJ::load_userid($userid, "force");

    # add new caps
    my $newcaps = int($u->{'caps'});
    foreach (@$cap_add) {
        my $cap = 1 << $_;

        # about to turn bit on, is currently off?
        $cap_add_mod{$_} = 1 unless $newcaps & $cap;
        $newcaps |= $cap;
    }

    # remove deleted caps
    foreach (@$cap_del) {
        my $cap = 1 << $_;

        # about to turn bit off, is it currently on?
        $cap_del_mod{$_} = 1 if $newcaps & $cap;
        $newcaps &= ~$cap;
    }

    # run hooks for modified bits
    if (LJ::are_hooks("modify_caps")) {
        $res = LJ::run_hook("modify_caps",
                            { 'u' => $u,
                              'newcaps' => $newcaps,
                              'oldcaps' => $u->{'caps'},
                              'cap_on_req'  => { map { $_ => 1 } @$cap_add },
                              'cap_off_req' => { map { $_ => 1 } @$cap_del },
                              'cap_on_mod'  => \%cap_add_mod,
                              'cap_off_mod' => \%cap_del_mod,
                          });

        # hook should return a status code
        return undef unless defined $res;
    }

    # update user row
    return 0 unless LJ::update_user($u, { 'caps' => $newcaps });

    $u->{caps} = $newcaps;
    $argu->{caps} = $newcaps if ref $argu; # temp hack
    return $u;
}

# returns 1 if action is permitted.  0 if above rate or fail.
# action isn't logged on fail.
#
# opts keys:
#   -- "limit_by_ip" => "1.2.3.4"  (when used for checking rate)
#   --
sub rate_log
{
    my ($u, $ratename, $count, $opts) = @_;
    my $rateperiod = LJ::get_cap($u, "rateperiod-$ratename");
    return 1 unless $rateperiod;

    return 0 unless $u->writer;

    my $rp = LJ::get_prop("rate", $ratename);
    return 0 unless $rp;

    my $now = time();
    my $beforeperiod = $now - $rateperiod;

    # delete inapplicable stuff (or some of it)
    $u->do("DELETE FROM ratelog WHERE userid=$u->{'userid'} AND rlid=$rp->{'id'} ".
           "AND evttime < $beforeperiod LIMIT 1000");

    # check rate.  (okay per period)
    my $opp = LJ::get_cap($u, "rateallowed-$ratename");
    return 1 unless $opp;

    my $udbr = LJ::get_cluster_reader($u);
    my $ip = $udbr->quote($opts->{'limit_by_ip'} || "0.0.0.0");
    my $sum = $udbr->selectrow_array("SELECT COUNT(quantity) FROM ratelog WHERE ".
                                     "userid=$u->{'userid'} AND rlid=$rp->{'id'} ".
                                     "AND ip=INET_ATON($ip) ".
                                     "AND evttime > $beforeperiod");

    # would this transaction go over the limit?
    if ($sum + $count > $opp) {
        # TODO: optionally log to rateabuse, unless caller is doing it themselves
        # somehow, like with the "loginstall" table.
        return 0;
    }

    # log current
    $count = $count + 0;
    $u->do("INSERT INTO ratelog (userid, rlid, evttime, ip, quantity) VALUES ".
           "($u->{'userid'}, $rp->{'id'}, $now, INET_ATON($ip), $count)");
    return 1;
}

sub login_ip_banned
{
    my $u = shift;
    return 0 unless $u;

    my $ip;
    return 0 unless ($ip = LJ::get_remote_ip());

    my $udbr;
    my $rateperiod = LJ::get_cap($u, "rateperiod-failed_login");
    if ($rateperiod && ($udbr = LJ::get_cluster_reader($u))) {
        my $bantime = $udbr->selectrow_array("SELECT time FROM loginstall WHERE ".
                                             "userid=$u->{'userid'} AND ip=INET_ATON(?)",
                                             undef, $ip);
        if ($bantime && $bantime > time() - $rateperiod) {
            return 1;
        }
    }
    return 0;
}

sub handle_bad_login
{
    my $u = shift;
    return 1 unless $u;

    my $ip;
    return 1 unless ($ip = LJ::get_remote_ip());
    # an IP address is permitted such a rate of failures
    # until it's banned for a period of time.
    my $udbh;
    if (! LJ::rate_log($u, "failed_login", 1, { 'limit_by_ip' => $ip }) &&
        ($udbh = LJ::get_cluster_master($u)))
    {
        $udbh->do("REPLACE INTO loginstall (userid, ip, time) VALUES ".
                  "(?,INET_ATON(?),UNIX_TIMESTAMP())", undef, $u->{'userid'}, $ip);
    }
    return 1;
}

# <LJFUNC>
# name: LJ::userpic_count
# des: Gets a count of userpics for a given user
# args: dbarg?, upics, idlist
# des-upics: hashref to load pictures into, keys being the picids
# des-idlist: [$u, $picid] or [[$u, $picid], [$u, $picid], +] objects
# also supports depreciated old method of an array ref of picids
# </LJFUNC>
sub userpic_count {
    my $u = shift or return undef;

    if ($u->{'dversion'} > 6) {
        my $dbcr = LJ::get_cluster_def_reader($u) or return undef;
        return $dbcr->selectrow_array("SELECT COUNT(*) FROM userpic2 " .
                                      "WHERE userid=? AND state <> 'X'", undef, $u->{'userid'});
    }

    my $dbh = LJ::get_db_writer() or return undef;
    return $dbh->selectrow_array("SELECT COUNT(*) FROM userpic " .
                                 "WHERE userid=? AND state <> 'X'", undef, $u->{'userid'});
}

# <LJFUNC>
# name: LJ::_friends_do
# des: Runs given sql, then deletes the given userid's friends from memcache
# args: uuserid, sql, args
# des-uuserid: a userid or u object
# des-sql: sql to run via $dbh->do()
# des-args: a list of arguments to pass use via: $dbh->do($sql, undef, @args)
# returns: return false on error
# </LJFUNC>
sub _friends_do {
    my ($uuid, $sql, @args) = @_;
    my $uid = want_userid($uuid);
    return undef unless $uid && $sql;

    my $dbh = LJ::get_db_writer() or return 0;

    my $ret = $dbh->do($sql, undef, @args);
    return 0 if $dbh->err;

    LJ::memcache_kill($uid, "friends");

    # pass $uuid in case it's a $u object which mark_dirty wants
    LJ::mark_dirty($uuid, "friends");

    return 1;
}

# <LJFUNC>
# name: LJ::add_friend
# des: Simple interface to add a friend edge.
# args: uuid, to_add, opts?
# des-to_add: a single uuid or an arrayref of uuids to add (befriendees)
# des-opts: hashref; 'defaultview' key means add target uuids to $uuid's Default View friends group,
#                    'groupmask' key means use this group mask
# returns: boolean; 1 on success (or already friend), 0 on failure (bogus args)
# </LJFUNC>
sub add_friend
{
    &nodb;
    my ($userid, $to_add, $opts) = @_;

    $userid = LJ::want_userid($userid);
    return 0 unless $userid;

    my @add_ids = ref $to_add eq 'ARRAY' ? map { LJ::want_userid($_) } @$to_add : ( LJ::want_userid($to_add) );
    return 0 unless @add_ids;

    my $dbh = LJ::get_db_writer();

    my $fgcol = LJ::color_todb($opts->{'fgcolor'}) || LJ::color_todb("#000000");
    my $bgcol = LJ::color_todb($opts->{'bgcolor'});
    # in case the background color is #000000, in which case the || falls through
    # so only overwrite what we got if what we got was undef (invalid input)
    $bgcol = LJ::color_todb("#ffffff") unless defined $bgcol;

    $opts ||= {};

    my $groupmask = 1;
    if (defined $opts->{groupmask}) {
        $groupmask = $opts->{groupmask};
    } elsif ($opts->{'defaultview'}) {
        # TAG:FR:ljlib:add_friend_getdefviewmask
        my $group = LJ::get_friend_group($userid, { name => 'Default View' });
        my $grp = $group ? $group->{groupnum}+0 : 0;
        $groupmask |= (1 << $grp) if $grp;
    }

    # TAG:FR:ljlib:add_friend
    my $bind = join(",", map { "(?,?,?,?,?)" } @add_ids);
    my @vals = map { $userid, $_, $fgcol, $bgcol, $groupmask } @add_ids;

    my $res = LJ::_friends_do
        ($userid, "REPLACE INTO friends (userid, friendid, fgcolor, bgcolor, groupmask) VALUES $bind", @vals);

    my $sclient = LJ::theschwartz();
    my $friender = LJ::load_userid($userid);

    # part of the criteria for whether to fire befriended event
    my $notify = !$LJ::DISABLED{esn} && !$opts->{nonotify}
                 && $friender->is_visible && $friender->is_person;

    # delete friend-of memcache keys for anyone who was added
    foreach my $fid (@add_ids) {
        LJ::MemCache::delete([ $userid, "frgmask:$userid:$fid" ]);
        LJ::memcache_kill($fid, 'friendofs');
        LJ::memcache_kill($fid, 'friendofs2');

        if ($sclient) {
            my @jobs;

            # only fire event if the friender is a person and not banned and visible
            my $friender = LJ::load_userid($userid);
            my $friendee = LJ::load_userid($fid);
            if ($notify && !$friendee->is_banned($friender)) {
                push @jobs, LJ::Event::Befriended->new($friendee, $friender)->fire_job;
            }

            push @jobs, TheSchwartz::Job->new(
                                              funcname => "LJ::Worker::FriendChange",
                                              arg      => [$fid, 'add', $userid],
                                              ) unless $LJ::DISABLED{'friendchange-schwartz'};

            $sclient->insert_jobs(@jobs) if @jobs;
        }

    }
    LJ::memcache_kill($userid, 'friends');
    LJ::memcache_kill($userid, 'friends2');

    return $res;
}

# <LJFUNC>
# name: LJ::remove_friend
# args: uuid, to_del
# des-to_del: a single uuid or an arrayref of uuids to remove
# </LJFUNC>
sub remove_friend
{
    my ($userid, $to_del) = @_;

    $userid = LJ::want_userid($userid);
    return undef unless $userid;

    my @del_ids = ref $to_del eq 'ARRAY' ? map { LJ::want_userid($_) } @$to_del : ( LJ::want_userid($to_del) );
    return 0 unless @del_ids;

    my $bind = join(",", map { "?" } @del_ids);
    my $res = LJ::_friends_do($userid, "DELETE FROM friends WHERE userid=? AND friendid IN ($bind)",
                              $userid, @del_ids);

    my $sclient = LJ::theschwartz();
    my $u = LJ::load_userid($userid);

    # delete friend-of memcache keys for anyone who was removed
    foreach my $fid (@del_ids) {
        LJ::MemCache::delete([ $userid, "frgmask:$userid:$fid" ]);
        LJ::memcache_kill($fid, 'friendofs');
        LJ::memcache_kill($fid, 'friendofs2');

        if ($sclient && ! $LJ::DISABLED{'friendchange-schwartz'}) {
            my $job = TheSchwartz::Job->new(
                                            funcname => "LJ::Worker::FriendChange",
                                            arg      => [$fid, 'del', $userid],
                                            );
            $sclient->insert_jobs($job);
        }
    }
    LJ::memcache_kill($userid, 'friends');
    LJ::memcache_kill($userid, 'friends2');

    return $res;
}
*delete_friend_edge = \&LJ::remove_friend;

# <LJFUNC>
# name: LJ::get_friends
# des: Returns friends rows for a given user.
# args: uuserid, mask?, memcache_only?, force?
# des-uuserid: a userid or u object
# des-mask: a security mask to filter on
# des-memcache_only: flag, set to only return data from memcache
# des-force: flag, set to ignore memcache and always hit db
# returns: hashref; keys = friend userids
#                   values = hashrefs of 'friends' columns and their values
# </LJFUNC>
sub get_friends {
    # TAG:FR:ljlib:get_friends
    my ($uuid, $mask, $memcache_only, $force) = @_;
    my $userid = LJ::want_userid($uuid);
    return undef unless $userid;
    return undef if $LJ::FORCE_EMPTY_FRIENDS{$userid};

    unless ($force) {
        my $memc = _get_friends_memc($userid, $mask);
        return $memc if $memc;
    }
    return {} if $memcache_only; # no friends

    # nothing from memcache, select all rows from the
    # database and insert those into memcache
    # then return rows that matched the given groupmask
    my $gc = LJ::gearman_client();
    if (LJ::conf_test($LJ::LOADFRIENDS_USING_GEARMAN) && $gc) {
        my $arg = Storable::nfreeze({ userid => $userid,
                                      mask => $mask });
        my $rv = $gc->do_task('load_friends', \$arg,
                              {
                                  uniq => "$userid",
                                  # FIXME: no on_complete because we don't even
                                  #        do process caching!
                              }
                              );
        return Storable::thaw($$rv);
    }

    # not using fancy gearman path
    return _get_friends_db($userid, $mask);
}

sub _get_friends_memc {
    my $userid = shift
        or Carp::croak("no userid to _get_friends_db");
    my $mask = shift;

    # memcache data version
    my $ver = 1;

    my $packfmt = "NH6H6NC";
    my $packlen = 15;  # bytes

    my @cols = qw(friendid fgcolor bgcolor groupmask showbydefault);

    # first, check memcache
    my $memkey = [$userid, "friends:$userid"];

    my $memfriends = LJ::MemCache::get($memkey);
    return undef unless $memfriends;

    my %friends; # rows to be returned

    # first byte of object is data version
    # only version 1 is meaningful right now
    my $memver = substr($memfriends, 0, 1, '');
    return undef unless $memver == $ver;

    # get each $packlen-byte row
    while (length($memfriends) >= $packlen) {
        my @row = unpack($packfmt, substr($memfriends, 0, $packlen, ''));

        # don't add into %friends hash if groupmask doesn't match
        next if $mask && ! ($row[3]+0 & $mask+0);

        # add "#" to beginning of colors
        $row[$_] = "\#$row[$_]" foreach 1..2;

        # turn unpacked row into hashref
        my $fid = $row[0];
        my $idx = 1;
        foreach my $col (@cols[1..$#cols]) {
            $friends{$fid}->{$col} = $row[$idx];
            $idx++;
        }
    }

    # got from memcache, return
    return \%friends;
}

sub _get_friends_db {
    my $userid = shift
        or Carp::croak("no userid to _get_friends_db");
    my $mask = shift;

    my $dbh = LJ::get_db_writer();

    my $lockname = "get_friends:$userid";
    my $release_lock = sub {
        LJ::release_lock($dbh, "global", $lockname);
    };

    # get a lock
    my $lock = LJ::get_lock($dbh, "global", $lockname);
    return {} unless $lock;

    # in lock, try memcache
    my $memc = _get_friends_memc($userid, $mask);
    if ($memc) {
        $release_lock->();
        return $memc;
    }

    # inside lock, but still not populated, query db

    # memcache data info
    my $ver = 1;
    my $memkey = [$userid, "friends:$userid"];
    my $packfmt = "NH6H6NC";
    my $packlen = 15;  # bytes

    # columns we're selecting
    my @cols = qw(friendid fgcolor bgcolor groupmask showbydefault);

    my $mempack = $ver; # full packed string to insert into memcache, byte 1 is dversion
    my %friends;        # friends object to be returned, all groupmasks match

    my $sth = $dbh->prepare("SELECT friendid, fgcolor, bgcolor, groupmask, showbydefault " .
                            "FROM friends WHERE userid=?");
    $sth->execute($userid);
    die $dbh->errstr if $dbh->err;
    while (my @row = $sth->fetchrow_array) {

        # convert color columns to hex
        $row[$_] = sprintf("%06x", $row[$_]) foreach 1..2;

        my $newpack = pack($packfmt, @row);
        last if length($mempack) + length($newpack) > 950*1024;

        $mempack .= $newpack;

        # unless groupmask matches, skip adding to %friends
        next if $mask && ! ($row[3]+0 & $mask+0);

        # add "#" to beginning of colors
        $row[$_] = "\#$row[$_]" foreach 1..2;

        my $fid = $row[0];
        my $idx = 1;
        foreach my $col (@cols[1..$#cols]) {
            $friends{$fid}->{$col} = $row[$idx];
            $idx++;
        }
    }

    LJ::MemCache::add($memkey, $mempack);

    # finished with lock, release it
    $release_lock->();

    return \%friends;
}

# <LJFUNC>
# name: LJ::get_friendofs
# des: Returns userids of friendofs for a given user.
# args: uuserid, opts?
# des-opts: options hash, keys: 'force' => don't check memcache
# returns: userid for friendofs
# </LJFUNC>
sub get_friendofs {
    # TAG:FR:ljlib:get_friends
    my ($uuid, $opts) = @_;
    my $userid = LJ::want_userid($uuid);
    return undef unless $userid;

    # first, check memcache
    my $memkey = [$userid, "friendofs:$userid"];

    unless ($opts->{force}) {
        my $memfriendofs = LJ::MemCache::get($memkey);
        return @$memfriendofs if $memfriendofs;
    }

    # nothing from memcache, select all rows from the
    # database and insert those into memcache

    my $dbh = LJ::get_db_writer();
    my $limit = $opts->{force} ? '' : " LIMIT " . ($LJ::MAX_FRIENDOF_LOAD+1);
    my $friendofs = $dbh->selectcol_arrayref
        ("SELECT userid FROM friends WHERE friendid=?$limit",
         undef, $userid) || [];
    die $dbh->errstr if $dbh->err;

    LJ::MemCache::add($memkey, $friendofs);

    return @$friendofs;
}

# <LJFUNC>
# name: LJ::get_friend_group
# des: Returns friendgroup row(s) for a given user.
# args: uuserid, opt?
# des-uuserid: a userid or u object
# des-opt: a hashref with keys: 'bit' => bit number of group to return
#                               'name' => name of group to return
# returns: hashref; if bit/name are specified, returns hashref with keys being
#                   friendgroup rows, or undef if the group wasn't found.
#
#                   otherwise, returns hashref of all group rows with keys being
#                   group bit numbers and values being row col => val hashrefs
# </LJFUNC>
sub get_friend_group {
    my ($uuid, $opt) = @_;
    my $u = LJ::want_user($uuid);
    return undef unless $u;
    my $uid = $u->{userid};

    # data version number
    my $ver = 1;

    # sanity check bitnum
    delete $opt->{'bit'} if
        $opt->{'bit'} > 31 || $opt->{'bit'} < 0;

    my $fg;
    my $find_grp = sub {

        # $fg format:
        # [ version, [userid, bitnum, name, sortorder, public], [...], ... ]

        my $memver = shift @$fg;
        return undef unless $memver == $ver;

        # bit number was specified
        if ($opt->{'bit'}) {
            foreach (@$fg) {
                return LJ::MemCache::array_to_hash("fgrp", [$memver, @$_])
                    if $_->[1] == $opt->{'bit'};
            }
            return undef;
        }

        # group name was specified
        if ($opt->{'name'}) {
            foreach (@$fg) {
                return LJ::MemCache::array_to_hash("fgrp", [$memver, @$_])
                    if lc($_->[2]) eq lc($opt->{'name'});
            }
            return undef;
        }

        # no arg, return entire object
        return { map { $_->[1] => LJ::MemCache::array_to_hash("fgrp", [$memver, @$_]) } @$fg };
    };

    # check memcache
    my $memkey = [$uid, "fgrp:$uid"];
    $fg = LJ::MemCache::get($memkey);
    return $find_grp->() if $fg;

    # check database
    $fg = [$ver];
    my ($db, $fgtable) = $u->{dversion} > 5 ?
                         (LJ::get_cluster_def_reader($u), 'friendgroup2') : # if dversion is 6+, use definitive reader
                         (LJ::get_db_writer(), 'friendgroup');              # else, use regular db writer
    return undef unless $db;

    my $sth = $db->prepare("SELECT userid, groupnum, groupname, sortorder, is_public " .
                           "FROM $fgtable WHERE userid=?");
    $sth->execute($uid);
    return LJ::error($db) if $db->err;

    my @row;
    push @$fg, [ @row ] while @row = $sth->fetchrow_array;

    # set in memcache
    LJ::MemCache::set($memkey, $fg);

    return $find_grp->();
}


# <LJFUNC>
# name: LJ::fill_groups_xmlrpc
# des: Fills a hashref (presumably to be sent to an XMLRPC client, EG fotobilder)
#      with user friend group information
# args: u, ret
# des-ret: a response hashref to fill with friend group data
# returns: undef if called incorrectly, 1 otherwise
# </LJFUNC>
sub fill_groups_xmlrpc {
    my ($u, $ret) = @_;
    return undef unless ref $u && ref $ret;

    # best interface ever...
    $RPC::XML::ENCODING = "utf-8";

    # layer on friend group information in the following format:
    #
    # grp:1 => 'mygroup',
    # ...
    # grp:30 => 'anothergroup',
    #
    # grpu:whitaker => '0,1,2,3,4',
    # grpu:test => '0',

    my $grp = LJ::get_friend_group($u) || {};

    # we don't always have RPC::XML loaded (in web context), and it doesn't really
    # matter much anyway, since our only consumer is also perl which will take
    # the occasional ints back to strings.
    my $str = sub {
        my $str = shift;
        my $val = eval { RPC::XML::string->new($str); };
        return $val unless $@;
        return $str;
    };

    $ret->{"grp:0"} = $str->("_all_");
    foreach my $bit (1..30) {
        next unless my $g = $grp->{$bit};
        $ret->{"grp:$bit"} = $str->($g->{groupname});
    }

    my $fr = LJ::get_friends($u) || {};
    my $users = LJ::load_userids(keys %$fr);
    while (my ($fid, $f) = each %$fr) {
        my $u = $users->{$fid};
        next unless $u->{journaltype} =~ /[PSI]/;

        my $fname = $u->{user};
        $ret->{"grpu:$fid:$fname"} =
            $str->(join(",", 0, grep { $grp->{$_} && $f->{groupmask} & 1 << $_ } 1..30));
    }

    return 1;
}

# <LJFUNC>
# name: LJ::mark_dirty
# des: Marks a given user as being $what type of dirty
# args: u, what
# des-what: type of dirty being marked (EG 'friends')
# returns: 1
# </LJFUNC>
sub mark_dirty {
    my ($uuserid, $what) = @_;

    my $userid = LJ::want_userid($uuserid);
    return 1 if $LJ::REQ_CACHE_DIRTY{$what}->{$userid};

    my $u = LJ::want_user($userid);

    # friends dirtiness is only necessary to track
    # if we're exchange XMLRPC with fotobilder
    if ($what eq 'friends') {
        return 1 unless $LJ::FB_SITEROOT;
        my $sclient = LJ::theschwartz();

        push @LJ::CLEANUP_HANDLERS, sub {
            if ($sclient) {
                my $job = TheSchwartz::Job->new(
                                                funcname => "LJ::Worker::UpdateFotobilderFriends",
                                                coalesce => "uid:$u->{userid}",
                                                arg      => $u->{userid},
                                                );
                $sclient->insert($job);
            } else {
                LJ::cmd_buffer_add($u->{clusterid}, $u->{userid}, 'dirty', { what => 'friends' });
            }
        };
    }

    $LJ::REQ_CACHE_DIRTY{$what}->{$userid}++;

    return 1;
}

# <LJFUNC>
# name: LJ::memcache_kill
# des: Kills a memcache entry, given a userid and type
# args: uuserid, type
# des-uuserid: a userid or u object
# des-args: memcache key type, will be used as "$type:$userid"
# returns: results of LJ::MemCache::delete
# </LJFUNC>
sub memcache_kill {
    my ($uuid, $type) = @_;
    my $userid = want_userid($uuid);
    return undef unless $userid && $type;

    return LJ::MemCache::delete([$userid, "$type:$userid"]);
}

# <LJFUNC>
# name: LJ::delete_all_comments
# des: deletes all comments from a post, permanently, for when a post is deleted
# info: The tables [dbtable[talk2]], [dbtable[talkprop2]], [dbtable[talktext2]],
#       are deleted from, immediately.
# args: u, nodetype, nodeid
# des-nodetype: The thread nodetype (probably 'L' for log items)
# des-nodeid: The thread nodeid for the given nodetype (probably the jitemid from the log2 row)
# returns: boolean; success value
# </LJFUNC>
sub delete_all_comments {
    my ($u, $nodetype, $nodeid) = @_;

    my $dbcm = LJ::get_cluster_master($u);
    return 0 unless $dbcm && $u->writer;

    # delete comments
    my ($t, $loop) = (undef, 1);
    my $chunk_size = 200;
    while ($loop &&
           ($t = $dbcm->selectcol_arrayref("SELECT jtalkid FROM talk2 WHERE ".
                                           "nodetype=? AND journalid=? ".
                                           "AND nodeid=? LIMIT $chunk_size", undef,
                                           $nodetype, $u->{'userid'}, $nodeid))
           && $t && @$t)
    {
        my $in = join(',', map { $_+0 } @$t);
        return 1 unless $in;
        foreach my $table (qw(talkprop2 talktext2 talk2)) {
            $u->do("DELETE FROM $table WHERE journalid=? AND jtalkid IN ($in)",
                   undef, $u->{'userid'});
        }
        # decrement memcache
        LJ::MemCache::decr([$u->{'userid'}, "talk2ct:$u->{'userid'}"], scalar(@$t));
        $loop = 0 unless @$t == $chunk_size;
    }
    return 1;

}

# is a user object (at least a hashref)
sub isu {
    return unless ref $_[0];
    return 1 if UNIVERSAL::isa($_[0], "LJ::User");

    if (ref $_[0] eq "HASH" && $_[0]->{userid}) {
        carp "User HASH objects are depricated from use." if $LJ::IS_DEV_SERVER;
        return 1;
    }
}

# create externally mapped user.
# return uid of LJ user on success, undef on error.
# opts = {
#     extuser or extuserid (or both, but one is required.),
#     caps
# }
# opts also can contain any additional options that create_account takes. (caps?)
sub create_extuser
{
    my ($type, $opts) = @_;
    return undef unless $type && $LJ::EXTERNAL_NAMESPACE{$type}->{id};
    return undef unless ref $opts &&
        ($opts->{extuser} || defined $opts->{extuserid});

    my $uid;
    my $dbh = LJ::get_db_writer();
    return undef unless $dbh;

    # make sure a mapping for this user doesn't already exist.
    $uid = LJ::get_extuser_uid( $type, $opts, 'force' );
    return $uid if $uid;

    # increment ext_ counter until we successfully create an LJ account.
    # hard cap it at 10 tries. (arbitrary, but we really shouldn't have *any*
    # failures here, let alone 10 in a row.)
    for (1..10) {
        my $extuser = 'ext_' . LJ::alloc_global_counter( 'E' );
        $uid =
          LJ::create_account(
            { caps => $opts->{caps}, user => $extuser, name => $extuser } );
        last if $uid;
        select undef, undef, undef, .10;  # lets not thrash over this.
    }
    return undef unless $uid;

    # add extuser mapping.
    my $sql = "INSERT INTO extuser SET userid=?, siteid=?";
    my @bind = ($uid, $LJ::EXTERNAL_NAMESPACE{$type}->{id});

    if ($opts->{extuser}) {
        $sql .= ", extuser=?";
        push @bind, $opts->{extuser};
    }

    if ($opts->{extuserid}) {
        $sql .= ", extuserid=? ";
        push @bind, $opts->{extuserid}+0;
    }

    $dbh->do($sql, undef, @bind) or return undef;
    return $uid;
}

# given an extuserid or extuser, return the LJ uid.
# return undef if there is no mapping.
sub get_extuser_uid
{
    my ($type, $opts, $force) = @_;
    return undef unless $type && $LJ::EXTERNAL_NAMESPACE{$type}->{id};
    return undef unless ref $opts &&
        ($opts->{extuser} || defined $opts->{extuserid});

    my $dbh = $force ? LJ::get_db_writer() : LJ::get_db_reader();
    return undef unless $dbh;

    my $sql = "SELECT userid FROM extuser WHERE siteid=?";
    my @bind = ($LJ::EXTERNAL_NAMESPACE{$type}->{id});

    if ($opts->{extuser}) {
        $sql .= " AND extuser=?";
        push @bind, $opts->{extuser};
    }

    if ($opts->{extuserid}) {
        $sql .= $opts->{extuser} ? ' OR ' : ' AND ';
        $sql .= "extuserid=?";
        push @bind, $opts->{extuserid}+0;
    }

    return $dbh->selectrow_array($sql, undef, @bind);
}

# given a LJ userid/u, return a hashref of:
# type, extuser, extuserid
# returns undef if user isn't an externally mapped account.
sub get_extuser_map
{
    my $uid = LJ::want_userid(shift);
    return undef unless $uid;

    my $dbr = LJ::get_db_reader();
    return undef unless $dbr;

    my $sql = "SELECT * FROM extuser WHERE userid=?";
    my $ret = $dbr->selectrow_hashref($sql, undef, $uid);
    return undef unless $ret;

    my $type = 'unknown';
    foreach ( keys %LJ::EXTERNAL_NAMESPACE ) {
        $type = $_ if $LJ::EXTERNAL_NAMESPACE{$_}->{id} == $ret->{siteid};
    }

    $ret->{type} = $type;
    return $ret;
}

# <LJFUNC>
# name: LJ::create_account
# des: Creates a new basic account.  <b>Note:</b> This function is
#      not really too useful but should be extended to be useful so
#      htdocs/create.bml can use it, rather than doing the work itself.
# returns: integer of userid created, or 0 on failure.
# args: dbarg?, opts
# des-opts: hashref containing keys 'user', 'name', 'password', 'email', 'caps', 'journaltype'
# </LJFUNC>
sub create_account
{
    &nodb;
    my $o = shift;

    my $user = LJ::canonical_username($o->{'user'});
    unless ($user)  {
        return 0;
    }

    my $dbh = LJ::get_db_writer();
    my $quser = $dbh->quote($user);
    my $cluster = defined $o->{'cluster'} ? $o->{'cluster'} : LJ::new_account_cluster();
    my $caps = $o->{'caps'} || $LJ::NEWUSER_CAPS;
    my $journaltype = $o->{'journaltype'} || "P";

    # new non-clustered accounts aren't supported anymore
    return 0 unless $cluster;

    $dbh->do("INSERT INTO user (user, name, clusterid, dversion, caps, journaltype) ".
             "VALUES ($quser, ?, ?, $LJ::MAX_DVERSION, ?, ?)", undef,
             $o->{'name'}, $cluster, $caps, $journaltype);
    return 0 if $dbh->err;

    my $userid = $dbh->{'mysql_insertid'};
    return 0 unless $userid;

    LJ::set_email($userid, $o->{email});
    LJ::set_password($userid, $o->{password});

    $dbh->do("INSERT INTO useridmap (userid, user) VALUES ($userid, $quser)");
    $dbh->do("INSERT INTO userusage (userid, timecreate) VALUES ($userid, NOW())");

    LJ::run_hooks("post_create", {
        'userid' => $userid,
        'user' => $user,
        'code' => undef,
    });
    return $userid;
}

# <LJFUNC>
# name: LJ::new_account_cluster
# des: Which cluster to put a new account on.  $DEFAULT_CLUSTER if it's
#      a scalar, random element from @$DEFAULT_CLUSTER if it's arrayref.
#      also verifies that the database seems to be available.
# returns: clusterid where the new account should be created; 0 on error
#      (such as no clusters available)
# </LJFUNC>
sub new_account_cluster
{
    # if it's not an arrayref, put it in an array ref so we can use it below
    my $clusters = ref $LJ::DEFAULT_CLUSTER ? $LJ::DEFAULT_CLUSTER : [ $LJ::DEFAULT_CLUSTER+0 ];

    # iterate through the new clusters from a random point
    my $size = @$clusters;
    my $start = int(rand() * $size);
    foreach (1..$size) {
        my $cid = $clusters->[$start++ % $size];

        # verify that this cluster is in @LJ::CLUSTERS
        my @check = grep { $_ == $cid } @LJ::CLUSTERS;
        next unless scalar(@check) >= 1 && $check[0] == $cid;

        # try this cluster to see if we can use it, return if so
        my $dbcm = LJ::get_cluster_master($cid);
        return $cid if $dbcm;
    }

    # if we get here, we found no clusters that were up...
    return 0;
}

# <LJFUNC>
# name: LJ::make_journal
# class:
# des:
# info:
# args: dbarg, user, view, remote, opts
# des-:
# returns:
# </LJFUNC>
sub make_journal
{
    &nodb;
    my ($user, $view, $remote, $opts) = @_;

    my $r = $opts->{'r'};  # mod_perl $r, or undef
    my $geta = $opts->{'getargs'};

    if ($LJ::SERVER_DOWN) {
        if ($opts->{'vhost'} eq "customview") {
            return "<!-- LJ down for maintenance -->";
        }
        return LJ::server_down_html();
    }

    my $u = $opts->{'u'} || LJ::load_user($user);
    unless ($u) {
        $opts->{'baduser'} = 1;
        return "<h1>Error</h1>No such user <b>$user</b>";
    }
    LJ::set_active_journal($u);

    # S1 style hashref.  won't be loaded now necessarily,
    # only if via customview.
    my $style;

    my ($styleid);
    if ($opts->{'styleid'}) {  # s1 styleid
        $styleid = $opts->{'styleid'}+0;

        # if we have an explicit styleid, we have to load
        # it early so we can learn its type, so we can
        # know which uprops to load for its owner
        if ($LJ::ONLY_USER_VHOSTS && $opts->{vhost} eq "customview") {
            # reject this style if it's not trusted by the user, and we're showing
            # stuff on user domains
            my $ownerid = LJ::S1::get_style_userid_always($styleid);
            my $is_trusted = sub {
                return 1 if $ownerid == $u->{userid};
                return 1 if $ownerid == LJ::system_userid();
                return 1 if $LJ::S1_CUSTOMVIEW_WHITELIST{"styleid-$styleid"};
                return 1 if $LJ::S1_CUSTOMVIEW_WHITELIST{"userid-$ownerid"};
                my $trust_list = eval { $u->prop("trusted_s1") };
                return 1 if $trust_list =~ /\b$styleid\b/;
                return 0;
            };
            unless ($is_trusted->()) {
                $style = undef;
                $styleid = 0;
            }
        }
    } else {
        $view ||= "lastn";    # default view when none specified explicitly in URLs
        if ($LJ::viewinfo{$view} || $view eq "month" ||
            $view eq "entry" || $view eq "reply")  {
            $styleid = -1;    # to get past the return, then checked later for -1 and fixed, once user is loaded.
        } else {
            $opts->{'badargs'} = 1;
        }
    }
    return unless $styleid;


    $u->{'_journalbase'} = LJ::journal_base($u->{'user'}, $opts->{'vhost'});

    my $eff_view = $LJ::viewinfo{$view}->{'styleof'} || $view;
    my $s1prop = "s1_${eff_view}_style";

    my @needed_props = ("stylesys", "s2_style", "url", "urlname", "opt_nctalklinks",
                        "renamedto",  "opt_blockrobots", "opt_usesharedpic", "icbm",
                        "journaltitle", "journalsubtitle", "external_foaf_url");

    # S2 is more fully featured than S1, so sometimes we get here and $eff_view
    # is reply/month/entry/res and that means it *has* to be S2--S1 defaults to a
    # BML page to handle those, but we don't want to attempt to load a userprop
    # because now load_user_props dies if you try to load something invalid
    push @needed_props, $s1prop if $eff_view =~ /^(?:calendar|day|friends|lastn)$/;

    # preload props the view creation code will need later (combine two selects)
    if (ref $LJ::viewinfo{$eff_view}->{'owner_props'} eq "ARRAY") {
        push @needed_props, @{$LJ::viewinfo{$eff_view}->{'owner_props'}};
    }

    if ($eff_view eq "reply") {
        push @needed_props, "opt_logcommentips";
    }

    $u->preload_props(@needed_props);

    # FIXME: remove this after all affected accounts have been fixed
    # see http://zilla.livejournal.org/1443 for details
    if ($u->{$s1prop} =~ /^\D/) {
        $u->{$s1prop} = $LJ::USERPROP_DEF{$s1prop};
        $u->set_prop($s1prop, $u->{$s1prop});
    }

    # if the remote is the user to be viewed, make sure the $remote
    # hashref has the value of $u's opt_nctalklinks (though with
    # LJ::load_user caching, this may be assigning between the same
    # underlying hashref)
    $remote->{'opt_nctalklinks'} = $u->{'opt_nctalklinks'} if
        ($remote && $remote->{'userid'} == $u->{'userid'});

    my $stylesys = 1;
    if ($styleid == -1) {

        my $get_styleinfo = sub {

            my $get_s1_styleid = sub {
                my $id = $u->{$s1prop};
                LJ::run_hooks("s1_style_select", {
                    'styleid' => \$id,
                    'u' => $u,
                    'view' => $view,
                });
                return $id;
            };

            # forced s2 style id
            if ($geta->{'s2id'} && LJ::get_cap($u, "s2styles")) {

                # see if they own the requested style
                my $dbr = LJ::get_db_reader();
                my $style_userid = $dbr->selectrow_array("SELECT userid FROM s2styles WHERE styleid=?",
                                                         undef, $geta->{'s2id'});

                # if remote owns the style or the journal owns the style, it's okay
                if ($u->{'userid'} == $style_userid ||
                    ($remote && $remote->{'userid'} == $style_userid) ) {
                    $opts->{'style_u'} = LJ::load_userid($style_userid);
                    return (2, $geta->{'s2id'});
                }
            }

            # style=mine passed in GET?
            if ($remote && $geta->{'style'} eq 'mine') {

                # get remote props and decide what style remote uses
                $remote->preload_props("stylesys", "s2_style");

                # remote using s2; make sure we pass down the $remote object as the style_u to
                # indicate that they should use $remote to load the style instead of the regular $u
                if ($remote->{'stylesys'} == 2 && $remote->{'s2_style'}) {
                    $opts->{'checkremote'} = 1;
                    $opts->{'style_u'} = $remote;
                    return (2, $remote->{'s2_style'});
                }

                # remote using s1
                return (1, $get_s1_styleid->());
            }

            # resource URLs have the styleid in it
            if ($view eq "res" && $opts->{'pathextra'} =~ m!^/(\d+)/!) {
                return (2, $1);
            }

            my $forceflag = 0;
            LJ::run_hooks("force_s1", $u, \$forceflag);

            # if none of the above match, they fall through to here
            if ( !$forceflag && $u->{'stylesys'} == 2 ) {
                return (2, $u->{'s2_style'});
            }

            # no special case and not s2, fall through to s1
            return (1, $get_s1_styleid->());
        };

        ($stylesys, $styleid) = $get_styleinfo->();
    }

    # transcode the tag filtering information into the tag getarg; this has to
    # be done above the s1shortcomings section so that we can fall through to that
    # style for lastn filtered by tags view
    if ($view eq 'lastn' && $opts->{pathextra} && $opts->{pathextra} =~ /^\/tag\/(.+)$/) {
        $opts->{getargs}->{tag} = LJ::durl($1);
        $opts->{pathextra} = undef;
    }

    if ($r) {
        $r->notes('journalid' => $u->{'userid'});
    }

    my $notice = sub {
        my $msg = shift;
        my $status = shift;

        my $url = "$LJ::SITEROOT/users/$user/";
        $opts->{'status'} = $status if $status;

        my $head;
        my $journalbase = LJ::journal_base($user);

        # Automatic Discovery of RSS/Atom
        $head .= qq{<link rel="alternate" type="application/rss+xml" title="RSS" href="$journalbase/data/rss" />\n};
        $head .= qq{<link rel="alternate" type="application/atom+xml" title="Atom" href="$journalbase/data/atom" />\n};
        $head .= qq{<link rel="service.feed" type="application/atom+xml" title="AtomAPI-enabled feed" href="$LJ::SITEROOT/interface/atom/feed" />\n};
        $head .= qq{<link rel="service.post" type="application/atom+xml" title="Create a new post" href="$LJ::SITEROOT/interface/atom/post" />\n};

        # OpenID Server and Yadis
       if (LJ::OpenID->server_enabled) {
            $head .= qq{<link rel="openid.server" href="$LJ::OPENID_SERVER" />\n};
            $head .= qq{<meta http-equiv="X-XRDS-Location" content="$journalbase/data/yadis" />\n};
        }

        # FOAF autodiscovery
        my $foafurl = $u->{external_foaf_url} ? LJ::eurl($u->{external_foaf_url}) : "$journalbase/data/foaf";
        my $digest = Digest::SHA1::sha1_hex('mailto:' . $u->email_raw);
        $head .= qq{<link rel="meta" type="application/rdf+xml" title="FOAF" href="$foafurl" />\n};
        $head .= qq{<meta name="foaf:maker" content="foaf:mbox_sha1sum '$digest'" />\n};

        return qq{
            <html>
            <head>
            $head
            </head>
            <body>
             <h1>Notice</h1>
             <p>$msg</p>
             <p>Instead, please use <nobr><a href=\"$url\">$url</a></nobr></p>
            </body>
            </html>
        }.("<!-- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx -->\n" x 50);
    };
    my $error = sub {
        my $msg = shift;
        my $status = shift;
        $opts->{'status'} = $status if $status;

        return qq{
            <h1>Error</h1>
            <p>$msg</p>
        }.("<!-- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx -->\n" x 50);
    };
    if ($LJ::USER_VHOSTS && $opts->{'vhost'} eq "users" && $u->{'journaltype'} ne 'R' &&
        ! LJ::get_cap($u, "userdomain")) {
        return $notice->("URLs like <nobr><b>http://<i>username</i>.$LJ::USER_DOMAIN/" .
                         "</b></nobr> are not available for this user's account type.");
    }
    if ($opts->{'vhost'} =~ /^other:/ && ! LJ::get_cap($u, "domainmap")) {
        return $notice->("This user's account type doesn't permit domain aliasing.");
    }
    if ($opts->{'vhost'} eq "customview" && ! LJ::get_cap($u, "styles")) {
        return $notice->("This user's account type is not permitted to create and embed styles.");
    }
    if ($opts->{'vhost'} eq "community" && $u->{'journaltype'} !~ /[CR]/) {
        $opts->{'badargs'} = 1; # Output a generic 'bad URL' message if available
        return "<h1>Notice</h1><p>This account isn't a community journal.</p>";
    }
    if ($view eq "friendsfriends" && ! LJ::get_cap($u, "friendsfriendsview")) {
        my $inline;
        if ($inline .= LJ::run_hook("cprod_inline", $u, 'FriendsFriendsInline')) {
            return $inline;
        } else {
            return BML::ml('cprod.friendsfriendsinline.text.v1');
        }
    }

    # signal to LiveJournal.pm that we can't handle this
    if (($stylesys == 1 || $geta->{'format'} eq 'light') && (({ entry=>1, reply=>1, month=>1, tag=>1 }->{$view}) || ($view eq 'lastn' && $geta->{tag}))) {

        # pick which fallback method (s2 or bml) we'll use by default, as configured with
        # $S1_SHORTCOMINGS
        my $fallback = $LJ::S1_SHORTCOMINGS ? "s2" : "bml";

        # but if the user specifys which they want, override the fallback we picked
        if ($geta->{'fallback'} && $geta->{'fallback'} =~ /^s2|bml$/) {
            $fallback = $geta->{'fallback'};
        }

        # if we are in this path, and they have style=mine set, it means
        # they either think they can get a S2 styled page but their account
        # type won't let them, or they really want this to fallback to bml
        if ($remote && $geta->{'style'} eq 'mine') {
            $fallback = 'bml';
        }

        # If they specified ?format=light, it means they want a page easy
        # to deal with text-only or on a mobile device.  For now that means
        # render it in the lynx site scheme.
        if ($geta->{'format'} eq 'light') {
            $fallback = 'bml';
            $r->notes('bml_use_scheme' => 'lynx');
        }

        # there are no BML handlers for these views, so force s2
        if ($view eq 'tag' || $view eq 'lastn') {
            $fallback = "s2";
        }

        # fall back to BML unless we're using the in-development S2
        # fallback (the "s1shortcomings/layout")
        if ($fallback eq "bml") {
            ${$opts->{'handle_with_bml_ref'}} = 1;
            return;
        }

        # S1 can't handle these views, so we fall back to a
        # system-owned S2 style (magic value "s1short") that renders
        # this content
        $stylesys = 2;
        $styleid = "s1short";
    }

    # now, if there's a GET argument for tags, split those out
    if (exists $opts->{getargs}->{tag}) {
        my $tagfilter = $opts->{getargs}->{tag};
        return $error->("You must provide tags to filter by.", "404 Not Found")
            unless $tagfilter;

        # error if disabled
        return $error->("Sorry, the tag system is currently disabled.", "404 Not Found")
            if $LJ::DISABLED{tags};

        # throw an error if we're rendering in S1, but not for renamed accounts
        return $error->("Sorry, tag filtering is not supported within S1 styles.", "404 Not Found")
            if $stylesys == 1 && $view ne 'data' && $u->{journaltype} ne 'R';

        # overwrite any tags that exist
        $opts->{tags} = [];
        return $error->("Sorry, the tag list specified is invalid.", "404 Not Found")
            unless LJ::Tags::is_valid_tagstring($tagfilter, $opts->{tags}, { omit_underscore_check => 1 });

        # get user's tags so we know what remote can see, and setup an inverse mapping
        # from keyword to tag
        $opts->{tagids} = [];
        my $tags = LJ::Tags::get_usertags($u, { remote => $remote });
        my %kwref = ( map { $tags->{$_}->{name} => $_ } keys %{$tags || {}} );

        foreach (@{$opts->{tags}}) {
            return $error->("Sorry, one or more specified tags do not exist.", "404 Not Found")
                unless $kwref{$_};
            push @{$opts->{tagids}}, $kwref{$_};
        }
    }

    unless ($geta->{'viewall'} && LJ::check_priv($remote, "canview") ||
            $opts->{'pathextra'} =~ m#/(\d+)/stylesheet$#) { # don't check style sheets
        return $error->("Journal has been deleted.  If you are <b>$user</b>, you have a period of 30 days to decide to undelete your journal.", "404 Not Found") if ($u->is_deleted);
        return $error->("This journal has been suspended.", "403 Forbidden") if ($u->is_suspended);
    }
    return $error->("This journal has been deleted and purged.", "410 Gone") if ($u->is_expunged);

    return $error->("This user has no journal here.", "404 Not here") if $u->{'journaltype'} eq "I" && $view ne "friends";

    $opts->{'view'} = $view;

    # what charset we put in the HTML
    $opts->{'saycharset'} ||= "utf-8";

    if ($view eq 'data') {
        return LJ::Feed::make_feed($r, $u, $remote, $opts);
    }

    if ($stylesys == 2) {
        $r->notes('codepath' => "s2.$view") if $r;

        eval { LJ::S2->can("dostuff") };  # force Class::Autouse
        my $mj = LJ::S2::make_journal($u, $styleid, $view, $remote, $opts);

        # intercept flag to handle_with_bml_ref and instead use S1 shortcomings
        # if BML is disabled
        if ($opts->{'handle_with_bml_ref'} && ${$opts->{'handle_with_bml_ref'}} &&
            ($LJ::S1_SHORTCOMINGS || $geta->{fallback} eq "s2"))
        {
            # kill the flag
            ${$opts->{'handle_with_bml_ref'}} = 0;

            # and proceed with s1shortcomings (which looks like BML) instead of BML
            $mj = LJ::S2::make_journal($u, "s1short", $view, $remote, $opts);
        }

        return $mj;
    }

    # Everything from here on down is S1.  FIXME: this should be moved to LJ::S1::make_journal
    # to be more like LJ::S2::make_journal.
    $r->notes('codepath' => "s1.$view") if $r;

    # For embedded polls
    BML::set_language($LJ::LANGS[0] || 'en', \&LJ::Lang::get_text);

    # load the user-related S1 data  (overrides and colors)
    my $s1uc = {};
    my $s1uc_memkey = [$u->{'userid'}, "s1uc:$u->{'userid'}"];
    if ($u->{'useoverrides'} eq "Y" || $u->{'themeid'} == 0) {
        $s1uc = LJ::MemCache::get($s1uc_memkey);
        unless ($s1uc) {
            my $db;
            my $setmem = 1;
            if (@LJ::MEMCACHE_SERVERS) {
                $db = LJ::get_cluster_def_reader($u);
            } else {
                $db = LJ::get_cluster_reader($u);
                $setmem = 0;
            }
            $s1uc = $db->selectrow_hashref("SELECT * FROM s1usercache WHERE userid=?",
                                           undef, $u->{'userid'});
            LJ::MemCache::set($s1uc_memkey, $s1uc) if $s1uc && $setmem;
        }
    }

    # we should have our cache row!  we'll update it in a second.
    my $dbcm;
    if (! $s1uc) {
        $u->do("INSERT IGNORE INTO s1usercache (userid) VALUES (?)", undef, $u->{'userid'});
        $s1uc = {};
    }

    # conditionally rebuild parts of our cache that are missing
    my %update;

    # is the overrides cache old or missing?
    my $dbh;
    if ($u->{'useoverrides'} eq "Y" && (! $s1uc->{'override_stor'} ||
                                        $s1uc->{'override_cleanver'} < $LJ::S1::CLEANER_VERSION)) {

        my $overrides = LJ::S1::get_overrides($u);
        $update{'override_stor'} = LJ::CleanHTML::clean_s1_style($overrides);
        $update{'override_cleanver'} = $LJ::S1::CLEANER_VERSION;
    }

    # is the color cache here if it's a custom user theme?
    if ($u->{'themeid'} == 0 && ! $s1uc->{'color_stor'}) {
        my $col = {};
        $dbh ||= LJ::get_db_writer();
        my $sth = $dbh->prepare("SELECT coltype, color FROM themecustom WHERE user=?");
        $sth->execute($u->{'user'});
        $col->{$_->{'coltype'}} = $_->{'color'} while $_ = $sth->fetchrow_hashref;
        $update{'color_stor'} = Storable::freeze($col);
    }

    # save the updates
    if (%update) {
        my $set;
        foreach my $k (keys %update) {
            $s1uc->{$k} = $update{$k};
            $set .= ", " if $set;
            $set .= "$k=" . $u->quote($update{$k});
        }
        my $rv = $u->do("UPDATE s1usercache SET $set WHERE userid=?", undef, $u->{'userid'});
        if ($rv && $update{'color_stor'}) {
            $dbh ||= LJ::get_db_writer();
            $dbh->do("DELETE FROM themecustom WHERE user=?", undef, $u->{'user'});
        }
        LJ::MemCache::set($s1uc_memkey, $s1uc);
    }

    # load the style
    my $viewref = $view eq "" ? \$view : undef;
    $style ||= $LJ::viewinfo{$view}->{'nostyle'} ? {} :
        LJ::S1::load_style($styleid, $viewref);

    my %vars = ();

    # apply the style
    foreach (keys %$style) {
        $vars{$_} = $style->{$_};
    }

    # apply the overrides
    if ($opts->{'nooverride'}==0 && $u->{'useoverrides'} eq "Y") {
        my $tw = Storable::thaw($s1uc->{'override_stor'});
        foreach (keys %$tw) {
            $vars{$_} = $tw->{$_};
        }
    }

    # apply the color theme
    my $cols = $u->{'themeid'} ? LJ::S1::get_themeid($u->{'themeid'}) :
        Storable::thaw($s1uc->{'color_stor'});
    foreach (keys %$cols) {
        $vars{"color-$_"} = $cols->{$_};
    }

    # instruct some function to make this specific view type
    return unless defined $LJ::viewinfo{$view}->{'creator'};
    my $ret = "";

    # call the view creator w/ the buffer to fill and the construction variables
    my $res = $LJ::viewinfo{$view}->{'creator'}->(\$ret, $u, \%vars, $remote, $opts);

    unless ($res) {
        my $errcode = $opts->{'errcode'};
        my $errmsg = {
            'nodb' => 'Database temporarily unavailable during maintenance.',
            'nosyn' => 'No syndication URL available.',
        }->{$errcode};
        return "<!-- $errmsg -->" if ($opts->{'vhost'} eq "customview");

        # If not customview, set the error response code.
        $opts->{'status'} = {
            'nodb' => '503 Maintenance',
            'nosyn' => '404 Not Found',
        }->{$errcode} || '500 Server Error';
        return $errmsg;
    }

    if ($opts->{'redir'}) {
        return undef;
    }

    # clean up attributes which we weren't able to quickly verify
    # as safe in the Storable-stored clean copy of the style.
    $ret =~ s/\%\%\[attr\[(.+?)\]\]\%\%/LJ::CleanHTML::s1_attribute_clean($1)/eg;

    # return it...
    return $ret;
}

# <LJFUNC>
# name: LJ::canonical_username
# des:
# info:
# args: user
# returns: the canonical username given, or blank if the username is not well-formed
# </LJFUNC>
sub canonical_username
{
    my $user = shift;
    if ($user =~ /^\s*([A-Za-z0-9_\-]{1,15})\s*$/) {
        # perl 5.8 bug:  $user = lc($1) sometimes causes corruption when $1 points into $user.
        $user = $1;
        $user = lc($user);
        $user =~ s/-/_/g;
        return $user;
    }
    return "";  # not a good username.
}

# <LJFUNC>
# name: LJ::get_userid
# des: Returns a userid given a username.
# info: Results cached in memory.  On miss, does DB call.  Not advised
#       to use this many times in a row... only once or twice perhaps
#       per request.  Tons of serialized db requests, even when small,
#       are slow.  Opposite of [func[LJ::get_username]].
# args: dbarg?, user
# des-user: Username whose userid to look up.
# returns: Userid, or 0 if invalid user.
# </LJFUNC>
sub get_userid
{
    &nodb;
    my $user = shift;

    $user = LJ::canonical_username($user);

    if ($LJ::CACHE_USERID{$user}) { return $LJ::CACHE_USERID{$user}; }

    my $userid = LJ::MemCache::get("uidof:$user");
    return $LJ::CACHE_USERID{$user} = $userid if $userid;

    my $dbr = LJ::get_db_reader();
    $userid = $dbr->selectrow_array("SELECT userid FROM useridmap WHERE user=?", undef, $user);

    # implictly create an account if we're using an external
    # auth mechanism
    if (! $userid && ref $LJ::AUTH_EXISTS eq "CODE")
    {
        $userid = LJ::create_account({ 'user' => $user,
                                       'name' => $user,
                                       'password' => '', });
    }

    if ($userid) {
        $LJ::CACHE_USERID{$user} = $userid;
        LJ::MemCache::set("uidof:$user", $userid);
    }

    return ($userid+0);
}

# <LJFUNC>
# name: LJ::want_userid
# des: Returns userid when passed either userid or the user hash. Useful to functions that
#      want to accept either. Forces its return value to be a number (for safety).
# args: userid
# des-userid: Either a userid, or a user hash with the userid in its 'userid' key.
# returns: The userid, guaranteed to be a numeric value.
# </LJFUNC>
sub want_userid
{
    my $uuserid = shift;
    return ($uuserid->{'userid'} + 0) if ref $uuserid;
    return ($uuserid + 0);
}

# <LJFUNC>
# name: LJ::want_user
# des: Returns user object when passed either userid or user object. Useful to functions that
#      want to accept either.
# args: user
# des-user: Either a userid or a user hash with the userid in its 'userid' key.
# returns: The user object represented by said userid or username.
# </LJFUNC>
sub want_user
{
    my $uuid = shift;
    return undef unless $uuid;
    return $uuid if ref $uuid;
    return LJ::load_userid($uuid) if $uuid =~ /^\d+$/;
    Carp::croak("Bogus caller of LJ::want_user with non-ref/non-numeric parameter");
}

# <LJFUNC>
# name: LJ::get_username
# des: Returns a username given a userid.
# info: Results cached in memory.  On miss, does DB call.  Not advised
#       to use this many times in a row... only once or twice perhaps
#       per request.  Tons of serialized db requests, even when small,
#       are slow.  Opposite of [func[LJ::get_userid]].
# args: dbarg?, user
# des-user: Username whose userid to look up.
# returns: Userid, or 0 if invalid user.
# </LJFUNC>
sub get_username
{
    &nodb;
    my $userid = shift;
    $userid += 0;

    # Checked the cache first.
    if ($LJ::CACHE_USERNAME{$userid}) { return $LJ::CACHE_USERNAME{$userid}; }

    # if we're using memcache, it's faster to just query memcache for
    # an entire $u object and just return the username.  otherwise, we'll
    # go ahead and query useridmap
    if (@LJ::MEMCACHE_SERVERS) {
        my $u = LJ::load_userid($userid);
        return undef unless $u;

        $LJ::CACHE_USERNAME{$userid} = $u->{'user'};
        return $u->{'user'};
    }

    my $dbr = LJ::get_db_reader();
    my $user = $dbr->selectrow_array("SELECT user FROM useridmap WHERE userid=?", undef, $userid);

    # Fall back to master if it doesn't exist.
    unless (defined $user) {
        my $dbh = LJ::get_db_writer();
        $user = $dbh->selectrow_array("SELECT user FROM useridmap WHERE userid=?", undef, $userid);
    }

    return undef unless defined $user;

    $LJ::CACHE_USERNAME{$userid} = $user;
    return $user;
}

# <LJFUNC>
# name: LJ::can_manage
# des: Given a user and a target user, will determine if the first user is an
#      admin for the target user.
# returns: bool: true if authorized, otherwise fail
# args: remote, u
# des-remote: user object or userid of user to try and authenticate
# des-u: user object or userid of target user
# </LJFUNC>
sub can_manage {
    my $remote = LJ::want_user(shift);
    my $u = LJ::want_user(shift);
    return undef unless $remote && $u;

    # is same user?
    return 1 if LJ::u_equals($u, $remote);

    # people/syn/rename accounts can only be managed by the one account
    return undef if $u->{journaltype} =~ /^[PYR]$/;

    # check for admin access
    return undef unless LJ::check_rel($u, $remote, 'A');

    # passed checks, return true
    return 1;
}

# <LJFUNC>
# name: LJ::can_manage_other
# des: Given a user and a target user, will determine if the first user is an
#      admin for the target user, but not if the two are the same.
# returns: bool: true if authorized, otherwise fail
# args: remote, u
# des-remote: user object or userid of user to try and authenticate
# des-u: user object or userid of target user
# </LJFUNC>
sub can_manage_other {
    my ($remote, $u) = @_;
    return 0 if LJ::want_userid($remote) == LJ::want_userid($u);
    return LJ::can_manage($remote, $u);
}

sub can_delete_journal_item {
    return LJ::can_manage(@_);
}


# <LJFUNC>
# name: LJ::get_remote
# des: authenticates the user at the remote end based on their cookies
#      and returns a hashref representing them
# returns: hashref containing 'user' and 'userid' if valid user, else
#          undef.
# args: opts?
# des-opts: 'criterr': scalar ref to set critical error flag.  if set, caller
#           should stop processing whatever it's doing and complain
#           about an invalid login with a link to the logout page..
#           'ignore_ip': ignore IP address of remote for IP-bound sessions
# </LJFUNC>
sub get_remote
{
    my $opts = ref $_[0] eq "HASH" ? shift : {};
    return $LJ::CACHE_REMOTE if $LJ::CACHED_REMOTE && ! $opts->{'ignore_ip'};

    my $no_remote = sub {
        LJ::User->set_remote(undef);
        return undef;
    };

    # can't have a remote user outside of web context
    my $r = eval { Apache->request; };
    return $no_remote->() unless $r;

    my $criterr = $opts->{criterr} || do { my $d; \$d; };
    $$criterr = 0;

    $LJ::CACHE_REMOTE_BOUNCE_URL = "";

    # set this flag if any of their ljsession cookies contained the ".FS"
    # opt to use the fast server.  if we later find they're not logged
    # in and set it, or set it with a free account, then we give them
    # the invalid cookies error.
    my $tried_fast = 0;
    my $sessobj = LJ::Session->session_from_cookies(tried_fast   => \$tried_fast,
                                                    redirect_ref => \$LJ::CACHE_REMOTE_BOUNCE_URL,
                                                    ignore_ip    => $opts->{ignore_ip},
                                                    );

    my $u = $sessobj ? $sessobj->owner : undef;

    # inform the caller that this user is faking their fast-server cookie
    # attribute.
    if ($tried_fast && ! LJ::get_cap($u, "fastserver")) {
        $$criterr = 1;
    }

    return $no_remote->() unless $sessobj;

    # renew soon-to-expire sessions
    $sessobj->try_renew;

    # augment hash with session data;
    $u->{'_session'} = $sessobj;

    # keep track of activity for the user we just loaded from db/memcache
    # - if necessary, this code will actually run in Apache's cleanup handler
    #   so latency won't affect the user
    if (@LJ::MEMCACHE_SERVERS && ! $LJ::DISABLED{active_user_tracking}) {
        push @LJ::CLEANUP_HANDLERS, sub { $u->note_activity('A') };
    }

    LJ::User->set_remote($u);
    $r->notes("ljuser" => $u->{'user'});
    return $u;
}

# returns URL we have to bounce the remote user to in order to
# get their domain cookie
sub remote_bounce_url {
    return $LJ::CACHE_REMOTE_BOUNCE_URL;
}

sub set_remote {
    my $remote = shift;
    LJ::User->set_remote($remote);
    1;
}

sub unset_remote
{
    LJ::User->unset_remote;
    1;
}

sub get_active_journal
{
    return $LJ::ACTIVE_JOURNAL;
}

sub set_active_journal
{
    $LJ::ACTIVE_JOURNAL = shift;
}

# Checks if they are flagged as having a bad password and redirects
# to changepassword.bml.  If returl is on it returns the URL to
# redirect to vs doing the redirect itself.  Useful in non-BML context
# and for QuickReply links
sub bad_password_redirect {
    my $opts = shift;

    my $remote = LJ::get_remote();
    return undef unless $remote;

    return undef if $LJ::DISABLED{'force_pass_change'};

    return undef unless $remote->prop('badpassword');

    my $redir = "$LJ::SITEROOT/changepassword.bml";
    unless (defined $opts->{'returl'}) {
        return BML::redirect($redir);
    } else {
        return $redir;
    }
}

# Returns HTML to display user search results
# Args: %args
# des-args:
#           users    => hash ref of userid => u object like LJ::load userids
#                       returns or array ref of user objects
#           userids  => array ref of userids to include in results, ignored
#                       if users is defined
#           timesort => set to 1 to sort by last updated instead
#                       of username
#           perpage  => Enable pagination and how many users to display on
#                       each page
#           curpage  => What page of results to display
#           navbar   => Scalar reference for paging bar
#           pickwd   => userpic keyword to display instead of default if it
#                       exists for the user
sub user_search_display {
    my %args = @_;

    my $loaded_users;
    unless (defined $args{users}) {
        $loaded_users = LJ::load_userids(@{$args{userids}});
    } else {
        if (ref $args{users} eq 'HASH') { # Assume this is direct from LJ::load_userids
            $loaded_users = $args{users};
        } elsif (ref $args{users} eq 'ARRAY') { # They did a grep on it or something
            foreach (@{$args{users}}) {
                $loaded_users->{$_->{userid}} = $_;
            }
        } else {
            return undef;
        }
    }

    # If we're sorting by last updated, we need to load that
    # info for all users before the sort.  If sorting by
    # username we can load it for a subset of users later,
    # if paginating.
    my $updated;
    my @display;

    if ($args{timesort}) {
        $updated = LJ::get_timeupdate_multi(keys %$loaded_users);
        @display = sort { $updated->{$b->{userid}} <=> $updated->{$a->{userid}} } values %$loaded_users;
    } else {
        @display = sort { $a->{user} cmp $b->{user} } values %$loaded_users;
    }

    if (defined $args{perpage}) {
        my %items = BML::paging(\@display, $args{curpage}, $args{perpage});

        # Fancy paging bar
        ${$args{navbar}} = LJ::paging_bar($items{'page'}, $items{'pages'});

        # Now pull out the set of users to display
        @display = @{$items{'items'}};
    }

    # If we aren't sorting by time updated, load last updated time for the
    # set of users we are displaying.
    $updated = LJ::get_timeupdate_multi(map { $_->{userid} } @display)
        unless $args{timesort};

    # Allow caller to specify a custom userpic to use instead
    # of the user's default all userpics
    my $get_picid = sub {
        my $u = shift;
        return $u->{'defaultpicid'} unless $args{'pickwd'};
        return LJ::get_picid_from_keyword($u, $args{'pickwd'});
    };

    my $ret;
    foreach my $u (@display) {
        # We should always have loaded user objects, but it seems
        # when the site is overloaded we don't always load the users
        # we request.
        next unless LJ::isu($u);

        $ret .= "<div style='width: 300px; height: 105px; overflow: hidden; float: left; ";
        $ret .= "border-bottom: 1px solid <?altcolor2?>; margin-bottom: 10px; padding-bottom: 5px; margin-right: 10px'>";
        $ret .= "<table style='height: 105px'><tr>";

        if (my $picid = $get_picid->($u)) {
            $ret .= "<td style='width: 100px; text-align: center;'>";
            $ret .= "<a href='/allpics.bml?user=$u->{user}'>";
            $ret .= "<img src='$LJ::USERPIC_ROOT/$picid/$u->{userid}' alt='$u->{user} userpic' style='border: 1px solid #000;' /></a>";
            } else {
                $ret .= "<td style='width: 100px;'>";
                $ret .= "<img src='$LJ::IMGPREFIX/userpic_holder.gif' alt='no default userpic' style='border: 1px solid #000;' width='100' height='100' /></a>";
            }

        $ret .= "</td><td style='padding-left: 5px;' valign='top'><table>";

        $ret .= "<tr><td colspan='2' style='text-align: left;'>";
        $ret .= LJ::ljuser($u);
        $ret .= "</td></tr><tr>";

        if ($u->{name}) {
            $ret .= "<td width='1%' style='font-size: smaller' valign='top'>Name:</td><td style='font-size: smaller'><a href='$LJ::SITEROOT/userinfo.bml?user=$u->{user}'>";
            $ret .= LJ::ehtml($u->{name});
            $ret .= "</a>";
            $ret .= "</td></tr><tr>";
        }

        if (my $jtitle = $u->prop('journaltitle')) {
            $ret .= "<td width='1%' style='font-size: smaller' valign='top'>Journal:</td><td style='font-size: smaller'><a href='" . $u->journal_base . "'>";
            $ret .= LJ::ehtml($jtitle) . "</a>";
            $ret .= "</td></tr>";
        }

        $ret .= "<tr><td colspan='2' style='text-align: left; font-size: smaller'>";

        if ($updated->{$u->{'userid'}} > 0) {
            $ret .= "Updated ";
            $ret .= LJ::ago_text(time() - $updated->{$u->{'userid'}});
        } else {
            $ret .= "Never updated";
        }

        $ret .= "</td></tr>";

        $ret .= "</table>";
        $ret .= "</td></tr>";
        $ret .= "</table></div>";
    }

    return $ret;
}

1;


