package LJ::Event::CommunityJoinRequest;
use strict;
use Class::Autouse qw(LJ::Entry);
use Carp qw(croak);
use base 'LJ::Event';

sub new {
    my ($class, $u, $requestor, $comm) = @_;

    foreach ($u, $requestor, $comm) {
        LJ::errobj('Event::CommunityJoinRequest', u => $_)->throw unless LJ::isu($_);
    }

    # Shouldn't these be method calls? $requestor->id, etc.
    return $class->SUPER::new($u, $requestor->{userid}, $comm->{userid});
}

sub is_common { 0 }

sub comm {
    my $self = shift;
    return LJ::load_userid($self->arg2);
}

sub requestor {
    my $self = shift;
    return LJ::load_userid($self->arg1);
}

sub authurl {
    my $self = shift;

    # we need to force the authaction from the master db; otherwise, replication
    # delays could cause this to fail initially
    my $arg = "targetid=". $self->requestor->id;
    my $auth = LJ::get_authaction($self->comm->id, "comm_join_request", $arg, { force => 1 })
        or die "Unable to fetch authcode";

    return "$LJ::SITEROOT/approve/" . $auth->{aaid} . "." . $auth->{authcode};
}

sub as_html {
    my $self = shift;
    return sprintf("The user %s has <a href=\"$LJ::SITEROOT/community/pending.bml?authas=%s\">requested to join</a> the community %s.",
                   $self->requestor->ljuser_display, $self->comm->user,
                   $self->comm->ljuser_display);
}

sub as_html_actions {
    my ($self) = @_;

    my $ret .= "<div class='actions'>";
    $ret .= " <a href='" . $self->requestor->profile_url . "'>View Profile</a>";
    $ret .= " <a href='$LJ::SITEROOT/community/pending.bml?authas=" . $self->comm->user . "'>Manage Members</a>";
    $ret .= "</div>";

    return $ret;
}

sub content {
    my ($self, $target) = @_;

    return $self->as_html_actions;
}

sub as_string {
    my $self = shift;
    return sprintf("The user %s has requested to join the community %s.",
                   $self->requestor->display_username,
                   $self->comm->display_username);
}

my @_ml_strings_en = (
    'esn.community_join_requst.subject',    # '[[comm]] membership request by [[who]]!',
    'esn.approve_join_request',             # '[[openlink]]Approve [[username]]\'s request to join[[closelink]]',
    'esn.manage_membership_reqs',           # '[[openlink]]Manage [[communityname]]\'s membership requests[[closelink]]',
    'esn.manage_community',                 # '[[openlink]]Manage your communities[[closelink]]',
    'esn.community_join_requst.email_text', # 'Hi [[maintainer]],
                                            #
                                            #[[username]] has requested to join your community, [[communityname]].
                                            #
                                            #You can:',
);

sub as_email_subject {
    my ($self, $u) = @_;
    return LJ::Lang::get_text($u->prop('browselang'), 'esn.community_join_requst.subject', undef,
        {
            comm    => $self->comm->display_username,
            who     => $self->requestor->display_username,
        });
}

sub _as_email {
    my ($self, $u, $is_html) = @_;

    my $maintainer      = $is_html ? ($u->ljuser_display) : ($u->user);
    my $username        = $is_html ? ($self->requestor->ljuser_display) : ($self->requestor->user);
    my $user            = $self->requestor->user;
    my $communityname   = $self->comm->user;
    my $community       = $self->comm->ljuser_display;
    my $authurl         = $self->authurl;
    my $lang            = $u->prop('browselang');

    # Precache text
    LJ::Lang::get_text_multi($lang, undef, \@_ml_strings_en);
 
    my $vars = {
        maintainer      => $maintainer,
        username        => $username,
        communityname   => $communityname,
    };

    return LJ::Lang::get_text($lang, 'esn.community_join_requst.email_text', undef, $vars) .
        $self->format_options($is_html, $lang, $vars,
        {
            'esn.approve_join_request'    => [ 1, $authurl ],
            'esn.manage_membership_reqs'  => [ 2, "$LJ::SITEROOT/community/pending.bml?authas=$communityname" ],
            'esn.manage_community'        => [ 3, "$LJ::SITEROOT/community/manage.bml" ],
        }
    );
}

sub as_email_string {
    my ($self, $u) = @_;
    return _as_email($self, $u, 0);
}

sub as_email_html {
    my ($self, $u) = @_;
    return _as_email($self, $u, 1);
}

sub as_sms {
    my $self = shift;

    return sprintf("%s requests membership in %s. Visit community settings to approve.",
                   $self->requestor->display_username,
                   $self->comm->display_username);
}

sub subscription_as_html {
    my ($class, $subscr) = @_;
    return 'Someone requests membership in a community I maintain';
}

package LJ::Error::Event::CommunityJoinRequest;
sub fields { 'u' }
sub as_string {
    my $self = shift;
    return "LJ::Event::CommuinityJoinRequest passed bogus u object: $self->{u}";
}

1;
