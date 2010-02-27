package LJ::Event::CommunityEntryReply;
use strict;
use base 'LJ::Event::JournalNewComment';

sub subscription_as_html {
    my ($class, $subscr) = @_;
    
    return BML::ml('event.community_entry_reply');
}

sub available_for_user  { 1 }

sub is_subscription_visible_to { 1 }

sub is_tracking { 0 }

1;
