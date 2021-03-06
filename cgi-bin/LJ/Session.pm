package LJ::Session;
use strict;
use Carp qw(croak);
use Digest::HMAC_SHA1 qw(hmac_sha1 hmac_sha1_hex);
use LJ::Request;
use Class::Autouse qw(
                      LJ::EventLogRecord::SessionExpired
                      );
use LJ::Auth::Secret;
use LJ::TimeUtil;
use Digest::MD5;

use constant VERSION => 1;
use constant LJLOGGEDIN_VERSION => 2;
use constant MASTER_VERSION => 2;

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
# * the 'auth' field of the session object is the prized possession which
#   we might hide from XSS attackers.  they can steal domain cookies but
#   they're not good very long and can't do much.  it's the ljmastersession
#   containing the auth that we care about.
#

############################################################################
#  CREATE/LOAD SESSIONS OBJECTS
############################################################################

sub instance {
    my ($class, $u, $sessid) = @_;

    return undef unless $u && !$u->is_expunged;

    # try memory
    my $memkey = _memkey($u, $sessid);
    my $sess = LJ::MemCacheProxy::get($memkey);
    return $sess if $sess;

    # try master
    $sess = $u->selectrow_hashref("SELECT userid, sessid, exptype, auth, timecreate, timeexpire, ipfixed " .
                                  "FROM sessions WHERE userid=? AND sessid=?",
                                  undef, $u->{'userid'}, $sessid)
        or return undef;

    bless $sess;
    LJ::MemCacheProxy::set($memkey, $sess);
    return $sess;
}

sub active_sessions {
    my ($class, $u) = @_;
    my $sth = $u->prepare("SELECT userid, sessid, exptype, auth, timecreate, timeexpire, ipfixed " .
                          "FROM sessions WHERE userid=? AND timeexpire > UNIX_TIMESTAMP()");
    $sth->execute($u->{userid});
    my @ret;
    while (my $rec = $sth->fetchrow_hashref) {
        bless $rec;
        push @ret, $rec;
    }
    return @ret;
}

sub record_login {
    my ( $class, $u, $sessid ) = @_;
    $sessid ||= 0;

    my $too_old = time() - 86400 * 30;
    $u->do( "DELETE FROM loginlog WHERE userid=? AND logintime < ?",
        undef, $u->{userid}, $too_old );

    my ( $ip, $ua );
    eval {
        $ip = LJ::get_remote_ip();
        $ua = LJ::Request->header_in('User-Agent');
    };

    return $u->do(
        "INSERT INTO loginlog SET userid=?, sessid=?, "
            . "logintime=UNIX_TIMESTAMP(), ip=?, ua=?",
        undef, $u->{userid}, $sessid, $ip, $ua
    );
}

sub create {
    my ($class, $u, %opts) = @_;

    # validate options
    my $exptype = delete $opts{'exptype'} || "short";
    my $ipfixed = delete $opts{'ipfixed'};   # undef or scalar ipaddress  FIXME: validate
    my $nolog   = delete $opts{'nolog'} || 0; # 1 to not log to loginlogs
    croak("Invalid exptype") unless $exptype =~ /^short|long|once$/;

    croak("Invalid options: " . join(", ", keys %opts)) if %opts;

    my $udbh = LJ::get_cluster_master($u);
    return undef unless $udbh;

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

    $class->record_login($u, $id)
        unless $nolog;

    $u->do("REPLACE INTO sessions (userid, sessid, auth, exptype, ".
           "timecreate, timeexpire, ipfixed) VALUES (?,?,?,?,LAST_INSERT_ID(UNIX_TIMESTAMP()),".
           "?,?)", undef,
           $u->{'userid'}, $id, $sess->{'auth'}, $exptype, $timeexpire, $ipfixed);

    return undef if $u->err;
    $sess->{'sessid'} = $id;
    $sess->{'userid'} = $u->{'userid'};

    $sess->{timecreate} = $u->mysql_insertid;

    # clean up old sessions
    my $old = $udbh->selectcol_arrayref("SELECT sessid FROM sessions WHERE ".
                                        "userid=$u->{'userid'} AND ".
                                        "timeexpire < UNIX_TIMESTAMP()");
    $u->kill_sessions(@$old) if $old;

    # mark account as being used
    LJ::mark_user_active($u, 'login');

    bless $sess;
    return $u->{'_session'} = $sess;
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
    my ( $sess, $exptype ) = @_;

    croak("Invalid exptype") unless $exptype =~ /^short|long|once$/;

    my $ret = $sess->_dbupdate(
        exptype    => $exptype,
        timeexpire => time() + LJ::Session->session_length($exptype),
    );

    if ($ret) {
        $sess->record_login( $sess->owner, $sess->{'sessid'} );
    }

    return $ret;
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

    LJ::MemCacheProxy::delete($sess->_memkey);
    return 1;

}

# returns unix timestamp of expiration
sub expiration_time {
    my $sess = shift;

    # expiration time if we have it,
    return $sess->{timeexpire} if $sess->{timeexpire};

    $sess->{timeexpire} = time() + LJ::Session->session_length($sess->{exptype});
    return $sess->{timeexpire};
}

# return format of the "ljloggedin" cookie.
sub loggedin_cookie_string {
    my ($sess, $version) = @_;

    my $time = $sess->{timecreate};
    $version ||= LJLOGGEDIN_VERSION;

    my $signed = "v$version:u$sess->{userid}:s$sess->{sessid}:t$time";
    my $secret = LJ::conf_test($LJ::LJLOGGEDIN_SECRET, $sess, $time, $signed);
    my $sign   = $version eq '1' 
                 ? hmac_sha1_hex($time . $secret . $signed)
                 : hmac_sha1_hex($signed, $secret);
    return $signed . ":g$sign";
}

# for backward compatibility.
# this method is a copy of loggedin_cookie_string method without sign part.
# it's safe to remove it some day. 
sub unsigned_loggedin_cookie_string {
    my ($sess) = @_;
    return "u$sess->{userid}:s$sess->{sessid}";
}

sub master_cookie_string {
    my $sess = shift;

    my $ver    = MASTER_VERSION;
    my $sig    = master_signature($sess);
    my $cookie = "v$ver:" .
        "u$sess->{userid}:" .
        "s$sess->{sessid}:" .
        "a$sess->{auth}:" .
        "g$sig";

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
    my $secret = LJ::Auth::Secret->create();
    croak("Could not create secret") unless $secret;
    my $time = $secret->ts;
    my $sig = domsess_signature($time, $sess, $domcook);

    # the cookie
    my $ver = VERSION;
    my $value = "v$ver:" .
        "u$sess->{userid}:" .
        "s$sess->{sessid}:" .
        "t$time:" .
        "g$sig//" .
        LJ::eurl($LJ::COOKIE_GEN || "");

    return $value;
}

# this is just a wrapper around domsess
sub fb_cookie_string {

    # FIXME: can we just use domsess's function like this?
    #        might be more differences so we need to write a new one?
    return domsess_cookie_string(@_);
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

    $sess->owner->preload_props('schemepref', 'browselang');

    if (my $scheme = $sess->owner->prop('schemepref')) {
        set_cookie(BMLschemepref   => $scheme,
                   domain          => $LJ::DOMAIN,
                   path            => '/',
                   http_only       => 1,
                   @expires,);
    } else {
        set_cookie(BMLschemepref   => "",
                   domain          => $LJ::DOMAIN,
                   path            => '/',
                   delete          => 1);
    }

    if (my $lang = $sess->owner->prop('browselang')) {
        set_cookie(langpref        => $lang . "/" . time(),
                   domain          => $LJ::DOMAIN,
                   path            => '/',
                   http_only       => 1,
                   @expires,);
    } else {
        set_cookie(langpref        => "",
                   domain          => $LJ::DOMAIN,
                   path            => '/',
                   delete          => 1);
    }

    # set fb global cookie
    if ($LJ::FB_SITEROOT) {
        my $fb_cookie = fb_cookie();
        set_cookie($fb_cookie    => $sess->fb_cookie_string($fb_cookie),
                   domain        => $LJ::DOMAIN,
                   path          => '/',
                   http_only     => 1,
                   @expires,);
    }

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

    LJ::EventLogRecord::SessionExpired->new($sess)->fire;

    return LJ::Session->destroy_sessions($u, $id);
}


# based on our type and current expiration length, update this cookie if we
# need to
sub try_renew {
    my ( $sess, $cookies ) = @_;

    # only renew long type cookies
    return if $sess->{exptype} ne 'long';

    # how long to live for
    my $u           = $sess->owner;
    my $sess_length = LJ::Session->session_length( $sess->{exptype} );
    my $now         = time();
    my $new_expire  = $now + $sess_length;

    # if there is a new session length to be set and the user's db writer is
    # available, go ahead and set the new session expiration in the database.
    # then only update the cookies if the database operation is successful
    if (   $sess_length
        && $sess->{'timeexpire'} - $now < $sess_length / 2
        && $u->writer )
    {
        return unless $sess->_dbupdate( 'timeexpire' => $new_expire );

        $sess->record_login( $u, $sess->{'sessid'} );
        $sess->update_master_cookie;
    }
}

############################################################################
#  CLASS METHODS
############################################################################

# NOTE: internal function REQUIRES trusted input
sub helper_url {
    my ($class, $dest) = @_;
 
    return unless $dest;

    my $u = LJ::get_remote();

    unless ($u) {
        LJ::Session->clear_master_cookie;
        return $dest;
    }

    my $domcook = LJ::Session->domain_cookie($dest) or
        return $dest;

    my $sess = $u->session;
    my $cookie = $sess->domsess_cookie_string($domcook);

    if ($dest =~ m!^(https?://)([^/]*?)\.\Q$LJ::USER_DOMAIN\E/?([a-z0-9\-_]*)!i) {
        my $url = "$1$2.$LJ::USER_DOMAIN/";

        if ($LJ::SUBDOMAIN_FUNCTION{lc($2)} eq "journal") {
            $url .= "$3/" if $3 && ($3 ne '/'); # 'http://community.livejournal.com/name/__setdomsess'
        }

        return $url . "__setdomsess?dest=" . LJ::eurl($dest) .
            "&k=" . LJ::eurl($domcook) . "&v=" . LJ::eurl($cookie);
    }
    elsif ( $dest =~ m!^(https?://)(.+?)(/.*)$! ) {
        my $setdomsess = $1 . $2;
        $dest =~ m!^https?://(?:www\.)?(.+?)(/.*)$!;

        return "${setdomsess}/__setdomsess?dest="
             . LJ::eurl($dest)
             . "&k=" . LJ::eurl($domcook)
             . "&v=" . LJ::eurl($cookie);
    }

    return $dest;
}

# given a URL (or none, for current url), what domain cookie represents this URL?
# return undef if not URL for a domain cookie, which means either bogus URL
# or the master cookies should be tried.
sub domain_cookie {
    my ($class, $url) = @_;
    my ($subdomain, $user) = LJ::Session->domain_journal($url);

    # undef:  not on a user-subdomain
    return undef
        unless defined $subdomain;

    # on a user subdomain, or shared subdomain
    if ($user ne "") {
        $user =~ s/-/_/g; # URLs may be - or _, convert to _ which is what usernames contain
        return "ljdomsess.$subdomain.$user";
    }
    else {
        return "ljdomsess.$subdomain";
    }
}

# given an optional URL (by default, the current URL), what is the username
# of that URL?.  undef if no user.  in list context returns the ($subdomain, $user)
# where $user can be "" if $subdomain isn't, say, "community" or "users".
# in scalar context, userame is always the canonical username (no hypens/capitals)
sub domain_journal {
    my ($class, $url) = @_;
    $url ||= _current_url();

    return undef unless
        $url =~ m!^https?://(.+?)(/.*)$!;

    my ($host, $path) = ($1, $2);
    $host = lc($host);

    # don't return a domain cookie for the master domain
    return undef if
        $host eq lc($LJ::DOMAIN_WEB) ||
        $host eq lc($LJ::DOMAIN) ||
        $host eq lc($LJ::SSLDOMAIN);

    $host =~ s/^www\.//;

    return wantarray ? ( '__external', "") : '__external' if
        exists $LJ::DOMAIN_JOURNALS_REVERSE{$host};

    return wantarray ? ( '__external', "") : '__external' unless
        $host =~ m!^([\w\-\.]{1,50})\.\Q$LJ::USER_DOMAIN\E$!;

    my $subdomain = $1 || lc($host);

    if ($LJ::SUBDOMAIN_FUNCTION{$subdomain} eq "journal") {
        return undef unless $path =~ m!^/(\w{1,15})\b!;

        my $user = lc($1);
        return wantarray ? ($subdomain, $user) : $user;
    }

    if( $subdomain ) {
        # where $subdomain is actually a username:
        return wantarray ? ($subdomain, "") : LJ::canonical_username($subdomain);
    }

    return wantarray ? ( '__external', "") : '__external';
}

sub url_owner {
    my ($class, $url) = @_;
    $url ||= _current_url();
    my ($subdomain, $user) = LJ::Session->domain_journal($url);
    $user = $subdomain if $user eq "";
    return LJ::canonical_username($user);
}

sub fb_cookie {
    my ($class) = @_;

    # where $subdomain is actually a username:
    return "ljsession";
}

# CLASS METHOD
#  -- frontend to session_from_domain_cookie and session_from_master_cookie below
sub session_from_cookies {
    my $class = shift;
    my %getopts = @_;

    # must be in web context
    return undef unless LJ::Request->is_inited;

    my $sessobj;
    my $host = LJ::Request->header_in("Host");
    my $domain_cookie = LJ::Session->domain_cookie;

    # foreign domain case
    unless ( $host =~ /(^|\.)$LJ::DOMAIN(:\d+)?$/ ) {
        return LJ::Session->session_from_external_cookie(\%getopts, @{ $BML::COOKIE{"$domain_cookie\[\]"} || [] });
    }

    if ($domain_cookie) {
        # journal domain
        $sessobj = LJ::Session->session_from_domain_cookie(\%getopts, @{ $BML::COOKIE{"$domain_cookie\[\]"} || [] });
    }
    else {
        # this is the master cookie at "www.livejournal.com" or "livejournal.com";
        my @cookies = @{ $BML::COOKIE{'ljmastersession[]'} || [] };

        # but support old clients who are just sending an "ljsession" cookie which they got
        # from ljprotocol's "generatesession" mode.
        unless (@cookies) {
            @cookies = @{ $BML::COOKIE{'ljsession[]'} || [] };
            $getopts{old_cookie} = 1;
        }

        $sessobj = LJ::Session->session_from_master_cookie(\%getopts, @cookies);
    }

    return $sessobj;
}

sub session_from_external_cookie {
    my $class = shift;
    my $opts = ref $_[0] ? shift() : {};

    my $no_session = sub {
        my $reason = shift;
        my $rr = $opts->{redirect_ref};

        if ($rr) {
            my $curl = _current_url();
            $curl =~ m|^https?://(.+?)/|i;
            my $domain = $1;

            set_cookie(
                'ljdomsess.__external' => '',
                path       => '/',
                http_only  => 1,
                domain     => $domain,
            );
        }
        return undef;
    };

    my @cookies = grep { $_ } @_;
    return $no_session->("no cookies") unless @cookies;

    my $domcook = LJ::Session->domain_cookie;
    foreach my $cookie (@cookies) {
        my $sess = valid_domain_cookie($domcook, $cookie, undef, {ignore_li_cook=>1,});

        next unless $sess;
        return $sess;
    }

    return $no_session->("no valid cookie");
}

# CLASS METHOD
#   -- but not called directly.  usually called by LJ::Session->session_from_cookies above
sub session_from_domain_cookie {
    my $class = shift;
    my $opts = ref $_[0] ? shift() : {};

    # the logged-in cookie
    my $li_cook = $BML::COOKIE{'ljloggedin'};
    return undef unless $li_cook;

    my $no_session = sub {
        my $reason = shift;
        my $rr = $opts->{redirect_ref};

        if ($rr) {
            my $current_url = _current_url();

            my $time     = time;
            my $sign     = LJ::run_hook('sign_set_domain_session_redirect' => $current_url, $time);
            my $returnto = LJ::eurl($current_url);
            $$rr = "$LJ::SITEROOT/misc/get_domain_session.bml?return=" . $returnto . '&sign=' . $sign . '&t=' . $time;
        }

        return undef;
    };

    my @cookies = grep { $_ } @_;
    return $no_session->("no cookies") unless @cookies;

    my $domcook = LJ::Session->domain_cookie;

    foreach my $cookie (@cookies) {
        my $sess = valid_domain_cookie($domcook, $cookie, $li_cook);
        next unless $sess;
        return $sess;
    }

    return $no_session->("no valid cookie");
}

sub session_from_fb_cookie {
    my $class = shift;

    my $domcook  = LJ::Session->fb_cookie;
    my $fbcookie = $BML::COOKIE{$domcook};
    return undef unless $fbcookie;

    my $sess = valid_fb_cookie($domcook, $fbcookie);
    return $sess;
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
    my $old_cookie = delete $opts->{old_cookie} ? 1 : 0;

    delete $opts->{'redirect_ref'};  # we don't use this
    croak("Unknown options: " . join(', ', keys(%$opts))) if %$opts;

    my $now = time();

    # our return value
    my $sess;

    my $li_cook = $BML::COOKIE{'ljloggedin'};

  COOKIE:
    foreach my $sessdata (@cookies) {
        my ($cookie, $gen) = split(m!//!, $sessdata);
        my ($version, $userid, $sessid, $auth, $flags, $sig);

        my $dest = {
            v => \$version,
            u => \$userid,
            s => \$sessid,
            a => \$auth,
            f => \$flags,
            g => \$sig
        };

        my $bogus = 0;
        foreach my $var (split /:/, $cookie) {
            if ( $var =~ /^(\w)(.+)$/ && $dest->{$1} ) {
                ${$dest->{$1}} = $2;
            }
            else {
                $bogus = 1;
            }
        }

        # must do this first so they can't trick us
        $$tried_fast = 1 if $flags =~ /\.FS\b/;

        next COOKIE if $bogus;

        next COOKIE unless valid_cookie_generation($gen);

        my $err = sub {
            $sess = undef;
            push @$errs, "$sessdata: $_[0]";
        };

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

        # make sure their ljloggedin cookie
        unless ($old_cookie){
            my ($version)   = $li_cook =~ m/^v(\d+)/;
            my $sess_cookie = $version
                              ? $sess->loggedin_cookie_string($version) ## versioned cookie
                              : $sess->unsigned_loggedin_cookie_string; ## backward compatibility: user has cookie without a sign
            if ($sess_cookie ne $li_cook){
                $err->("loggedin cookie bogus");
                next COOKIE;
            }
        }

        # current cookie version
        if ( $version == MASTER_VERSION ) {
            unless ( $sig eq master_signature($sess) ) {
                $err->("wrong master cookie signature");
                next COOKIE;
            }
        }
        # prev cookie version
        elsif ( $version == MASTER_VERSION - 1 ) {
            # don't check signature
            # it will work for a some time
        }
        # all other cookie must fail
        else {
            $err->("no ws auth");
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
        LJ::MemCacheProxy::delete(_memkey($u, $id));
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

    # set fb global cookie
    if ($LJ::FB_SITEROOT) {
        my $fb_cookie = fb_cookie();
        set_cookie($fb_cookie    => "",
                   domain        => $LJ::DOMAIN,
                   path          => '/',
                   delete        => 1);
    }
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
    my $class = shift;
    my %get = LJ::Request->args;

    my $dest    = $get{'dest'};
    my $domcook = $get{'k'};
    my $cookie  = $get{'v'};
    my $expires = $LJ::DOMSESS_EXPIRATION || 0; # session-cookie only
    my $path    = '/'; # By default cookie path is root

    my $curl = _current_url();
    $curl =~ m|^https?://(.+?)/|i;
    my $domain = $1;

    if ($domcook eq 'ljdomsess.__external') { # foreign domain case
        return $LJ::SITEROOT unless valid_domain_cookie($domcook, $cookie, undef, { ignore_li_cook => 1,});
    }
    else { # livejournal domain case

        return "$LJ::SITEROOT" unless valid_destination($dest);
        return $dest unless valid_domain_cookie($domcook, $cookie, $BML::COOKIE{'ljloggedin'});
    }

    set_cookie(
        $domcook   => $cookie,
        path       => $path,
        http_only  => 1,
        expires    => $expires,
        domain     => $domain ? $domain : '',
    );

    # add in a trailing slash, if URL doesn't have at least two slashes.
    # otherwise the path on the cookie above (which is like /community/)
    # won't be caught when we bounce them to /community.
    unless ($dest =~ m!^https?://.+?/.+?/! || $path eq "/") {
        # add a slash unless we can slip one in before the query parameters
        $dest .= "/" unless $dest =~ s!\?!/?!;
    }

    return $dest;
}


############################################################################
#  UTIL FUNCTIONS
############################################################################

sub _current_url {
    my $args = LJ::Request->args;
    my $args_wq = $args ? "?$args" : "";
    my $host = LJ::Request->header_in("Host");
    my $uri = LJ::Request->uri;
    return "http://$host$uri$args_wq";
}

sub master_signature {
    my ($sess) = @_;
    my $u      = $sess->owner;
    my $secret = $LJ::MASTER_COOKIE_SALT;

    my $data = join("-", $sess->{auth}, $u->{userid}, $sess->{sessid});
    my $sig  = hmac_sha1_hex($data, $secret);

    return $sig;
}

sub domsess_signature {
    my ($time, $sess, $domcook) = @_;

    my $u      = $sess->owner;
    my $secret = LJ::Auth::Secret->create($time);
    croak("Could not create secret") unless $secret;

    my $data = join("-", $sess->{auth}, $domcook, $u->{userid}, $sess->{sessid}, $time);
    return hmac_sha1_hex($data, $secret->value);
}

# same logic as domsess_signature, so just a wrapper
sub fb_signature {
    my ($time, $sess, $fbcook) = @_;

    return domsess_signature($time, $sess, $fbcook);
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

    return unless LJ::Request->is_inited;

    my $http_only = delete $opts{http_only};
    my $domain    = delete $opts{domain};
    my $path      = delete $opts{path};
    my $expires   = delete $opts{expires};
    my $delete    = delete $opts{delete};
    croak("Invalid cookie options: " . join(", ", keys %opts)) if %opts;

    # Mac IE 5 can't handle HttpOnly, so filter it out
    if ($http_only && ! $LJ::DEBUG{'no_mac_ie_httponly'}) {
        my $ua = LJ::Request->header_in("User-Agent");
        $http_only = 0 if $ua =~ /MSIE.+Mac_/;
    }

    # expires can be absolute or relative.  this is gross or clever, your pick.
    $expires += time() if $expires && $expires <= 1135217120;

    if ($delete) {
        # set expires to 5 seconds after 1970.  definitely in the past.
        # so cookie will be deleted.
        $expires = 5 if $delete;
    }

    my $cookiestr = $key . '=' . $value;
    $cookiestr .= '; expires=' . LJ::TimeUtil->time_to_cookie($expires) if $expires;
    $cookiestr .= '; domain=' . $domain if $domain;
    $cookiestr .= '; path=' . $path if $path;
    $cookiestr .= '; HttpOnly' if $http_only;

    LJ::Request->err_headers_out->add('Set-Cookie' => $cookiestr);

    # Backwards compatability for older browsers
    my @labels = split(/\./, $domain);
    if ($domain && scalar @labels == 2 && ! $LJ::DEBUG{'no_extra_dot_cookie'}) {
        my $cookiestr = $key . '=' . $value;
        $cookiestr .= '; expires=' . LJ::TimeUtil->time_to_cookie($expires) if $expires;
        $cookiestr .= '; domain=.' . $domain;
        $cookiestr .= '; path=' . $path if $path;
        $cookiestr .= '; HttpOnly' if $http_only;

        LJ::Request->err_headers_out->add('Set-Cookie' => $cookiestr);
    }
}

# returns undef or a session, given a $domcook and its $val, as well
# as the current logged-in cookie $li_cook which says the master
# session's uid/sessid
sub valid_domain_cookie {
    my ($domcook, $val, $li_cook, $opts) = @_;
    $opts ||= {};

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
    my @bogus;

    foreach my $var (split /:/, $cookie) {
        if ($var =~ /^(\w)(.+)$/ && $dest->{$1}) {
            ${$dest->{$1}} = $2;
        }
        else {
            $bogus = 1;
            push @bogus, $var;
        }
    }

    my $not_valid = sub {
        my $reason = shift;
        return undef;
    };

    return $not_valid->("bogus params", @bogus) if $bogus;
    return $not_valid->("wrong gen") unless valid_cookie_generation($gen);
    return $not_valid->("wrong version", $version, VERSION) if $version != VERSION;

    # have to be relatively new.  these shouldn't last longer than a day
    # or so anyway.
    unless ($opts->{ignore_age}) {
        my $now = time();
        return $not_valid->("old cookie", $time, $now) unless $time > $now - 86400*7;
    }

    my $u = LJ::load_userid($uid)
        or return $not_valid->("no user $uid");

    my $sess = $u->session($sessid)
        or return $not_valid->("no session $sessid");

    # the master session can't be expired or ip-bound to wrong IP
    return $not_valid->("not valid session") unless $sess->valid;

    # the per-domain cookie has to match the session of the master cookie
    unless ($opts->{ignore_li_cook}) {
        my ($version)   = $li_cook =~ m/^v(\d+)/;
        my $sess_licook = $version
                              ? $sess->loggedin_cookie_string($version) ## versioned cookie
                              : $sess->unsigned_loggedin_cookie_string; ## backward compatibility: user has cookie without a sign
        return $not_valid->("li_cook mismatch.  session=$sess_licook, user=$li_cook")
            unless $sess_licook eq $li_cook;
    }

    my $correct_sig = domsess_signature($time, $sess, $domcook);
    return $not_valid->("signature wrong", $sig, $correct_sig) unless $correct_sig eq $sig;

    return $sess;
}

sub valid_fb_cookie {
    my ($domcook, $val) = @_;
    my $opts = {
        ignore_age     => 1,
        ignore_li_cook => 1,
    };
    return valid_domain_cookie($domcook, $val, undef, $opts);
}

sub valid_destination {
    my $dest = shift;
    return $dest =~ qr!^http://[\w\-\.]+\.\Q$LJ::USER_DOMAIN\E/.*!;
}

sub valid_cookie_generation {
    my $gen    = shift;
    my $dgen   = LJ::durl($gen);
    foreach my $okay ($LJ::COOKIE_GEN, @LJ::COOKIE_GEN_OKAY) {
        return 1 if $gen  eq $okay;
        return 1 if $dgen eq $okay;
    }
    return 0;
}


sub allow_login_from_iframe {
    # This P3P header should be set to enable login when login page is in <iframe> tag on the other site
    my $header_name = 'P3P';
    my $header_body = 'CP="NON DSP COR CUR ADM DEV PSA PSD OUR UNR BUS UNI COM NAV INT DEM STA"';
    LJ::Request->set_header_out($header_name, $header_body);
}

sub best_guess_remote {
    my ($class) = @_;

    my $cookieval = LJ::Request->cookie('ljloggedin');
    return unless $cookieval;

    my ( undef, $useridval ) = split m{:}, $cookieval;
    return unless $useridval && $useridval =~ /^u\d+$/;

    my $userid = $useridval;
    $userid =~ s/^u//;
    return unless $userid;

    my $u = LJ::load_userid($userid);
    return unless $u;

    return $u;
}

1;
