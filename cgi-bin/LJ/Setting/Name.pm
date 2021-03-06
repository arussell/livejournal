package LJ::Setting::Name;
use base 'LJ::Setting::TextSetting';
use strict;
use warnings;
use LJ::Constants;

sub tags { qw(name) }

sub current_value {
    my ($class, $u) = @_;
    return $u->{name} || "";
}

sub text_size { 40 }

sub question {
    my $class = shift;

    return $class->ml('.setting.name.question');
}

sub error_check {
    my ($class, $u, $args) = @_;
    my $val = $class->get_arg($args);

    # for testing:
    if ($LJ::T_FAKE_SETTINGS_RULES && $val =~ /\`bad/) {
        $class->errors("txt" => "T-FAKE-ERROR: bogus value");
    }

    unless (length $val) {
        $class->errors("txt" => "You must specify a name");
    }

    1;
}

sub save_text {
    my ($class, $u, $txt) = @_;
    $txt = LJ::trim($txt);
    $txt = LJ::text_trim($txt, LJ::BMAX_NAME, LJ::CMAX_NAME);
    return 0 unless LJ::update_user($u, { name => $txt });
    LJ::load_userid($u->{userid}, "force");
    return 1;
}

1;
