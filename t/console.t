# -*-perl-*-

use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
use LJ::Console;
use LJ::Test qw (temp_user);

my $u = temp_user();
LJ::set_remote($u);

is(LJ::Console->run_commands_text("print one"),
   "info: Welcome to 'print'!
success: one
");

is(LJ::Console->run_commands_text("print one two !three"),
   "info: Welcome to 'print'!
success: one
success: two
error: !three
");
