package LJ;
use strict;

sub class_bit {
    my ($class) = @_;
    foreach my $bit (0..65) {
        my $def = $LJ::CAP{$bit};
        next unless $def->{_key} && $def->{_key} eq $class;
        return $bit;
    }
    return undef;
}

# what class name does a given bit number represent?
sub class_of_bit {
    my $bit = shift;
    return $LJ::CAP{$bit}->{_key};
}

sub classes_from_mask {
    my $caps = shift;

    my @classes = ();
    foreach my $bit (0..15) {
        my $class = LJ::class_of_bit($bit);
        next unless $class && LJ::caps_in_group($caps, $class);
        push @classes, $class;
    }

    return @classes;
}

sub mask_from_classes {
    my @classes = @_;

    my $mask = 0;
    foreach my $class (@classes) {
        my $bit = LJ::class_bit($class);
        $mask |= (1 << $bit);
    }

    return $mask;
}

sub mask_from_bits {
    my @bits = @_;

    my $mask = 0;
    foreach my $bit (@bits) {
        $mask |= (1 << $bit);
    }

    return $mask;
}

sub caps_in_group {
    my ($caps, $class) = @_;
    my $bit = LJ::class_bit($class);
    unless (defined $bit) {
        # this site has no underage class?  'underage' is the only
        # general class.
        return 0 if $class eq "underage";

        # all other classes are site-defined, so we die on those not existing.
        die "unknown class '$class'";
    }

    return ($caps+0 & (1 << $bit)) ? 1 : 0;
}

# <LJFUNC>
# name: LJ::name_caps
# des: Given a user's capability class bit mask, returns a
#      site-specific string representing the capability class name.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps
{
    return undef unless LJ::are_hooks("name_caps");
    my $caps = shift;
    return LJ::run_hook("name_caps", $caps);
}

# <LJFUNC>
# name: LJ::name_caps_short
# des: Given a user's capability class bit mask, returns a
#      site-specific short string code.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub name_caps_short
{
    return undef unless LJ::are_hooks("name_caps_short");
    my $caps = shift;
    return LJ::run_hook("name_caps_short", $caps);
}

# <LJFUNC>
# name: LJ::user_caps_icon
# des: Given a user's capability class bit mask, returns
#      site-specific HTML with the capability class icon.
# args: caps
# des-caps: 16 bit capability bitmask
# </LJFUNC>
sub user_caps_icon
{
    return undef unless LJ::are_hooks("user_caps_icon");
    my $caps = shift;
    return LJ::run_hook("user_caps_icon", $caps);
}

# <LJFUNC>
# name: LJ::get_cap
# des: Given a user object, capability class key or capability class bit mask
#      and a capability/limit name,
#      returns the maximum value allowed for given user or class, considering
#      all the limits in each class the user is a part of.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in [special[caps]].
# </LJFUNC>
sub get_cap
{
    my $caps = shift;   # capability bitmask (16 bits), cap key or user object
    my $cname = shift;  # capability limit name
    my $opts  = shift;  # { no_hook => 1/0 }
    $opts ||= {};

    # If caps is a reference
    my $u = ref $caps ? $caps : undef;

    # If caps is a reference get caps from User object
    if ($u) {
        $caps = $u->{'caps'};
    # If it is not all digits assume it is a key
    } elsif ($caps && $caps !~ /^\d+$/) {
        $caps = 1 << LJ::class_bit($caps);
    }
    # The caps is the cap mask already or undef, force it to be a number
    $caps += 0;

    my $max = undef;

    # allow a way for admins to force-set the read-only cap
    # to lower writes on a cluster.
    if ($cname eq "readonly" && $u &&
        ($LJ::READONLY_CLUSTER{$u->{clusterid}} ||
         $LJ::READONLY_CLUSTER_ADVISORY{$u->{clusterid}} &&
         ! LJ::get_cap($u, "avoid_readonly"))) {

        # HACK for desperate moments.  in when_needed mode, see if
        # database is locky first
        my $cid = $u->{clusterid};
        if ($LJ::READONLY_CLUSTER_ADVISORY{$cid} eq "when_needed") {
            my $now = time();
            return 1 if $LJ::LOCKY_CACHE{$cid} > $now - 15;

            my $dbcm = LJ::get_cluster_master($u->{clusterid});
            return 1 unless $dbcm;
            my $sth = $dbcm->prepare("SHOW PROCESSLIST");
            $sth->execute;
            return 1 if $dbcm->err;
            my $busy = 0;
            my $too_busy = $LJ::WHEN_NEEDED_THRES || 300;
            while (my $r = $sth->fetchrow_hashref) {
                $busy++ if $r->{Command} ne "Sleep";
            }
            if ($busy > $too_busy) {
                $LJ::LOCKY_CACHE{$cid} = $now;
                return 1;
            }
        } else {
            return 1;
        }
    }

    # underage/coppa check etc
    if ($cname eq "underage" && $u && $u->in_class("underage")) {
        return 1;
    }

    # is there a hook for this cap name?
    if (! $opts->{no_hook} && LJ::are_hooks("check_cap_$cname")) {
        die "Hook 'check_cap_$cname' requires full user object"
            unless LJ::isu($u);
        my $val = LJ::run_hook("check_cap_$cname", $u, $opts);
        return $val if defined $val;

        # otherwise fall back to standard means
    }

    # otherwise check via other means
    foreach my $bit (keys %LJ::CAP) {
        next unless ($caps & (1 << $bit));
        my $v = $LJ::CAP{$bit}->{$cname};
        next unless (defined $v);
        next if (defined $max && $max > $v);
        $max = $v;
    }

    return defined $max ? $max : $LJ::CAP_DEF{$cname};
}

# <LJFUNC>
# name: LJ::get_cap_min
# des: Just like [func[LJ::get_cap]], but returns the minimum value.
#      Although it might not make sense at first, some things are
#      better when they're low, like the minimum amount of time
#      a user might have to wait between getting updates or being
#      allowed to refresh a page.
# args: u_cap, capname
# des-u_cap: 16 bit capability bitmask or a user object from which the
#            bitmask could be obtained
# des-capname: the name of a limit, defined in [special[caps]].
# </LJFUNC>
sub get_cap_min
{
    my $caps = shift;   # capability bitmask (16 bits), or user object
    my $cname = shift;  # capability name
    if (! defined $caps) { $caps = 0; }
    elsif (isu($caps)) { $caps = $caps->{'caps'}; }
    my $min = undef;
    foreach my $bit (keys %LJ::CAP) {
        next unless ($caps & (1 << $bit));
        my $v = $LJ::CAP{$bit}->{$cname};
        next unless (defined $v);
        next if (defined $min && $min < $v);
        $min = $v;
    }
    return defined $min ? $min : $LJ::CAP_DEF{$cname};
}

1;
