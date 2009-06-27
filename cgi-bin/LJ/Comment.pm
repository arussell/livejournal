#
# LiveJournal comment object.
#
# Just framing right now, not much to see here!
#

package LJ::Comment;

use strict;
use Carp qw/ croak /;
use Class::Autouse qw(
                      LJ::Entry
                      );

use lib "$LJ::HOME/cgi-bin";

require "htmlcontrols.pl";
require "talklib.pl";

# internal fields:
#
#    journalid:     journalid where the commend was
#                   posted,                          always present
#    jtalkid:       jtalkid identifying this comment
#                   within the journal_u,            always present
#
#    nodetype:      single-char nodetype identifier, loaded if _loaded_row
#    nodeid:        nodeid to which this comment
#                   applies (often an entry itemid), loaded if _loaded_row
#
#    parenttalkid:  talkid of parent comment,        loaded if _loaded_row
#    posterid:      userid of posting user           lazily loaded at access
#    datepost_unix: unixtime from the 'datepost'     loaded if _loaded_row
#    state:         comment state identifier,        loaded if _loaded_row

#    body:          text of comment,                 loaded if _loaded_text
#    body_orig:     text of comment w/o transcoding, present if unknown8bit

#    subject:       subject of comment,              loaded if _loaded_text
#    subject_orig   subject of comment w/o transcoding, present if unknown8bit

#    props:   hashref of props,                    loaded if _loaded_props

#    _loaded_text:   loaded talktext2 row
#    _loaded_row:    loaded talk2 row
#    _loaded_props:  loaded props

my %singletons = (); # journalid->jtalkid->singleton

sub reset_singletons {
    %singletons = ();
}

# <LJFUNC>
# name: LJ::Comment::new
# class: comment
# des: Gets a comment given journal_u entry and jtalkid.
# args: uobj, opts?
# des-uobj: A user id or user object ($u) to load the comment for.
# des-opts: Hash of optional keypairs.
#           jtalkid => talkid journal itemid (no anum)
# returns: A new LJ::Comment object. Returns undef on failure.
# </LJFUNC>
sub instance {
    my $class = shift;
    my $self  = bless {};

    my $uuserid = shift;
    my $n_arg   = scalar @_;
    croak("wrong number of arguments")
        unless $n_arg && ($n_arg % 2 == 0);

    my %opts = @_;

    $self->{journalid} = LJ::want_userid($uuserid) or
        croak("invalid journalid parameter");

    $self->{jtalkid} = int(delete $opts{jtalkid});

    if (my $dtalkid = int(delete $opts{dtalkid})) {
        $self->{jtalkid} = $dtalkid >> 8;
    }

    croak("need to supply jtalkid or dtalkid")
        unless $self->{jtalkid};

    croak("unknown parameter: " . join(", ", keys %opts))
        if %opts;

    my $journalid = $self->{journalid};
    my $jtalkid   = $self->{jtalkid};

    # do we have a singleton for this comment?
    $singletons{$journalid} ||= {};
    return $singletons{$journalid}->{$jtalkid}
        if $singletons{$journalid}->{$jtalkid};

    # save the singleton if it doesn't exist
    $singletons{$journalid}->{$jtalkid} = $self;

    croak("need to supply jtalkid") unless $self->{jtalkid};
    croak("unknown parameters: " . join(", ", keys %opts))
        if %opts;
    return $self;
}
*new = \&instance;

# class method. takes a ?thread= or ?replyto= URL
# to a comment, and returns that comment object
sub new_from_url {
    my ($class, $url) = @_;
    $url =~ s!#.*!!;

    if ($url =~ /(.+?)\?(?:thread|replyto)\=(\d+)/) {
        my $entry = LJ::Entry->new_from_url($1);
        return undef unless $entry;
        return LJ::Comment->new($entry->journal, dtalkid => $2);
    }

    return undef;
}


# <LJFUNC>
# name: LJ::Comment::create
# class: comment
# des: Create a new comment. Add them to DB.
# args: 
# returns: A new LJ::Comment object. Returns undef on failure.
# </LJFUNC>

sub create {
    my $class = shift;
    my %opts  = @_;
    
    my $need_captcha = delete($opts{ need_captcha }) || 0;

    # %talk_opts emulates parameters received from web form.
    # Fill it with nessesary options.
    my %talk_opts = map { $_ => delete $opts{$_} }
                    qw(nodetype parenttalkid body subject props);

    # poster and journal should be $u objects,
    # but talklib wants usernames... we'll map here
    my $journalu = delete $opts{journal};
    croak "invalid journal for new comment: $journalu"
        unless LJ::isu($journalu);

    my $posteru = delete $opts{poster};
    croak "invalid poster for new comment: $posteru"
        unless LJ::isu($posteru);

    # LJ::Talk::init uses 'itemid', not 'ditemid'.
    $talk_opts{itemid} = delete $opts{ditemid};

    # LJ::Talk::init needs journal name
    $talk_opts{journal} = $journalu->user;

    # Strictly parameters check. Do not allow any unused params to be passed in.
    croak (__PACKAGE__ . "->create: Unsupported params: " . join " " => keys %opts )
        if %opts;

    # Move props values to the talk_opts hash.
    # Because LJ::Talk::Post::init needs this.
    foreach my $key (  keys %{ $talk_opts{props} }  ){
        my $talk_key = "prop_$key";
         
        $talk_opts{$talk_key} = delete $talk_opts{props}->{$key} 
                            if not exists $talk_opts{$talk_key};
    }

    # The following 2 options are necessary for successful user authentification 
    # in the depth of LJ::Talk::Post::init.
    #
    # FIXME: this almost certainly should be 'usertype=user' rather than
    #        'cookieuser' with $remote passed below.  Gross.
    $talk_opts{cookieuser} ||= $posteru->user;
    $talk_opts{usertype}   ||= 'cookieuser';
    $talk_opts{nodetype}   ||= 'L';

    ## init.  this handles all the error-checking, as well.
    my @errors       = ();
    my $init = LJ::Talk::Post::init(\%talk_opts, $posteru, \$need_captcha, \@errors); 
    croak( join "\n" => @errors )
        unless defined $init;

    # check max comments
    croak ("Sorry, this entry already has the maximum number of comments allowed.")
        if LJ::Talk::Post::over_maxcomments($init->{journalu}, $init->{item}->{'jitemid'});

    # no replying to frozen comments
    croak('No reply to frozen thread')
        if $init->{parent}->{state} eq 'F';

    ## insertion
    my $wasscreened = ($init->{parent}->{state} eq 'S');
    my $err;
    croak ($err)
        unless LJ::Talk::Post::post_comment($init->{entryu},  $init->{journalu},
                                            $init->{comment}, $init->{parent}, 
                                            $init->{item},   \$err,
                                            );
    
    return 
        LJ::Comment->new($init->{journalu}, jtalkid => $init->{comment}->{talkid});

}


sub absorb_row {
    my ($self, %row) = @_;

    $self->{$_} = $row{$_} foreach (qw(nodetype nodeid parenttalkid posterid datepost state));
    $self->{_loaded_row} = 1;
}

sub url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?thread=$dtalkid#t$dtalkid";
}

sub reply_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?replyto=$dtalkid";
}

sub thread_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?thread=$dtalkid#t$dtalkid";
}

sub parent_url {
    my $self    = shift;

    my $parent  = $self->parent;

    return undef unless $parent;
    return $parent->url;
}

sub unscreen_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $journal = $entry->journal->{user};

    return
        "$LJ::SITEROOT/talkscreen.bml" .
        "?mode=unscreen&journal=$journal" .
        "&talkid=$dtalkid";
}

sub delete_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $journal = $entry->journal->{user};

    return
        "$LJ::SITEROOT/delcomment.bml" .
        "?journal=$journal&id=$dtalkid";
}

sub edit_url {
    my $self    = shift;

    my $dtalkid = $self->dtalkid;
    my $entry   = $self->entry;
    my $url     = $entry->url;

    return "$url?edit=$dtalkid";
}

# return img tag of userpic that the comment poster used
sub poster_userpic {
    my $self = shift;
    my $pic_kw = $self->prop('picture_keyword');
    my $posteru = $self->poster;

    # anonymous poster, no userpic
    return "" unless $posteru;

    # new from keyword falls back to the default userpic if
    # there was no keyword, or if the keyword is no longer used
    my $pic = LJ::Userpic->new_from_keyword($posteru, $pic_kw);
    return $pic->imgtag_nosize if $pic;

    # no userpic with comment
    return "";
}

# return LJ::User of journal comment is in
sub journal {
    my $self = shift;
    return LJ::load_userid($self->{journalid});
}

sub journalid {
    my $self = shift;
    return $self->{journalid};
}

# return LJ::Entry of entry comment is in, or undef if it's not
# a nodetype of L
sub entry {
    my $self = shift;

    return undef unless $self && $self->valid;
    return LJ::Entry->new($self->journal, jitemid => $self->nodeid);
}

sub jtalkid {
    my $self = shift;
    return $self->{jtalkid};
}

sub dtalkid {
    my $self = shift;
    my $entry = $self->entry;
    return ($self->jtalkid * 256) + $entry->anum;
}

sub nodeid {
    my $self = shift;

    # we want to fast-path and not preload_rows here if we can avoid it...
    # this sometimes gets called en masse on a bunch of comments, and
    # if there are a lot, the preload_rows calls (which do nothing) cause
    # the apache request to time out.
    return $self->{nodeid} if $self->{_loaded_row};

    __PACKAGE__->preload_rows([ $self->unloaded_singletons] );
    return $self->{nodeid};
}

sub nodetype {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self->unloaded_singletons] );
    return $self->{nodetype};
}

sub parenttalkid {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self->unloaded_singletons ]);
    return $self->{parenttalkid};
}

# returns a LJ::Comment object for the parent
sub parent {
    my $self = shift;
    my $ptalkid = $self->parenttalkid or return undef;

    return LJ::Comment->new($self->journal, jtalkid => $ptalkid);
}

# returns an array of LJ::Comment objects with parentid == $self->jtalkid
sub children {
    my $self = shift;

    my $entry = $self->entry;
    return grep { $_->{parenttalkid} == $self->{jtalkid} } $entry->comment_list;

    # FIXME: It might be a good idea to check to see if the entry object had
    #        comments cached above, then fall back to a query to select a list
    #        from db or memcache
}

sub has_children {
    my $self = shift;

    return $self->children ? 1 : 0;
}

# returns true if entry currently exists.  (it's possible for a given
# $u, to make a fake jitemid and that'd be a valid skeleton LJ::Entry
# object, even though that jitemid hasn't been created yet, or was
# previously deleted)
sub valid {
    my $self = shift;
    my $u = $self->journal;
    return 0 unless $u && $u->{clusterid};
    __PACKAGE__->preload_rows([ $self->unloaded_singletons ]);
    return $self->{_loaded_row};
}

# when was this comment left?
sub unixtime {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self->unloaded_singletons ]);
    return LJ::mysqldate_to_time($self->{datepost}, 0);
}

# returns LJ::User object for the poster of this entry, or undef for anonymous
sub poster {
    my $self = shift;
    return LJ::load_userid($self->posterid);
}

sub posterid {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self->unloaded_singletons ]);
    return $self->{posterid};
}

sub all_singletons {
    my $self = shift;
    my @singletons;
    push @singletons, values %{$singletons{$_}} foreach keys %singletons;
    return @singletons;
}

# returns an array of unloaded comment singletons
sub unloaded_singletons {
    my $self = shift;
    return grep { ! $_->{_loaded_row} } $self->all_singletons;
}

# returns an array of comment singletons which don't have text loaded yet
sub unloaded_text_singletons {
    my $self = shift;
    return grep { ! $_->{_loaded_text} } $self->all_singletons;
}

# returns an array of comment singletons which don't have prop rows loaded yet
sub unloaded_prop_singletons {
    my $self = shift;
    return grep { ! $_->{_loaded_props} } $self->all_singletons;
}

# class method:
sub preload_rows {
    my ($class, $obj_list) = @_;

    my @to_load =
        (map  { [ $_->journal, $_->jtalkid ] }
         grep { ! $_->{_loaded_row} } @$obj_list);

    # already loaded?
    return 1 unless @to_load;

    # args: ([ journalid, jtalkid ], ...)
    my @rows = LJ::Talk::get_talk2_row_multi(@to_load);

    # make a mapping of journalid-jtalkid => $row
    my %row_map = map { join("-", $_->{journalid}, $_->{jtalkid}) => $_ } @rows;

    foreach my $obj (@$obj_list) {
        my $u = $obj->journal;

        my $row = $row_map{join("-", $u->id, $obj->jtalkid)};
        next unless $row;

        # absorb row into the given LJ::Comment object
        $obj->absorb_row(%$row);
    }

    return 1;
}

# returns true if loaded, zero if not.
# also sets _loaded_text and subject and event.
sub _load_text {
    my $self = shift;
    return 1 if $self->{_loaded_text};

    my $entry  = $self->entry;
    my $entryu = $entry->journal;
    my $entry_uid = $entryu->id;

    # find singletons which don't already have text loaded
    my @to_load = grep { $_->journalid == $entry_uid } $self->unloaded_text_singletons;

    my $ret  = LJ::get_talktext2($entryu, map { $_->jtalkid } @to_load);
    return 0 unless $ret && ref $ret;

    # iterate over comment objects we retrieved and set their subject/body/loaded members
    foreach my $c_obj (@to_load) {
        my $tt = $ret->{$c_obj->jtalkid};
        next unless ($tt && ref $tt);

        # raw subject and body
        $c_obj->{subject} = $tt->[0];
        $c_obj->{body}    = $tt->[1];

        if ($c_obj->prop("unknown8bit")) {
            # save the old ones away, so we can get back at them if we really need to
            $c_obj->{subject_orig} = $c_obj->{subject};
            $c_obj->{body_orig}    = $c_obj->{body};

            # FIXME: really convert all the props?  what if we binary-pack some in the future?
            LJ::item_toutf8($c_obj->journal, \$c_obj->{subject}, \$c_obj->{body}, $c_obj->{props});
        }

        $c_obj->{_loaded_text} = 1;
    }

    return 1;
}

sub _set_text {
    my ($self, %opts) = @_;

    my $jtalkid = $self->jtalkid;
    die "can't set text on unsaved comment"
        unless $jtalkid;

    my %doing      = ();
    my %original   = ();
    my %compressed = ();

    foreach my $part (qw(subject body)) {
        next unless exists $opts{$part};

        $original{$part} = delete $opts{$part};
        die "$part is not utf-8" unless LJ::is_utf8($original{$part});

        $doing{$part}++;
        $compressed{$part} = LJ::text_compress($original{$part});
    }

    croak "must set either body or subject" unless %doing;

    # if the comment is unknown8bit, then we must be setting both subject and body,
    # else we'll have one side utf-8 and the other side unknown, but no metadata
    # capable of expressing "subject is unknown8bit, but not body".
    if ($self->prop('unknown8bit')) {
        die "Can't set text on unknown8bit comments unless both subject and body are specified"
            unless $doing{subject} && $doing{body};
    }

    my $journalu  = $self->journal;
    my $journalid = $self->journalid;

    # need to set new values in the database
    my $set_sql  = join(", ", map { "$_=?" } grep { $doing{$_} } qw(subject body));
    my @set_vals = map { $compressed{$_} } grep { $doing{$_} } qw(subject body);

    # update is okay here because we verified we have a jtalkid, presumably from this table
    # -- compressed versions of the text here
    $journalu->do("UPDATE talktext2 SET $set_sql WHERE journalid=? AND jtalkid=?",
                 undef, @set_vals, $journalid, $jtalkid);
    die $journalu->errstr if $journalu->err;

    # need to also update memcache
    # -- uncompressed versions here
    my $memkey = join(":", $journalu->clusterid, $journalid, $jtalkid);
    foreach my $part (qw(subject body)) {
        next unless $doing{$part};
        LJ::MemCache::set([$journalid, "talk$part:$memkey"], $original{$part});
    }

    # got this far in setting text, and we know we used to be unknown8bit, except the text
    # we just set was utf8, so clear the unknown8bit flag
    if ($self->prop('unknown8bit')) {
        # set to 0 instead of delete so we can find these records later
        $self->set_prop('unknown8bit', '0');

    }

    # if text is already loaded, then we can just set whatever we've modified in $self
    if ($doing{subject} && $doing{body}) {
        $self->{$_} = $original{$_} foreach qw(subject body);
        $self->{_loaded_text} = 1;
    } else {
        $self->{$_} = undef foreach qw(subject body);
        $self->{_loaded_text} = 0;
    }
    # otherwise _loaded_text=0 and we won't do any optimizations

    return 1;
}

sub set_subject {
    my ($self, $text) = @_;

    return $self->_set_text( subject => $text );
}

sub set_body {
    my ($self, $text) = @_;

    return $self->_set_text( body => $text );
}

sub set_subject_and_body {
    my ($self, $subject, $body) = @_;

    return $self->_set_text( subject => $subject, body => $body );
}

sub prop {
    my ($self, $prop) = @_;
    $self->_load_props unless $self->{_loaded_props};
    return $self->{props}{$prop};
}

sub set_prop {
    my ($self, $prop, $val) = @_;

    return $self->set_props($prop => $val);
}

# allows the caller to pass raw SQL to set a prop (e.g. UNIX_TIMESTAMP())
# do not use this if setting a value given by the user
sub set_prop_raw {
    my ($self, $prop, $val) = @_;

    return $self->set_props_raw($prop => $val);
}

sub delete_prop {
    my ($self, $prop) = @_;

    return $self->set_props($prop => undef);
}

sub props {
    my ($self, $prop) = @_;
    $self->_load_props unless $self->{_loaded_props};
    return $self->{props} || {};
}

sub _load_props {
    my $self = shift;
    return 1 if $self->{_loaded_props};

    # find singletons which don't already have text loaded
    my $journalid = $self->journalid;
    my @to_load = grep { $_->journalid == $journalid } $self->unloaded_prop_singletons;

    my $prop_ret = {};
    LJ::load_talk_props2($journalid, [ map { $_->jtalkid } @to_load ], $prop_ret);

    # iterate over comment objects to load and fill in their props members
    foreach my $c_obj (@to_load) {
        $c_obj->{props} = $prop_ret->{$c_obj->jtalkid} || {};
        $c_obj->{_loaded_props} = 1;
    }

    return 1;
}

sub set_props {
    my ($self, %props) = @_;

    # call this so that get_prop() calls below will be cached
    LJ::load_props("talk");

    my $set_raw = delete $props{_raw} ? 1 : 0;

    my $journalid = $self->journalid;
    my $journalu  = $self->journal;
    my $jtalkid   = $self->jtalkid;

    my @vals = ();
    my @to_del = ();
    my %tprops = ();
    my @prop_vals = ();
    foreach my $key (keys %props) {
        my $p = LJ::get_prop("talk", $key);
        next unless $p;

        my $val = $props{$key};

        # build lists for inserts and deletes, also update $self
        if (defined $val) {
            if ($set_raw) {
                push @vals, ($journalid, $jtalkid, $p->{tpropid});
                push @prop_vals, $val;
                $tprops{$p->{tpropid}} = $key;
            } else {
                push @vals, ($journalid, $jtalkid, $p->{tpropid}, $val);
                $self->{props}->{$key} = $props{$key};
            }
        } else {
            push @to_del, $p->{tpropid};
            delete $self->{props}->{$key};
        }
    }

    if (@vals) {
        my $bind;
        if ($set_raw) {
            my @binds;
            foreach my $prop_val (@prop_vals) {
                push @binds, "(?,?,?,$prop_val)";
            }
            $bind = join(",", @binds);
        } else {
            $bind = join(",", map { "(?,?,?,?)" } 1..(@vals/4));
        }
        $journalu->do("REPLACE INTO talkprop2 (journalid, jtalkid, tpropid, value) ".
                      "VALUES $bind", undef, @vals);
        die $journalu->errstr if $journalu->err;

        # get the raw prop values back out of the database to store on the object
        if ($set_raw) {
            my $bind = join(",", map { "?" } keys %tprops);
            my $sth = $journalu->prepare("SELECT tpropid, value FROM talkprop2 WHERE journalid = ? AND jtalkid = ? AND tpropid IN ($bind)");
            $sth->execute($journalid, $jtalkid, keys %tprops);

            while (my $row = $sth->fetchrow_hashref) {
                my $tpropid = $row->{tpropid};
                $self->{props}->{$tprops{$tpropid}} = $row->{value};
            }
        }

        if ($LJ::_T_COMMENT_SET_PROPS_INSERT) {
            $LJ::_T_COMMENT_SET_PROPS_INSERT->();
        }
    }

    if (@to_del) {
        my $bind = join(",", map { "?" } @to_del);
        $journalu->do("DELETE FROM talkprop2 WHERE journalid=? AND jtalkid=? AND tpropid IN ($bind)",
                      undef, $journalid, $jtalkid, @to_del);
        die $journalu->errstr if $journalu->err;

        if ($LJ::_T_COMMENT_SET_PROPS_DELETE) {
            $LJ::_T_COMMENT_SET_PROPS_DELETE->();
        }
    }

    if (@vals || @to_del) {
        LJ::MemCache::delete([$journalid, "talkprop:$journalid:$jtalkid"]);
    }

    return 1;
}

sub set_props_raw {
    my ($self, %props) = @_;

    return $self->set_props(%props, _raw => 1);
}

# raw utf8 text, with no HTML cleaning
sub subject_raw {
    my $self = shift;
    $self->_load_text  unless $self->{_loaded_text};
    return $self->{subject};
}

# raw text as user sent us, without transcoding while correcting for unknown8bit
sub subject_orig {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return $self->{subject_orig} || $self->{subject};
}

# raw utf8 text, with no HTML cleaning
sub body_raw {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};

    # die if we didn't load any body text
    die "Couldn't load body text" unless $self->{_loaded_text};

    return $self->{body};
}

# raw text as user sent us, without transcoding while correcting for unknown8bit
sub body_orig {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return $self->{body_orig} || $self->{body};
}

# comment body, cleaned
sub body_html {
    my $self = shift;

    my $opts;
    $opts->{preformatted} = $self->prop("opt_preformatted");
    $opts->{anon_comment} = $self->poster ? 0 : 1;

    my $body = $self->body_raw;
    LJ::CleanHTML::clean_comment(\$body, $opts) if $body;
    return $body;
}

# comment body, plaintext
sub body_text {
    my $self = shift;

    my $body = $self->body_html;
    return LJ::strip_html($body);
}

sub subject_html {
    my $self = shift;
    $self->_load_text unless $self->{_loaded_text};
    return LJ::ehtml($self->{subject});
}

sub subject_text {
    my $self = shift;
    my $subject = $self->subject_raw;
    return LJ::ehtml($subject);
}

sub state {
    my $self = shift;
    __PACKAGE__->preload_rows([ $self->unloaded_singletons] );
    return $self->{state};
}


sub is_active {
    my $self = shift;
    return $self->state eq 'A' ? 1 : 0;
}

sub is_screened {
    my $self = shift;
    return $self->state eq 'S' ? 1 : 0;
}

sub is_deleted {
    my $self = shift;
    return $self->state eq 'D' ? 1 : 0;
}

sub is_frozen {
    my $self = shift;
    return $self->state eq 'F' ? 1 : 0;
}

sub visible_to {
    my ($self, $u) = @_;

    return 0 unless $self->entry && $self->entry->visible_to($u);

    # screened comment
    return 0 if $self->is_screened &&
                !( LJ::can_manage($u, $self->journal)           # owns the journal
                   || LJ::u_equals($u, $self->poster)           # posted the comment
                   || LJ::u_equals($u, $self->entry->poster )); # posted the entry

    # comments from suspended users aren't visible
    return 0 if $self->poster && $self->poster->{statusvis} eq 'S';

    return 1;
}

sub remote_can_delete {
    my $self = shift;

    my $remote = LJ::User->remote;
    return $self->user_can_delete($remote);
}

sub user_can_delete {
    my $self = shift;
    my $targetu = shift;
    return 0 unless LJ::isu($targetu);

    my $journalu = $self->journal;
    my $posteru  = $self->poster;
    my $poster   = $posteru ? $posteru->{user} : undef;

    return LJ::Talk::can_delete($targetu, $journalu, $posteru, $poster);
}

sub remote_can_edit {
    my $self = shift;
    my $errref = shift;

    my $remote = LJ::get_remote();
    return $self->user_can_edit($remote, $errref);
}

sub user_can_edit {
    my $self = shift;
    my $u = shift;
    my $errref = shift;

    return 0 unless $u;

    $$errref = LJ::Lang::ml('talk.error.cantedit.invalid');
    return 0 unless $self && $self->valid;

    # comment editing must be enabled and the user must have the cap
    $$errref = LJ::Lang::ml('talk.error.cantedit');
    return 0 unless LJ::is_enabled("edit_comments");
    return 0 unless $u->get_cap("edit_comments");

    # entry cannot be suspended
    return 0 if $self->entry->is_suspended;

    # user must be the poster of the comment
    unless ($u->equals($self->poster)) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.notyours');
        return 0;
    }

    # user cannot be read-only
    return 0 if $u->is_readonly;

    my $journal = $self->journal;

    # journal owner must have commenting enabled
    if ($journal->prop('opt_showtalklinks') eq "N") {
        $$errref = LJ::Lang::ml('talk.error.cantedit.commentingdisabled');
        return 0;
    }

    # user cannot be banned from commenting
    if ($journal->has_banned($u)) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.banned');
        return 0;
    }

    # user must be a friend if friends-only commenting is on
    if ($journal->prop('opt_whocanreply') eq "friends" && !$journal->trusts_or_has_member( $u )) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.notfriend');
        return 0;
    }

    # comment cannot have any replies
    if ($self->has_children) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.haschildren');
        return 0;
    }

    # comment cannot be deleted
    if ($self->is_deleted) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.isdeleted');
        return 0;
    }

    # comment cannot be frozen
    if ($self->is_frozen) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.isfrozen');
        return 0;
    }

    # comment must be visible to the user
    unless ($self->visible_to($u)) {
        $$errref = LJ::Lang::ml('talk.error.cantedit.notvisible');
        return 0;
    }

    $$errref = "";
    return 1;
}

sub mark_as_spam {
    my $self = shift;
    LJ::Talk::mark_comment_as_spam($self->poster, $self->jtalkid)
}


# returns comment action buttons (screen, freeze, delete, etc...)
sub manage_buttons {
    my $self = shift;
    my $dtalkid = $self->dtalkid;
    my $journal = $self->journal;
    my $jargent = "journal=$journal->{'user'}&amp;";

    my $remote = LJ::get_remote() or return '';

    my $managebtns = '';

    return '' unless $self->entry->poster;

    my $poster = $self->poster ? $self->poster->user : "";

    if ($self->remote_can_edit) {
        $managebtns .= "<a href='" . $self->edit_url . "'>" . LJ::img("editcomment", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
    }

    if (LJ::Talk::can_delete($remote, $self->journal, $self->entry->poster, $poster)) {
        $managebtns .= "<a href='$LJ::SITEROOT/delcomment.bml?${jargent}id=$dtalkid'>" . LJ::img("btn_del", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
    }

    if (LJ::Talk::can_freeze($remote, $self->journal, $self->entry->poster, $poster)) {
        unless ($self->is_frozen) {
            $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=freeze&amp;${jargent}talkid=$dtalkid'>" . LJ::img("btn_freeze", "", { align => 'absmiddle', hspace => 2, vspace => }) . "</a>";
        } else {
            $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=unfreeze&amp;${jargent}talkid=$dtalkid'>" . LJ::img("btn_unfreeze", "", { align => 'absmiddle', hspace => 2, vspace => }) . "</a>";
        }
    }

    if (LJ::Talk::can_screen($remote, $self->journal, $self->entry->poster, $poster)) {
        unless ($self->is_screened) {
            $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=screen&amp;${jargent}talkid=$dtalkid'>" . LJ::img("btn_scr", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
        } else {
            $managebtns .= "<a href='$LJ::SITEROOT/talkscreen.bml?mode=unscreen&amp;${jargent}talkid=$dtalkid'>" . LJ::img("btn_unscr", "", { 'align' => 'absmiddle', 'hspace' => 2, 'vspace' => }) . "</a>";
        }
    }

    return $managebtns;
}

# returns info for javscript comment management
sub info {
    my $self = shift;
    my $remote = LJ::get_remote() or return;

    my %LJ_cmtinfo;
    $LJ_cmtinfo{'canAdmin'} = LJ::can_manage($remote, $self->journal);
    $LJ_cmtinfo{'journal'} = $self->journal->{user};
    $LJ_cmtinfo{'remote'} = $remote->{user};

    return \%LJ_cmtinfo;
}

sub indent {
    return LJ::Talk::Post::indent(@_);
}

sub blockquote {
    return LJ::Talk::Post::blockquote(@_);
}

# used for comment email notification headers
sub email_messageid {
    my $self = shift;
    return "<" . join("-", "comment", $self->journal->id, $self->dtalkid) . "\@$LJ::DOMAIN>";
}

my @_ml_strings_en = (
    'esn.journal_new_comment.subject',                                          # 'Subject:',
    'esn.journal_new_comment.message',                                          # 'Message',

    'esn.screened',                                                             # 'This comment was screened.',
    'esn.you_must_unscreen',                                                    # 'You must respond to it or unscreen it before others can see it.',
    'esn.someone_must_unscreen',                                                # 'Someone else must unscreen it before you can reply to it.',
    'esn.here_you_can',                                                         # 'From here, you can:',

    'esn.view_thread',                                                          # '[[openlink]]View the thread[[closelink]] starting from this comment',
    'esn.view_comments',                                                        # '[[openlink]]View all comments[[closelink]] to this entry',
    'esn.reply_at_webpage',                                                     # '[[openlink]]Reply[[closelink]] at the webpage',
    'esn.unscreen_comment',                                                     # '[[openlink]]Unscreen the comment[[closelink]]',
    'esn.delete_comment',                                                       # '[[openlink]]Delete the comment[[closelink]]',
    'esn.edit_comment',                                                         # '[[openlink]]Edit the comment[[closelink]]',
    'esn.if_suport_form',                                                       # 'If your mail client supports it, you can also reply here:',

    'esn.journal_new_comment.anonymous.comment',                                # 'Their reply was:',
    'esn.journal_new_comment.anonymous.reply_to.anonymous_comment.to_your_post',# 'Somebody replied to another comment somebody left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.anonymous.reply_to.user_comment.to_your_post',     # 'Somebody replied to another comment [[pwho]] left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.anonymous.reply_to.your_comment.to_post',          # 'Somebody replied to another comment you left in [[openlink]]a LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.anonymous.reply_to.your_comment.to_your_post',     # 'Somebody replied to another comment you left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.anonymous.reply_to.your_post',                     # 'Somebody replied to [[openlink]]your LiveJournal post[[closelink]] in which you said:',

    'esn.journal_new_comment.user.comment',                                     # 'Their reply was:',
    'esn.journal_new_comment.user.edit_reply_to.anonymous_comment.to_your_post',# '[[who]] edited a reply to another comment somebody left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.edit_reply_to.user_comment.to_your_post',     # '[[who]] edited a reply to another comment [[pwho]] left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.edit_reply_to.your_comment.to_post',          # '[[who]] edited a reply to another comment you left in [[openlink]]a LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.edit_reply_to.your_comment.to_your_post',     # '[[who]] edited a reply to another comment you left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.edit_reply_to.your_post',                     # '[[who]] edited a reply to [[openlink]]your LiveJournal post[[closelink]] in which you said:',
    'esn.journal_new_comment.user.new_comment',                                 # 'Their new reply was:',

    'esn.journal_new_comment.user.reply_to.anonymous_comment.to_your_post',     # '[[who]] replied to another comment somebody left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.reply_to.user_comment.to_your_post',          # '[[who]] replied to another comment [[pwho]] left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.reply_to.your_comment.to_post',               # '[[who]] replied to another comment you left in [[openlink]]a LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.reply_to.your_comment.to_your_post',          # '[[who]] replied to another comment you left in [[openlink]]your LiveJournal post[[closelink]]. The comment they replied to was:',
    'esn.journal_new_comment.user.reply_to.your_post',                          # '[[who]] replied to [[openlink]]your LiveJournal post[[closelink]] in which you said:',

    'esn.journal_new_comment.you.edit_reply_to.anonymous_comment.to_post',      # 'You edited a reply to another comment somebody left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.anonymous_comment.to_your_post', # 'You edited a reply to another comment somebody left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.post',                           # 'You edited a reply to [[openlink]]a LiveJournal post[[closelink]] in which [[pwho]] said:',
    'esn.journal_new_comment.you.edit_reply_to.user_comment.to_post',           # 'You edited a reply to another comment [[pwho]] left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.user_comment.to_your_post',      # 'You edited a reply to another comment [[pwho]] left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.your_comment.to_post',           # 'You edited a reply to another comment you left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.your_comment.to_your_post',      # 'You edited a reply to another comment you left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.edit_reply_to.your_post',                      # 'You edited a reply to [[openlink]]your LiveJournal post[[closelink]] in which you said:',

    'esn.journal_new_comment.you.reply_to.anonymous_comment.to_post',           # 'You replied to another comment somebody left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.anonymous_comment.to_your_post',      # 'You replied to another comment somebody left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.post',                                # 'You replied to [[openlink]]a LiveJournal post[[closelink]] in which [[pwho]] said:',
    'esn.journal_new_comment.you.reply_to.user_comment.to_post',                # 'You replied to another comment [[pwho]] left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.user_comment.to_your_post',           # 'You replied to another comment [[pwho]] left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.your_comment.to_post',                # 'You replied to another comment you left in [[openlink]]a LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.your_comment.to_your_post',           # 'You replied to another comment you left in [[openlink]]your LiveJournal post[[closelink]]. The comment you replied to was:',
    'esn.journal_new_comment.you.reply_to.your_post',                           # 'You replied to [[openlink]]your LiveJournal post[[closelink]] in which you said:',

    'esn.journal_new_comment.your.comment',                                     # 'Your reply was:',
    'esn.journal_new_comment.your.new_comment',                                 # 'Your new reply was:',
);

# Implementation for both format_text_mail and format_html_mail.
sub _format_mail_both {
    my $self = shift;
    my $targetu = shift;
    my $is_html = shift;

    my $parent  = $self->parent;
    my $entry   = $self->entry;
    my $posteru = $self->poster;
    my $edited  = $self->is_edited;

    my $who = ''; # Empty means anonymous

    my ($k_who, $k_what, $k_reply_edit);
    if ($posteru) {
        if ($posteru->{name} eq $posteru->display_username) {
            if ($is_html) {
                my $profile_url = $posteru->profile_url;
                $who = " <a href=\"$profile_url\">" . $posteru->display_username . "</a>";
            } else {
                $who = $posteru->display_username;
            }
        } else {
            if ($is_html) {
                my $profile_url = $posteru->profile_url;
                $who = LJ::ehtml($posteru->{name}) .
                    " (<a href=\"$profile_url\">" . $posteru->display_username . "</a>)";
            } else {
                $who = $posteru->{name} . " (" . $posteru->display_username . ")";
            }
        }
        if (LJ::u_equals($targetu, $posteru)) {
            if ($edited) {
                # 'You edit your comment to...';
                $k_who = 'you.edit_reply_to';
                $k_reply_edit = 'your.new_comment';
            } else {
                # 'You replied to...'
                $k_who = 'you.reply_to';
                $k_reply_edit = 'your.comment';
            }
        } else {
            if ($edited) {
                # 'LJ-user ' . $posteru->{name} . ' edit reply to...';
                $k_who = 'user.edit_reply_to';
                $k_reply_edit = 'user.new_comment';
            } else {
                # 'LJ-user ' . $posteru->{name} . ' replied to...';
                $k_who = 'user.reply_to';
                $k_reply_edit = 'user.comment';
            }
        }
    } else {
        # 'Somebody replied to';
        $k_who = 'anonymous.reply_to';
        $k_reply_edit = 'anonymous.comment';
    }

    # Parent post author. Empty string means 'You'.
    my $parentu = $entry->journal;
    my $pwho = ''; #author of the commented post/comment. If empty - it's you or anonymous

    if ($is_html) {
        if (! $parent && ! LJ::u_equals($parentu, $targetu)) {
            # comment to a post and e-mail is going to be sent to not-AUTHOR of the journal
            my $p_profile_url = $entry->poster->profile_url;
            # pwho - author of the post
            # If the user's name hasn't been set (it's the same as display_username), then
            # don't display both
            if ($entry->poster->{name} eq $entry->poster->display_username) {
                $pwho = "<a href=\"$p_profile_url\">" . $entry->poster->display_username . "</a>";
            } else {
                $pwho = LJ::ehtml($entry->poster->{name}) .
                    " (<a href=\"$p_profile_url\">" . $entry->poster->display_username . "</a>)";
            }
        } elsif ($parent) {
            my $threadu = $parent->poster;
            if ($threadu && ! LJ::u_equals($threadu, $targetu)) {
                my $p_profile_url = $threadu->profile_url;
                if ($threadu->{name} eq $threadu->display_username) {
                    $pwho = "<a href=\"$p_profile_url\">" . $threadu->display_username . "</a>";
                } else {
                    $pwho = LJ::ehtml($threadu->{name}) .
                        " (<a href=\"$p_profile_url\">" . $threadu->display_username . "</a>)";
                }
            }
        }
    } else {
        if (! $parent && ! LJ::u_equals($parentu, $targetu)) {
            if ($entry->poster->{name} eq $entry->poster->display_username) {
                $pwho = $entry->poster->display_username;
            } else {
                $pwho = $entry->poster->{name} .
                    " (" . $entry->poster->display_username . ")";
            }
        } elsif ($parent) {
            my $threadu = $parent->poster;
            if ($threadu && ! LJ::u_equals($threadu, $targetu)) {
                if ($threadu->{name} eq $threadu->display_username) {
                    $pwho = $threadu->display_username;
                } else {
                    $pwho = $threadu->{name} .
                        " (" . $threadu->display_username . ")";
                }
            }
        }
    }

    # ESN directed to comment poster
    if (LJ::u_equals($targetu, $self->poster)) {
        # ->parent returns undef/0 if parent is an entry.
        if ($parent) {
            if ($pwho) {
                # '... a comment ' . $pwho . ' left in post.';
                $k_what = 'user_comment';
            } else {
                # '... a comment you left in post.';
                if($parent->poster) {
                    $k_what = 'your_comment';
                } else {
                    $k_what = 'anonymous_comment';
                }
            }
            if (LJ::u_equals($targetu, $entry->journal)) {
                $k_what .= '.to_your_post';
            } else {
                $k_what .= '.to_post';
            }
        } else {
            if ($pwho) {
                $k_what = 'post';
            } else {
                $k_what = 'your_post';
            }
        }
    # ESN directed to entry author
    } elsif (LJ::u_equals($targetu, $entry->journal)) {
        if ($parent) {
            if ($pwho) {
                # '... another comment ' . $pwho . ' left in your post.';
                $k_what = 'user_comment.to_your_post';
            } else {
                if($parent->poster) {
                    $k_what = 'your_comment.to_your_post';
                } else {
                    # '... another comment you left in your post.';
                    $k_what = 'anonymous_comment.to_your_post';
                }
            }
        } else {
            $k_what = 'your_post';
        }
    # ESN directed to author parent comment or post
    } else {
        if ($parent) {
            if($parent->poster) {
                if ($pwho) {
                    $k_what = 'user_comment.to_post';
                }
                else {
                    $k_what = 'your_comment.to_post';
                }
            } else {
                # '... another comment you left in your post.';
                $k_what = 'anonymous_comment.to_post';
            }
        } else {
            if ($pwho) {
                $k_what = 'post';
            }
            else {
                $k_what = 'your_post';
            }
        }
    }

    my $encoding = $targetu->mailencoding;
    my $charset  = $encoding ? "; charset=$encoding" : "";

    # Precache text lines
    my $lang     = $targetu->prop('browselang');
    LJ::Lang::get_text_multi($lang, undef, \@_ml_strings_en);

    my $body = '';
    $body = "<head><meta http-equiv=\"Content-Type\" content=\"text/html$charset\" /></head><body>"
        if $is_html;

    my $vars = {
        who             => $who,
        pwho            => $pwho,
        sitenameshort   => $LJ::SITENAMESHORT
    };

    # make hyperlinks for post
    my $talkurl = $entry->url;
    if ($is_html) {
        $vars->{openlink}  = "<a href=\"$talkurl\">";
        $vars->{closelink} = "</a>";
    } else {
        $vars->{openlink}  = '';
        $vars->{closelink} = " ($talkurl)";
    }

    my $ml_prefix = "esn.journal_new_comment.";
    $k_who = $ml_prefix . $k_who;
    $k_reply_edit = $ml_prefix . $k_reply_edit;

    my $intro = LJ::Lang::get_text($lang, $k_who . '.' . $k_what, undef, $vars);

    if ($is_html) {
        my $pichtml;
        my $pic_kw = $self->prop('picture_keyword');

        if ($posteru && $posteru->{defaultpicid} || $pic_kw) {
            my $pic = $pic_kw ? LJ::get_pic_from_keyword($posteru, $pic_kw) : undef;
            my $picid = $pic ? $pic->{picid} : $posteru->{defaultpicid};
            unless ($pic) {
                my %pics;
                LJ::load_userpics(\%pics, [ $posteru, $posteru->{defaultpicid} ]);
                $pic = $pics{$picid};
                # load_userpics doesn't return picid, but we rely on it above
                $picid = $picid;
            }
            if ($pic) {
                $pichtml = "<img src=\"$LJ::USERPIC_ROOT/$picid/$pic->{userid}\" align='absmiddle' ".
                    "width='$pic->{width}' height='$pic->{height}' ".
                    "hspace='1' vspace='2' alt='' /> ";
            }
        }

        if ($pichtml) {
            $body .= "<table><tr valign='top'><td>$pichtml</td><td width='100%'>$intro</td></tr></table>\n";
        } else {
            $body .= "<table><tr valign='top'><td width='100%'>$intro</td></tr></table>\n";
        }

        $body .= blockquote($parent ? $parent->body_html : $entry->event_html);
    } else {
        $body .= $intro . "\n\n" . indent($parent ? $parent->body_raw : $entry->event_raw, ">");
    }

    $body .= "\n\n" . LJ::Lang::get_text($lang, $k_reply_edit, undef, $vars) . "\n\n";

    if ($is_html) {
        my $pics = LJ::Talk::get_subjecticons();
        my $icon = LJ::Talk::show_image($pics, $self->prop('subjecticon'));

        my $heading;
        if ($self->subject_raw) {
            $heading = "<b>" . LJ::Lang::get_text($lang, $ml_prefix . 'subject', undef) . "</b> " . $self->subject_html;
        }
        $heading .= $icon;
        $heading .= "<br />" if $heading;
        # this needs to be one string so blockquote handles it properly.
        $body .= blockquote("$heading" . $self->body_html);

        $body .= "<br />";
    } else {
        if (my $subj = $self->subject_raw) {
            $body .= Text::Wrap::wrap(" " . LJ::Lang::get_text($lang, $ml_prefix . 'subject', undef) . " ", "", $subj) . "\n\n";
        }
        $body .= indent($self->body_raw) . "\n\n";

        # Don't wrap options, only text.
        $body = Text::Wrap::wrap("", "", $body) . "\n";
    }

    my $can_unscreen = $self->is_screened &&
                       LJ::Talk::can_unscreen($targetu, $entry->journal, $entry->poster,
                                              $posteru ? $posteru->{user} : undef);

    if ($self->is_screened) {
        $body .= LJ::Lang::get_text($lang, 'esn.screened', undef) .
            LJ::Lang::get_text($lang, $can_unscreen ? 'esn.you_must_unscreen' : 'esn.someone_must_unscreen', undef) .
            "\n";
    }

    $body .= LJ::Lang::get_text($lang, 'esn.here_you_can', undef, $vars);
    $body .= LJ::Event::format_options(undef, $is_html, $lang, $vars,
        {
            'esn.view_thread'       => [ 1, $self->thread_url ],
            'esn.view_comments'     => [ 2, $talkurl ],
            'esn.reply_at_webpage'  => [ 3, $self->reply_url ],
            'esn.unscreen_comment'  => [ $can_unscreen ? 4 : 0, $self->unscreen_url ],
            'esn.delete_comment'    => [ $self->user_can_delete($targetu) ? 5 : 0, $self->delete_url ],
            'esn.edit_comment'      => [ $self->user_can_edit($targetu) ? 6 : 0, $self->edit_url ],
        });

    my $want_form = $is_html && ($self->is_active || $can_unscreen);  # this should probably be a preference, or maybe just always off.
    if ($want_form) {
        $body .= LJ::Lang::get_text($lang, 'esn.if_suport_form', undef) . "\n";
        $body .= "<blockquote><form method='post' target='ljreply' action=\"$LJ::SITEROOT/talkpost_do.bml\">\n";

        $body .= LJ::html_hidden
            ( usertype     =>  "user",
              parenttalkid =>  $self->jtalkid,
              itemid       =>  $entry->ditemid,
              journal      =>  $entry->journal->{user},
              userpost     =>  $targetu->{user},
              ecphash      =>  LJ::Talk::ecphash($entry->jitemid, $self->jtalkid, $targetu->password)
              );

        $body .= "<input type='hidden' name='encoding' value='$encoding' />" unless $encoding eq "UTF-8";
        my $newsub = $self->subject_html($targetu);
        unless (!$newsub || $newsub =~ /^Re:/) { $newsub = "Re: $newsub"; }
        $body .= "<b>".LJ::Lang::get_text($lang, $ml_prefix . 'subject', undef)."</b> <input name='subject' size='40' value=\"" . LJ::ehtml($newsub) . "\" />";
        $body .= "<p><b>".LJ::Lang::get_text($lang, $ml_prefix . 'message', undef, $vars)."</b><br /><textarea rows='10' cols='50' wrap='soft' name='body'></textarea>";
        $body .= "<br /><input type='submit' value='" . LJ::Lang::get_text($lang, $ml_prefix . 'post_reply', undef) . "' />";
        $body .= "</form></blockquote>\n";
    }

    $body .= "</body>\n" if $is_html;

    return $body;
}

sub format_text_mail {
    my $self = shift;
    my $targetu = shift;
    croak "invalid targetu passed to format_text_mail"
        unless LJ::isu($targetu);

    return _format_mail_both($self, $targetu, 0);
}

sub format_html_mail {
    my $self = shift;
    my $targetu = shift;
    croak "invalid targetu passed to format_html_mail"
        unless LJ::isu($targetu);

    return _format_mail_both($self, $targetu, 1);
}

# Collects common comment's props,
# and passes them into the given template
sub _format_template_mail {
    my $self    = shift;           # comment
    my $targetu = shift;           # target user, who should be notified about the comment
    my $t       = shift;           # LJ::HTML::Template object - template of the notification e-mail
    croak "invalid targetu passed to format_template_mail"
        unless LJ::isu($targetu);

    my $parent  = $self->parent || $self->entry;
    my $entry   = $self->entry;
    my $posteru = $self->poster;

    my $encoding     = $targetu->mailencoding || 'UTF-8';
    my $can_unscreen = $self->is_screened &&
                       LJ::Talk::can_unscreen($targetu, $entry->journal, $entry->poster, $posteru ? $posteru->username : undef);

    # set template vars
    $t->param(encoding => $encoding);

    #   comment data
    $t->param(parent_userpic     => ($parent->userpic) ? $parent->userpic->imgtag : '');
    $t->param(parent_profile_url => $parent->poster->profile_url);
    $t->param(parent_username    => $parent->poster->username);
    $t->param(poster_userpic     => ($self->userpic) ? $self->userpic->imgtag : '' );
    $t->param(poster_profile_url => $self->poster->profile_url);
    $t->param(poster_username    => $self->poster->username);

    #   manage comment
    $t->param(thread_url    => $self->thread_url);
    $t->param(entry_url     => $self->entry->url);
    $t->param(reply_url     => $self->reply_url);
    $t->param(unscreen_url  => $self->unscreen_url) if $can_unscreen;
    $t->param(delete_url    => $self->delete_url) if $self->user_can_delete($targetu);
    $t->param(want_form     => ($self->is_active || $can_unscreen));
    $t->param(form_action   => "$LJ::SITEROOT/talkpost_do.bml");
    $t->param(hidden_fields => LJ::html_hidden
                                    ( usertype     =>  "user",
                                      parenttalkid =>  $self->jtalkid,
                                      itemid       =>  $entry->ditemid,
                                      journal      =>  $entry->journal->username,
                                      userpost     =>  $targetu->username,
                                      ecphash      =>  LJ::Talk::ecphash($entry->jitemid, $self->jtalkid, $targetu->password)
                                      ) .
                               ($encoding ne "UTF-8" ?
                                    LJ::html_hidden(encoding => $encoding):
                                    ''
                               )
             );

    $t->param(jtalkid           => $self->jtalkid);
    $t->param(dtalkid           => $self->dtalkid);
    $t->param(ditemid           => $entry->ditemid);
    $t->param(journal_username  => $entry->journal->username);
    if ($self->parent) {
      $t->param(parent_jtalkid         => $self->parent->jtalkid);
      $t->param(parent_dtalkid         => $self->parent->dtalkid);
    }

}

# Processes template for HTML e-mail notifications
# and returns the result of template processing.
sub format_template_html_mail {
    my $self    = shift;           # comment
    my $targetu = shift;           # target user, who should be notified about the comment
    my $t       = shift;           # LJ::HTML::Template object - template of the notification e-mail

    my $parent  = $self->parent || $self->entry;

    $self->_format_template_mail($targetu, $t);

    # add specific for HTML params
    $t->param(parent_text        => LJ::Talk::Post::blockquote($parent->body_html));
    $t->param(poster_text        => LJ::Talk::Post::blockquote($self->body_html));

    my $email_subject = $self->subject_html;
    $email_subject = "Re: $email_subject" if $email_subject and $email_subject !~ /^Re:/;
    $t->param(email_subject => $email_subject);

    # parse template and return it
    return $t->output; 
}

# Processes template for PLAIN-TEXT e-mail notifications
# and returns the result of template processing.
sub format_template_text_mail {
    my $self    = shift;           # comment
    my $targetu = shift;           # target user, who should be notified about the comment
    my $t       = shift;           # LJ::HTML::Template object - template of the notification e-mail

    my $parent  = $self->parent || $self->entry;

    $self->_format_template_mail($targetu, $t);

    # add specific for PLAIN-TEXT params
    $t->param(parent_text        => $parent->body_raw);
    $t->param(poster_text        => $self->body_raw);

    my $email_subject = $self->subject_raw;
    $email_subject = "Re: $email_subject" if $email_subject and $email_subject !~ /^Re:/;
    $t->param(email_subject => $email_subject);

    # parse template and return it
    return $t->output; 
}

sub delete {
    my $self = shift;

    return LJ::Talk::delete_comment
        ( $self->journal,
          $self->nodeid, # jitemid
          $self->jtalkid, 
          $self->state );
}

sub delete_thread {
    my $self = shift;

    return LJ::Talk::delete_thread
        ( $self->journal,
          $self->nodeid, # jitemid
          $self->jtalkid );
}

#
# Returns true if passed text is a spam.
#
# Class method.
#   LJ::Comment->is_text_spam( $some_text );
#
sub is_text_spam($\$) {
    my $class = shift;

    # REF on text
    my $ref   = shift; 
       $ref   = \$ref unless ref ($ref) eq 'SCALAR';
    
    my $plain = $$ref; # otherwise we modify the source text
       $plain = LJ::CleanHTML::clean_comment(\$plain);

    foreach my $re ($LJ::TALK_ABORT_REGEXP, @LJ::TALKSPAM){
        return 1 # spam
            if $re and ($plain =~ /$re/ or $$ref =~ /$re/);
    }
    
    return 0; # normal text
}

# returns a LJ::Userpic object for the poster of the comment, or undef
# it will unify interface between Entry and Comment: $foo->userpic will
# work correctly for both Entry and Comment objects
sub userpic {
    my $self = shift;

    my $up = $self->poster;
    return unless $up;

    my $key = $self->prop('picture_keyword');

    # return the picture from keyword, if defined
    my $picid = LJ::get_picid_from_keyword($up, $key);
    return LJ::Userpic->new($up, $picid) if $picid;

    # else return poster's default userpic
    return $up->userpic;
}

sub poster_ip {
    my $self = shift;

    return $self->prop("poster_ip");
}

# sets the new poster IP and returns the value that was set
sub set_poster_ip {
    my $self = shift;

    return "" unless LJ::is_web_context();

    my $current_ip = $self->poster_ip;

    my $new_ip = BML::get_remote_ip();
    my $forwarded = BML::get_client_header('X-Forwarded-For');
    $new_ip = "$forwarded, via $new_ip" if $forwarded && $forwarded ne $new_ip;

    if (!$current_ip || $new_ip eq $current_ip) {
        $self->set_prop( poster_ip => $new_ip );
        return $new_ip;
    }

    if ($current_ip =~ /\(originally ([\w\.]+)\)/) {
        if ($new_ip eq $1) {
            $self->set_prop( poster_ip => $new_ip );
            return $new_ip;
        }

        $new_ip = "$new_ip (originally $1)";
    } else {
        $new_ip = "$new_ip (originally $current_ip)";
    }

    $self->set_prop( poster_ip => $new_ip );
    return $new_ip;
}

sub edit_time {
    my $self = shift;

    return $self->prop("edit_time");
}

sub is_edited {
    my $self = shift;

    return $self->edit_time ? 1 : 0;
}

1;
