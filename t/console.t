# -*-perl-*-
use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
use LJ::Console;
use LJ::Test qw (temp_user temp_comm memcache_stress);

my $run = sub {
    my $cmd = shift;
    return LJ::Console->run_commands_text($cmd);
};

# check that it requires a login
is($run->("print one"), "error: You must be logged in to use the console.");
my $u = temp_user();
LJ::set_remote($u);


# ----------- ALLOWOPENPROXY FUNCTIONS -----------

is($run->("allow_open_proxy 127.0.0.1"), "error: You are not authorized to do this");
$u->grant_priv("allowopenproxy");
is($run->("allow_open_proxy 127.0.0.1"), "error: That IP address is not an open proxy.");
is($run->("allow_open_proxy 127001"), "error: That is an invalid IP address.");

my $dbh = LJ::get_db_writer();
$dbh->do("REPLACE INTO openproxy (addr, status, asof, src) VALUES (?,?,?,?)", undef,
         "127.0.0.1", "proxy", time(), "Marking as open proxy for test");
is(LJ::is_open_proxy("127.0.0.1"), 1, "Verified IP as open proxy.");
$dbh->do("REPLACE INTO openproxy (addr, status, asof, src) VALUES (?,?,?,?)", undef,
         "127.0.0.2", "proxy", time(), "Marking as open proxy for test");
is(LJ::is_open_proxy("127.0.0.2"), 1, "Verified IP as open proxy.");

is($run->("allow_open_proxy 127.0.0.1"), "success: 127.0.0.1 cleared as an open proxy for the next 24 hours");
is(LJ::is_open_proxy("127.0.0.1"), 0, "Verified IP has been cleared as open proxy.");

is($run->("allow_open_proxy 127.0.0.2 forever"), "success: 127.0.0.2 cleared as an open proxy forever");
is(LJ::is_open_proxy("127.0.0.2"), 0, "Verified IP has been cleared as open proxy.");

$dbh->do("DELETE FROM openproxy WHERE addr IN (?, ?)",
         undef, "127.0.0.1", "127.0.0.2");
$u->revoke_priv("allowopenproxy");



# ------------ BAN FUNCTIONS --------------
my $u2 = temp_user();
my $comm = temp_comm();

is($run->("ban_set " . $u2->user),
   "success: User " . $u2->user . " banned from " . $u->user);
is($run->("ban_set " . $u2->user . " from " . $comm->user),
   "error: You are not a maintainer of this account");

is(LJ::set_rel($comm, $u, 'A'), '1', "Set user as maintainer");
# obligatory hack until whitaker commits patch to clear $LJ::REQ_CACHE_REL
LJ::start_request();
LJ::set_remote($u);

is($run->("ban_set " . $u2->user . " from " . $comm->user),
   "success: User " . $u2->user . " banned from " . $comm->user);
is($run->("ban_list"),
   "info: " . $u2->user);
is($run->("ban_list from " . $comm->user),
   "info: " . $u2->user);
is($run->("ban_unset " . $u2->user),
   "success: User " . $u2->user . " unbanned from " . $u->user);
is($run->("ban_unset " . $u2->user . " from " . $comm->user),
   "success: User " . $u2->user . " unbanned from " . $comm->user);
is($run->("ban_list"),
   "info: " . $u->user . " has not banned any other users.");
is($run->("ban_list from " . $comm->user),
   "info: " . $comm->user . " has not banned any other users.");

my $comm2 = temp_comm();
is($run->("ban_list from " . $comm2->user),
   "error: You are not a maintainer of this account");
$u->grant_priv("finduser", "");
is($run->("ban_list from " . $comm2->user),
   "info: " . $comm2->user . " has not banned any other users.");
$u->revoke_priv("finduser", "");





# ------------ PRINT FUNCTIONS ---------------
is(LJ::Console->run_commands_text("print one"), "info: Welcome to 'print'!\nsuccess: one");
is(LJ::Console->run_commands_text("print one !two"), "info: Welcome to 'print'!\nsuccess: one\nerror: !two");
