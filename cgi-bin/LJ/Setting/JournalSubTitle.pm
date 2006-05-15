package LJ::Setting::JournalSubTitle;
use base 'LJ::Setting::TextSetting';
use strict;
use warnings;

sub tags { qw(journal subtitle) }

sub prop_name { "journalsubtitle" }
sub text_size { 40 }
sub question { "Journal Subtitle &nbsp;" }

1;

