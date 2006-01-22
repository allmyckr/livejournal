package LJ::Session;
use strict;
use Carp qw(croak);
use Digest::HMAC_SHA1 qw(hmac_sha1 hmac_sha1_hex);

use constant VERSION => 1;

# NOTES
#
# * fields in this object:
#     userid, sessid, exptype, auth, timecreate, timeexpire, ipfixed
#
# * do not store any references in the LJ::Session instances because of serialization
#   and storage in memcache
#
# * a user makes a session(s).  cookies aren't sessions.  cookies are handles into
#   sessions, and there can be lots of cookies to get the same session.
#
# * this file is a mix of instance, class, and util functions/methods
#

############################################################################
#  CREATE/LOAD SESSIONS OBJECTS
############################################################################

sub instance {
    my ($class, $u, $sessid) = @_;

    # try memory
    my $memkey = _memkey($u, $sessid);
    my $sess = LJ::MemCache::get($memkey);
    return $sess if $sess;

    # try master
    $sess = $u->selectrow_hashref("SELECT userid, sessid, exptype, auth, timecreate, timeexpire, ipfixed " .
                                  "FROM sessions WHERE userid=? AND sessid=?",
                                  undef, $u->{'userid'}, $sessid)
        or return undef;

    bless $sess;
    LJ::MemCache::set($memkey, $sess);
    return $sess;
}

sub create {
    my ($class, $u, %opts) = @_;

    # validate options
    my $exptype = delete $opts{'exptype'} || "short";
    my $ipfixed = delete $opts{'ipfixed'};   # undef or scalar ipaddress  FIXME: validate
    croak("Invalid exptype") unless $exptype =~ /^short|long|once$/;

    croak("Invalid options: " . join(", ", keys %opts)) if %opts;

    my $udbh = LJ::get_cluster_master($u);
    return undef unless $udbh;

    # clean up any old, expired sessions they might have (lazy clean)
    $u->do("DELETE FROM sessions WHERE userid=? AND timeexpire < UNIX_TIMESTAMP()",
           undef, $u->{userid});

    my $expsec     = LJ::Session->session_length($exptype);
    my $timeexpire = time() + $expsec;

    my $sess = {
        auth       => LJ::rand_chars(10),
        exptype    => $exptype,
        ipfixed    => $ipfixed,
        timeexpire => $timeexpire,
    };

    my $id = LJ::alloc_user_counter($u, 'S');
    return undef unless $id;

    $u->do("REPLACE INTO sessions (userid, sessid, auth, exptype, ".
           "timecreate, timeexpire, ipfixed) VALUES (?,?,?,?,UNIX_TIMESTAMP(),".
           "?,?)", undef,
           $u->{'userid'}, $id, $sess->{'auth'}, $exptype, $timeexpire, $ipfixed);

    return undef if $u->err;
    $sess->{'sessid'} = $id;
    $sess->{'userid'} = $u->{'userid'};

    # clean up old sessions
    my $old = $udbh->selectcol_arrayref("SELECT sessid FROM sessions WHERE ".
                                        "userid=$u->{'userid'} AND ".
                                        "timeexpire < UNIX_TIMESTAMP()");
    $u->kill_sessions(@$old) if $old;

    # mark account as being used
    LJ::mark_user_active($u, 'login');

    return bless $sess;

}

############################################################################
#  INSTANCE METHODS
############################################################################


# not stored in database, call this before calling to update cookie strings
sub set_flags {
    my ($sess, $flags) = @_;
    $sess->{flags} = $flags;
    return;
}

sub flags {
    my $sess = shift;
    return $sess->{flags};
}

sub set_ipfixed {
    my ($sess, $ip) = @_;
    return $sess->_dbupdate(ipfixed => $ip);
}

sub set_exptype {
    my ($sess, $exptype) = @_;
    croak("Invalid exptype") unless $exptype =~ /^short|long|once$/;
    return $sess->_dbupdate(exptype => $exptype,
                            timeexpire => time() + LJ::Session->session_length($exptype));
}


sub _dbupdate {
    my ($sess, %changes) = @_;
    my $u = $sess->owner;

    my $n_userid = $sess->{userid} + 0;
    my $n_sessid = $sess->{sessid} + 0;

    my @sets;
    my @values;
    foreach my $k (keys %changes) {
        push @sets, "$k=?";
        push @values, $changes{$k};
    }

    my $rv = $u->do("UPDATE sessions SET " . join(", ", @sets) .
                    " WHERE userid=$n_userid AND sessid=$n_sessid",
                    undef, @values);
    if (!$rv) {
        # FIXME: eventually use Error::Strict here on return
        return 0;
    }

    # update ourself, once db update succeeded
    foreach my $k (keys %changes) {
        $sess->{$k} = $changes{$k};
    }

    LJ::MemCache::delete($sess->_memkey);
    return 1;

}

# returns unix timestamp of expiration
sub expiration_time {
    my $sess = shift;

    # expiration time if we have it,
    return $sess->{timeexpire} if $sess->{timeexpire};

    warn "Had no 'timeexpire' for session.\n";
    return time() + LJ::Session->session_length($sess->{exptype});
}

# return format of the "ljloggedin" cookie.
sub loggedin_cookie_string {
    my ($sess) = @_;
    return "u$sess->{userid}:s$sess->{sessid}";
}


sub master_cookie_string {
    my $sess = shift;

    my $ver = VERSION;
    my $cookie = "v$ver:" .
        "u$sess->{userid}:" .
        "s$sess->{sessid}:" .
        "a$sess->{auth}";

    if ($sess->{flags}) {
        $cookie .= ":f$sess->{flags}";
    }

    $cookie .= "//" . LJ::eurl($LJ::COOKIE_GEN || "");
    return $cookie;
}

sub domsess_cookie_string {
    my ($sess, $domcook) = @_;
    croak("No domain cookie provided") unless $domcook;

    # compute a signed domain key
    my ($time, $key) = LJ::get_secret();
    my $sig = domsess_signature($time, $sess, $domcook);

    # the cookie
    my $ver = VERSION;
    my $value = "v$ver:" .
        "u$sess->{userid}:" .
        "s$sess->{sessid}:" .
        "t$time:" .
        "g$sig//" .
        ($LJ::COOKIE_GEN || "");

    return $value;
}

# sets new ljmastersession cookie given the session object
sub update_master_cookie {
    my ($sess) = @_;

    my @expires;
    if ($sess->{exptype} eq 'long') {
        push @expires, expires => $sess->expiration_time;
    }

    my $domain =
        $LJ::ONLY_USER_VHOSTS ? ($LJ::DOMAIN_WEB || $LJ::DOMAIN) : $LJ::DOMAIN;

    set_cookie(ljmastersession => $sess->master_cookie_string,
               domain          => $domain,
               path            => '/',
               http_only       => 1,
               @expires,);

    set_cookie(ljloggedin      => $sess->loggedin_cookie_string,
               domain          => $LJ::DOMAIN,
               path            => '/',
               http_only       => 1,
               @expires,);

    return;
}

sub auth {
    my $sess = shift;
    return $sess->{auth};
}

# NOTE: do not store any references in the LJ::Session instances because of serialization
# and storage in memcache
sub owner {
    my $sess = shift;
    return LJ::load_userid($sess->{userid});
}
# instance method:  has this session expired, or is it IP bound and
# bound to the wrong IP?
sub valid {
    my $sess = shift;
    my $now = time();
    my $err = sub { 0; };

    return $err->("Invalid auth") if $sess->{'timeexpire'} < $now;

    if ($sess->{'ipfixed'} && ! $LJ::Session::OPT_IGNORE_IP) {
        my $remote_ip = $LJ::_XFER_REMOTE_IP || LJ::get_remote_ip();
        return $err->("Session wrong IP ($remote_ip != $sess->{ipfixed})")
            if $sess->{'ipfixed'} ne $remote_ip;
    }

    return 1;
}

sub id {
    my $sess = shift;
    return $sess->{sessid};
}

sub ipfixed {
    my $sess = shift;
    return $sess->{ipfixed};
}

sub exptype {
    my $sess = shift;
    return $sess->{exptype};
}

# end a session
sub destroy {
    my $sess = shift;
    my $id = $sess->id;
    my $u = $sess->owner;
    return LJ::Session->destroy_sessions($u, $id);
}


# based on our type and current expiration length, update this cookie if we need to
sub try_renew {
    my ($sess, $cookies) = @_;

    # only renew long type cookies
    return if $sess->{exptype} ne 'long';

    # how long to live for
    my $u = $sess->owner;
    my $sess_length = LJ::Session->session_length($sess->{exptype});
    my $now = time();
    my $new_expire  = $now + $sess_length;

    # if there is a new session length to be set and the user's db writer is available,
    # go ahead and set the new session expiration in the database. then only update the
    # cookies if the database operation is successful
    if ($sess_length && $sess->{'timeexpire'} - $now < $sess_length/2 &&
        $u->writer && $sess->_dbupdate(timexpire => $new_expire))
    {
        $sess->update_master_cookie;
    }
}


############################################################################
#  CLASS METHODS
############################################################################

# NOTE: internal function REQUIRES trusted input
sub helper_url {
    my ($class, $domcook) = @_;
    return unless $domcook;

    my @parts = split(/\./, $domcook);
    my $url = "http://$parts[1].$LJ::USER_DOMAIN/";
    $url .= "$parts[2]/" if @parts == 3;
    $url .= "__setdomsess";
    return $url;
}

# given a URL, what domain cookie represents this URL?
# return undef if not URL for a domain cookie, which means either bogus URL
# or the master cookies should be tried.
sub domain_cookie {
    my ($class, $url) = @_;

    return undef unless
        $url =~ m!^http://(.+?)(/.*)$!;

    my ($host, $path) = ($1, $2);
    $host = lc($host);

    # don't return a domain cookie for the master domain
    return undef if $host eq lc($LJ::DOMAIN_WEB) || $host eq lc($LJ::DOMAIN);

    return undef unless
        $host =~ m!^(\w{1,50})\.\Q$LJ::USER_DOMAIN\E$!;

    my $subdomain = lc($1);
    if ($LJ::SUBDOMAIN_FUNCTION{$subdomain} eq "journal") {
        return undef unless $path =~ m!^/(\w{1,15})\b!;
        my $user = lc($1);
        return "ljdomsess.$subdomain.$user";
    }

    # where $subdomain is actually a username:
    return "ljdomsess.$subdomain";
}

# CLASS METHOD
#  -- frontend to session_from_domain_cookie and session_from_master_cookie below
sub session_from_cookies {
    my $class = shift;
    my %getopts = @_;

    # must be in web context
    return undef unless eval { Apache->request; };

    my $sessobj;

    my $domain_cookie = LJ::Session->domain_cookie(_current_url());
    if ($domain_cookie) {
        # journal domain
        $sessobj = LJ::Session->session_from_domain_cookie(\%getopts, @{ $BML::COOKIE{"$domain_cookie\[\]"} || [] });
    } else {
        # this is the master cookie at "www.livejournal.com" or "livejournal.com";
        $sessobj = LJ::Session->session_from_master_cookie(\%getopts, @{ $BML::COOKIE{'ljmastersession[]'} || [] });
    }

    return $sessobj;
}

# CLASS METHOD
#   -- but not called directly.  usually called by LJ::Session->session_from_cookies above
sub session_from_domain_cookie {
    my $class = shift;
    my $opts = ref $_[0] ? shift() : {};

    warn "session_from_domain_cookie()\n";

    # the logged-in cookie
    my $li_cook = $BML::COOKIE{'ljloggedin'};
    return undef unless $li_cook;

    warn "   li_cook = $li_cook\n";

    my $no_session = sub {
        my $reason = shift;
        my $rr = $opts->{redirect_ref};
        if ($rr) {
            $$rr = "$LJ::SITEROOT/misc/get_domain_session.bml?return=" . LJ::eurl(_current_url());
            warn "   need_bounce to: $$rr\n";
        }
        return undef;
    };

    my @cookies = grep { $_ } @_;
    return $no_session->("no cookies") unless @cookies;

    my $cur_url = _current_url();
    my $domcook = LJ::Session->domain_cookie($cur_url);

    warn "   domaincook: $domcook (for $cur_url)\n";

    foreach my $cookie (@cookies) {
        my $sess = valid_domain_cookie($domcook, $cookie, $li_cook);
        warn "for url=$cur_url, domcook=$domcook, sess=$sess\n";
        next unless $sess;
        return $sess;
    }

    return $no_session->("no valid cookie");
}

# CLASS METHOD
#   -- but not called directly.  usually called by LJ::Session->session_from_cookies above
# call: ( $opts?, @ljmastersession_cookie(s) )
# return value is LJ::Session object if we found one; else undef
# FIXME: document ops
sub session_from_master_cookie {
    my $class = shift;
    my $opts = ref $_[0] ? shift() : {};
    my @cookies = grep { $_ } @_;
    return undef unless @cookies;

    my $errs       = delete $opts->{errlist} || [];
    my $tried_fast = delete $opts->{tried_fast} || do { my $foo; \$foo; };
    my $ignore_ip  = delete $opts->{ignore_ip} ? 1 : 0;

    delete $opts->{'redirect_ref'};  # we don't use this
    croak("Unknown options") if %$opts;

    my $now = time();

    # our return value
    my $sess;

  COOKIE:
    foreach my $sessdata (@cookies) {
        warn "master cookie: = $sessdata\n";
        my ($cookie, $gen) = split(m!//!, $sessdata);

        my ($version, $userid, $sessid, $auth, $flags);

        my $dest = {
            v => \$version,
            u => \$userid,
            s => \$sessid,
            a => \$auth,
            f => \$flags,
        };

        my $bogus = 0;
        foreach my $var (split /:/, $cookie) {
            if ($var =~ /^(\w)(.+)$/ && $dest->{$1}) {
                ${$dest->{$1}} = $2;
            } else {
                $bogus = 1;
            }
        }

        # must do this first so they can't trick us
        $$tried_fast = 1 if $flags =~ /\.FS\b/;

        next COOKIE if $bogus;

        next COOKIE unless $gen eq $LJ::COOKIE_GEN;

        my $err = sub {
            warn "  ERROR due to: $_[0]";
            $sess = undef;
            push @$errs, "$sessdata: $_[0]";
        };

        # fail unless version matches current
        unless ($version == VERSION) {
            $err->("no ws auth");
            next COOKIE;
        }

        my $u = LJ::load_userid($userid);
        unless ($u) {
            $err->("user doesn't exist");
            next COOKIE;
        }

        # locked accounts can't be logged in
        if ($u->{statusvis} eq 'L') {
            $err->("User account is locked.");
            next COOKIE;
        }

        $sess = LJ::Session->instance($u, $sessid);

        unless ($sess) {
            $err->("Couldn't find session");
            next COOKIE;
        }

        unless ($sess->{auth} eq $auth) {
            $err->("Invald auth");
            next COOKIE;
        }

        unless ($sess->valid) {
            $err->("expired or IP bound problems");
            next COOKIE;
        }

        last COOKIE;
    }

    return $sess;
}

# class method
sub destroy_all_sessions {
    my ($class, $u) = @_;
    return 0 unless $u;

    my $udbh = LJ::get_cluster_master($u)
        or return 0;

    my $sessions = $udbh->selectcol_arrayref("SELECT sessid FROM sessions WHERE ".
                                             "userid=?", undef, $u->{'userid'});

    return LJ::Session->destroy_sessions($u, @$sessions) if @$sessions;
    return 1;
}

# class method
sub destroy_sessions {
    my ($class, $u, @sessids) = @_;

    my $in = join(',', map { $_+0 } @sessids);
    return 1 unless $in;
    my $userid = $u->{'userid'};
    foreach (qw(sessions sessions_data)) {
        $u->do("DELETE FROM $_ WHERE userid=? AND ".
               "sessid IN ($in)", undef, $userid)
            or return 0;   # FIXME: use Error::Strict
    }
    foreach my $id (@sessids) {
        $id += 0;
        LJ::MemCache::delete(_memkey($u, $id));
    }
    return 1;

}

sub clear_master_cookie {
    my ($class) = @_;

    my $domain =
        $LJ::ONLY_USER_VHOSTS ? ($LJ::DOMAIN_WEB || $LJ::DOMAIN) : $LJ::DOMAIN;

    set_cookie(ljmastersession => "",
               domain          => $domain,
               path            => '/',
               delete          => 1);

    set_cookie(ljloggedin      => "",
               domain          => $LJ::DOMAIN,
               path            => '/',
               delete          => 1);

}


# CLASS method for getting the length of a given session type in seconds
sub session_length {
    my ($class, $exptype) = @_;
    croak("Invalid exptype") unless $exptype =~ /^short|long|once$/;

    return {
        short => 60*60*24*1.5, # 1.5 days
        long  => 60*60*24*60,  # 60 days
        once  => 60*60*2,      # 2 hours
    }->{$exptype};
}

# given an Apache $r object, returns the URL to go to after setting the domain cookie
sub setdomsess_handler {
    my ($class, $r) = @_;
    my %get = $r->args;

    my $dest    = $get{'dest'};
    my $domcook = $get{'k'};
    my $cookie  = $get{'v'};

    warn "setdomsess handler!\n";

    my $is_valid = valid_destination($dest);
    warn "  valid dest = $is_valid\n";
    return "$LJ::SITEROOT" unless $is_valid;

    $is_valid = valid_domain_cookie($domcook, $cookie, $BML::COOKIE{'ljloggedin'});
    warn "  valid dom cookie = $is_valid\n";
    return $dest           unless $is_valid;

    set_cookie($domcook   => $cookie,
               path       => path_of_domcook($domcook),
               http_only  => 1,
               expires    => 60*60);

    return $dest;
}


############################################################################
#  UTIL FUNCTIONS
############################################################################

sub _current_url {
    my $r = Apache->request;
    my $args = $r->args;
    my $args_wq = $args ? "?$args" : "";
    my $host = $r->header_in("Host");
    my $uri = $r->uri;
    return "http://$host$uri$args_wq";
}

sub domsess_signature {
    my ($time, $sess, $domcook) = @_;

    my $u      = $sess->owner;
    my $secret = LJ::get_secret($time);

    my $data = join("-", $sess->{auth}, $domcook, $u->{userid}, $sess->{sessid}, $time);
    my $sig  = hmac_sha1_hex($data, $secret);
    return $sig;
}

# function or instance method.
# FIXME: update the documentation for memkeys
sub _memkey {
    if (@_ == 2) {
        my ($u, $sessid) = @_;
        $sessid += 0;
        return [$u->{'userid'}, "ljms:$u->{'userid'}:$sessid"];
    } else {
        my $sess = shift;
        return [$sess->{'userid'}, "ljms:$sess->{'userid'}:$sess->{sessid}"];
    }
}

# FIXME: move this somewhere better
sub set_cookie {
    my ($key, $value, %opts) = @_;

    my $r = eval { Apache->request };
    croak("Can't set cookie in non-web context") unless $r;

    my $http_only = delete $opts{http_only};
    my $domain = delete $opts{domain};
    my $path = delete $opts{path};
    my $expires = delete $opts{expires};
    my $delete = delete $opts{delete};
    croak("Invalid cookie options: " . join(", ", keys %opts)) if %opts;

    # expires can be absolute or relative.  this is gross or clever, your pick.
    $expires += time() if $expires && $expires <= 1135217120;

    if ($delete) {
        # set expires to 5 seconds after 1970.  definitely in the past.
        # so cookie will be deleted.
        $expires = 5 if $delete;
    }

    my $cookiestr = $key . '=' . $value;
    $cookiestr .= '; expires=' . LJ::time_to_cookie($expires) if $expires;
    $cookiestr .= '; domain=' . $domain if $domain;
    $cookiestr .= '; path=' . $path if $path;
    $cookiestr .= '; HttpOnly' if $http_only;

    warn "SETTING-COOKIE: $cookiestr\n";
    $r->err_headers_out->add('Set-Cookie' => $cookiestr);
}

# returns undef or a session, given a $domcook and its $val, as well
# as the current logged-in cookie $li_cook which says the master
# session's uid/sessid
sub valid_domain_cookie {
    my ($domcook, $val, $li_cook) = @_;

    my ($cookie, $gen) = split m!//!, $val;

    my ($version, $uid, $sessid, $time, $sig, $flags);
    my $dest = {
        v => \$version,
        u => \$uid,
        s => \$sessid,
        t => \$time,
        g => \$sig,
        f => \$flags,
    };

    my $bogus = 0;
    foreach my $var (split /:/, $cookie) {
        if ($var =~ /^(\w)(.+)$/ && $dest->{$1}) {
            ${$dest->{$1}} = $2;
        } else {
            $bogus = 1;
        }
    }

    my $not_valid = sub {
        my $reason = shift;
        warn "  valid_domain_cookie = 0, because: $reason\n";
        return undef;
    };

    return $not_valid->("bogus params") if $bogus;
    return $not_valid->("wrong gen") if $gen ne $LJ::COOKIE_GEN;
    return $not_valid->("wrong ver") if $version != VERSION;

    # have to be relatively new.  these shouldn't last longer than a day
    # or so anyway.
    my $now = time();
    return $not_valid->("old cookie") unless $time > $now - 86400*7;;

    my $u = LJ::load_userid($uid)
        or return $not_valid->("no user $uid");

    my $sess = $u->session($sessid)
        or return $not_valid->("no session $sessid");

    # the master session can't be expired or ip-bound to wrong IP
    return $not_valid->("not valid") unless $sess->valid;

    # the per-domain cookie has to match the session of the master cookie
    my $sess_licook = $sess->loggedin_cookie_string;
    return $not_valid->("li_cook mismatch.  session=$sess_licook, user=$li_cook")
        unless $sess_licook eq $li_cook;

    my $correct_sig = domsess_signature($time, $sess, $domcook);
    return $not_valid->("signature wrong") unless $correct_sig eq $sig;

    return $sess;
}

sub valid_destination {
    my $dest = shift;
    my $rx = valid_dest_rx();
    return $dest =~ /$rx/;
}

sub valid_dest_rx {
    return qr!^http://\w+\.\Q$LJ::USER_DOMAIN\E/.*!;
}

sub path_of_domcook {
    my $domcook = shift;
    # if domcookie is 3 parts (ljdomsess.community.knitting), then restrict
    # path of the cookie to /knitting/.  by default path is /
    my @parts = split(/\./, $domcook);
    my $path = "/";
    if (@parts == 3) {
        $path = "/" . $parts[-1] . "/";
    }
    return $path;
}

1;
