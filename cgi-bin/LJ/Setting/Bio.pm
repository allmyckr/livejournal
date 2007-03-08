package LJ::Setting::Bio;
use base 'LJ::Setting';
use strict;
use warnings;

sub tags { qw(bio biography about) }

sub as_html {
    my ($class, $u, $errs, $args) = @_;
    my $key = $class->pkgkey;
    my $ret;

    # load and clean bio
    my $saved_bio = $u->bio;
    LJ::text_out(\$saved_bio, "force");

    if (LJ::text_in($saved_bio)) {
        $ret .= "<label for='${key}bio'>" . $class->ml('.setting.bio.question') . "</label>";
        $ret .= "<p>" . $class->ml('.setting.bio.desc') . "</p>";
        $ret .= LJ::html_textarea({ 'name' => "${key}bio", 'id' => "${key}bio", 'class' => 'text', 'rows' => '10', 'cols' => '50',
                                    'wrap' => 'soft', 'value' => $saved_bio, 'style' => "width: 80%" }) . "<br />";
        $ret .= "<p class='detail'>" . $class->ml('.setting.bio.note') . "</p>";
    } else {
        $ret .= LJ::html_hidden("${key}bio_absent", 'yes');
        $ret .= "<?p <?inerr " . LJ::Lang::ml('/manage/profile/index.bml.error.invalidbio', {'aopts' => "href='$LJ::SITEROOT/utf8convert.bml'"}) . " inerr?> p?>";
    }
    $ret .= $class->errdiv($errs, "bio");

    return $ret;
}

sub error_check {
    my ($class, $u, $args) = @_;

    unless (LJ::text_in($class->get_arg($args, "bio"))) {
        $class->errors("bio" => $class->ml('.setting.bio.error.invalid'));
    }

    return 1;
}

sub save {
    my ($class, $u, $args) = @_;
    $class->error_check($u, $args);

    my $bio = $class->get_arg($args, "bio");
    my $bio_absent = $class->get_arg($args, "bio_absent");

    $u->set_bio($bio, $bio_absent);
}

1;
