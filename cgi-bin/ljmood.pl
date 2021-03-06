package LJ;
use strict;

# <LJFUNC>
# name: LJ::load_mood_theme
# des: Loads and caches a mood theme, or returns immediately if already loaded.
# args: dbarg?, themeid
# des-themeid: the mood theme ID to load.
# </LJFUNC>
sub load_mood_theme
{
    &nodb;
    my $themeid = shift;
    return if $LJ::CACHE_MOOD_THEME{$themeid};
    return unless $themeid;

    # check memcache
    my $memkey = [$themeid, "moodthemedata:$themeid"];
    return if $LJ::CACHE_MOOD_THEME{$themeid} = LJ::MemCache::get($memkey) and
        %{$LJ::CACHE_MOOD_THEME{$themeid} || {}};

    # fall back to db
    my $dbh = LJ::get_db_writer()
        or return 0;

    $LJ::CACHE_MOOD_THEME{$themeid} = {};

    my $sth = $dbh->prepare("SELECT moodid, picurl, width, height FROM moodthemedata WHERE moodthemeid=?");
    $sth->execute($themeid);
    return 0 if $dbh->err;

    while (my ($id, $pic, $w, $h) = $sth->fetchrow_array) {
        $LJ::CACHE_MOOD_THEME{$themeid}->{$id} = { 'pic' => $pic, 'w' => $w, 'h' => $h };
    }

    my $des_sth = $dbh->prepare("SELECT name, des FROM moodthemes WHERE moodthemeid=?");
    $des_sth->execute($themeid);
    return 0 if $dbh->err;

    my ($name, $des) = $des_sth->fetchrow_array;
    $LJ::CACHE_MOOD_THEME{$themeid}->{name} = $name;
    $LJ::CACHE_MOOD_THEME{$themeid}->{des}  = $des;

    # set in memcache
    LJ::MemCache::set($memkey, $LJ::CACHE_MOOD_THEME{$themeid}, 3600)
        if %{$LJ::CACHE_MOOD_THEME{$themeid} || {}};

    return 1;
}

# <LJFUNC>
# name: LJ::load_moods
# class:
# des:
# info:
# args:
# des-:
# returns:
# </LJFUNC>
sub load_moods
{
    return if $LJ::CACHED_MOODS;
    my $dbr = LJ::get_db_reader();
    my $sth = $dbr->prepare("SELECT moodid, mood, parentmood FROM moods");
    $sth->execute;
    while (my ($id, $mood, $parent) = $sth->fetchrow_array) {
        $LJ::CACHE_MOODS{$id} = { 'name' => $mood, 'parent' => $parent, 'id' => $id };
        if ($id > $LJ::CACHED_MOOD_MAX) { $LJ::CACHED_MOOD_MAX = $id; }
    }
    $LJ::CACHED_MOODS = 1;
}

# <LJFUNC>
# name: LJ::get_mood_picture
# des: Loads a mood icon hashref given a themeid and moodid.
# args: themeid, moodid, ref
# des-themeid: Integer; mood themeid.
# des-moodid: Integer; mood id.
# des-ref: Hashref to load mood icon data into.
# returns: Boolean; 1 on success, 0 otherwise.
# </LJFUNC>
sub get_mood_picture
{
    my ($themeid, $moodid, $ref) = @_;
    LJ::load_mood_theme($themeid) unless $LJ::CACHE_MOOD_THEME{$themeid};
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    do
    {
        if ($LJ::CACHE_MOOD_THEME{$themeid} &&
            $LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}) {
            %{$ref} = %{$LJ::CACHE_MOOD_THEME{$themeid}->{$moodid}};
            if ($ref->{'pic'} =~ m!^/!) {
                $ref->{'pic'} =~ s!^/img!!;
                $ref->{'pic'} = $LJ::IMGPREFIX . $ref->{'pic'};
            }
            $ref->{'pic'} = "#invalid" unless
                $ref->{'pic'} =~ m!^https?://[^\'\"\0\s]+$!;
            $ref->{'moodid'} = $moodid;
            return 1;
        } else {
            $moodid = (defined $LJ::CACHE_MOODS{$moodid} ?
                       $LJ::CACHE_MOODS{$moodid}->{'parent'} : 0);
        }
    }
    while ($moodid);
    return 0;
}

sub mood_size_attributes {
    my %pic = @_;

    my @attrs;
    if ($pic{'w'} && $pic{'h'}) {
        push @attrs, "width='$pic{'w'}'";
        push @attrs, "height='$pic{'h'}'";
        push @attrs, qq{class="$pic{class}"} if $pic{'class'};
    } else {
        my @classes = qw(meta-mood-img);
        push @classes, $pic{'class'} if $pic{'class'};
        my $classes = join(' ', @classes);
        push @attrs, qq{class="$classes"};
    }

    return join(' ', @attrs);

}

# mood id to name (or undef)
sub mood_name
{
    my ($moodid) = @_;
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    my $m = $LJ::CACHE_MOODS{$moodid};
    return $m ? $m->{'name'} : undef;
}

# mood id to desc
sub mood_theme_des
{
    my ($themeid) = @_;
    LJ::load_mood_theme($themeid);
    my $m = $LJ::CACHE_MOOD_THEME{$themeid};
    return $m ? $m->{'des'} : undef;
}

# mood name to id (or undef)
sub mood_id
{
    my ($mood) = @_;
    return undef unless $mood;
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    foreach my $m (values %LJ::CACHE_MOODS) {
        return $m->{'id'} if $mood eq LJ::Lang::ml("mood.$m->{'name'}");
    }
    return undef;
}

sub get_moods
{
    LJ::load_moods() unless $LJ::CACHED_MOODS;
    return \%LJ::CACHE_MOODS;
}

1;
