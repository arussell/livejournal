# -*-perl-*-

use strict;
use Test::More 'no_plan';
use lib "$ENV{LJHOME}/cgi-bin";
require 'ljlib.pl';
use FindBin qw($Bin);

my $sysid = LJ::load_user("system")->{userid};
ok($sysid, "have a systemid");

{
    local @LJ::MEMCACHE_SERVERS = ();
    run_tests();
}

{
    local @LJ::MEMCACHE_SERVERS = ("127.0.0.1:11211");
    run_tests();
}

{
    local @LJ::MEMCACHE_SERVERS = ("127.0.0.1:11211");
    LJ::start_request();
    is_empty();

    my $u = LJ::load_user("system");
    ok($u, "Have system user");
    die unless $u;

    my $u2 = LJ::load_userid($u->{userid});
    is($u, $u2, "whether loading by name or userid, \$u objects are singletons");

    $u2->{_foo} = "field";

    is($u->{_foo}, "field", "our u _foo field is present");

    # this forced load will use the same memory address as our other $u of
    # the same id
    my $uf = LJ::load_userid($u->{userid}, "force");
    is($u, $uf, "forced userid load is u2");
    is($u2->{_foo}, undef, "our u2 _foo field is now gone");

    my $uf2 = LJ::load_user("system", "force");
    is($uf2, $uf, "forced system");


}

sub is_empty {
    is(scalar keys %LJ::REQ_CACHE_USER_NAME, 0, "reqcache for users is empty");
    is(scalar keys %LJ::REQ_CACHE_USER_ID, 0,   "reqcache for userids is empty");
}

sub run_tests {
    my $up;
    LJ::start_request();
    is_empty();
    my $u = LJ::load_user("system");
    ok($u, "Have system user");
    die unless $u;

    my $u2 = LJ::load_userid($u->{userid});
    is($u, $u2, "whether loading by name or userid, \$u objects are singletons");
}
