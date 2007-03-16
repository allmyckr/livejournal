package LJ::Widget::QotD;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);
use Class::Autouse qw( LJ::QotD );

sub need_res {
    return qw( js/widgets/qotd.js stc/widgets/qotd.css );
}

sub render_body {
    my $class = shift;
    my %opts = @_;
    my $ret;

    my $skip = $opts{skip};
    my $remote = LJ::get_remote();

    my @questions = LJ::QotD->get_questions( skip => $skip );

    $ret .= "<h2>Question of the Day</h2>";
    $ret .= "<div class='qotd-controls'>";
    $ret .= "<img id='prev_questions' src='$LJ::IMGPREFIX/arrow-spotlight-prev.gif' alt='Previous' /> ";
    $ret .= "<img id='next_questions' src='$LJ::IMGPREFIX/arrow-spotlight-next.gif' alt='Next' />";
    $ret .= "</div>";
    $ret .= "<div id='all_questions'>";
    $ret .= $class->qotd_display( questions => \@questions );
    $ret .= "</div>";

    return $ret;
}

sub qotd_display {
    my $class = shift;
    my %opts = @_;

    my $questions = $opts{questions} || [];

    my $ret;
    if (@$questions) {
        $ret .= "<div class='qotd'>";
        foreach my $q (@$questions) {
            if ($q->{img_url}) {
                $ret .= "<div><img src='$q->{img_url}' /></div>";
            }
            $ret .= "<p>" . $q->{text} . " " . $class->answer_link($q) . "</p>";
        }
        $ret .= "</div>";
    }

    return $ret;
}

sub answer_link {
    my $class = shift;
    my $question = shift;
    my %opts = @_;
    my $ret;

    my $subject = LJ::eurl("Writer's Block");
    my $event = LJ::eurl($question->{text});
    my $url = "$LJ::SITEROOT/update.bml?subject=$subject&event=$event";

    $ret .= "(<a href=\"$url\">Answer</a>)";

    return $ret;
}

1;
