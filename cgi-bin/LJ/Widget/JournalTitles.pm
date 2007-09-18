package LJ::Widget::JournalTitles;

use strict;
use base qw(LJ::Widget);
use Carp qw(croak);

sub ajax { 1 }
sub authas { 1 }
sub need_res { qw( stc/widgets/journaltitles.css ) }

sub render_body {
    my $class = shift;
    my %opts = @_;

    my $u = $class->get_effective_remote();
    die "Invalid user." unless LJ::isu($u);

    my $ret;
    $ret .= "<h2 class='widget-header'>" . $class->ml('widget.journaltitles.title') . "</h2>";
    $ret .= "<div class='theme-titles-content'>";
    $ret .= "<p class='detail'>" . $class->ml('widget.journaltitles.desc') . " " . LJ::help_icon('journal_titles') . "</p>";

    foreach my $id (qw( journaltitle journalsubtitle friendspagetitle )) {
        $ret .= $class->start_form( id => "${id}_form" );

        $ret .= "<p>";
        $ret .= "<label>" . $class->ml("widget.journaltitles.$id") . "</label> ";
        $ret .= "<span id='${id}_view'>";
        $ret .= "<strong>" . $u->prop($id) . "</strong> ";
        $ret .= "<a href='' class='theme-title-control' id='${id}_edit'>" . $class->ml('widget.journaltitles.edit') . "</a>";
        $ret .= "</span>";

        $ret .= "<span id='${id}_modify'>";
        $ret .= $class->html_text(
            name => 'title_value',
            id => $id,
            value => $u->prop($id),
            size => '30',
            maxlength => LJ::std_max_length(),
            raw => "class='text'",
        ) . " ";
        $ret .= $class->html_hidden( which_title => $id );
        $ret .= $class->html_submit(
            save => $class->ml('widget.journaltitles.btn'),
            { raw => "id='save_btn_$id'" },
        ) . " ";
        $ret .= "<a href='' class='theme-title-control' id='${id}_cancel'>" . $class->ml('widget.journaltitles.cancel') . "</a>";
        $ret .= "</span></p>";

        $ret .= $class->end_form;
    }

    $ret .= "</div>";

    return $ret;
}

sub handle_post {
    my $class = shift;
    my $post = shift;
    my %opts = @_;

    my $u = $class->get_effective_remote();
    die "Invalid user." unless LJ::isu($u);

    my $eff_val = LJ::text_trim($post->{title_value}, 0, LJ::std_max_length());
    $eff_val = "" unless $eff_val;
    $u->set_prop($post->{which_title}, $eff_val);

    return;
}

sub js {
    q [
        initWidget: function () {
            var self = this;

            // store current field values
            self.journaltitle_value = $("journaltitle").value;
            self.journalsubtitle_value = $("journalsubtitle").value;
            self.friendspagetitle_value = $("friendspagetitle").value;

            // show view mode
            $("journaltitle_view").style.display = "inline";
            $("journalsubtitle_view").style.display = "inline";
            $("friendspagetitle_view").style.display = "inline";
            $("journaltitle_cancel").style.display = "inline";
            $("journalsubtitle_cancel").style.display = "inline";
            $("friendspagetitle_cancel").style.display = "inline";
            $("journaltitle_modify").style.display = "none";
            $("journalsubtitle_modify").style.display = "none";
            $("friendspagetitle_modify").style.display = "none";

            // set up edit links
            DOM.addEventListener($("journaltitle_edit"), "click", function (evt) { self.editTitle(evt, "journaltitle") });
            DOM.addEventListener($("journalsubtitle_edit"), "click", function (evt) { self.editTitle(evt, "journalsubtitle") });
            DOM.addEventListener($("friendspagetitle_edit"), "click", function (evt) { self.editTitle(evt, "friendspagetitle") });

            // set up cancel links
            DOM.addEventListener($("journaltitle_cancel"), "click", function (evt) { self.cancelTitle(evt, "journaltitle") });
            DOM.addEventListener($("journalsubtitle_cancel"), "click", function (evt) { self.cancelTitle(evt, "journalsubtitle") });
            DOM.addEventListener($("friendspagetitle_cancel"), "click", function (evt) { self.cancelTitle(evt, "friendspagetitle") });

            // set up save forms
            DOM.addEventListener($("journaltitle_form"), "submit", function (evt) { self.saveTitle(evt, "journaltitle") });
            DOM.addEventListener($("journalsubtitle_form"), "submit", function (evt) { self.saveTitle(evt, "journalsubtitle") });
            DOM.addEventListener($("friendspagetitle_form"), "submit", function (evt) { self.saveTitle(evt, "friendspagetitle") });
        },
        editTitle: function (evt, id) {
            $(id + "_modify").style.display = "inline";
            $(id + "_view").style.display = "none";

            // cancel any other titles that are being edited since
            // we only want one title in edit mode at a time
            if (id == "journaltitle") {
                this.cancelTitle(evt, "journalsubtitle");
                this.cancelTitle(evt, "friendspagetitle");
            } else if (id == "journalsubtitle") {
                this.cancelTitle(evt, "journaltitle");
                this.cancelTitle(evt, "friendspagetitle");
            } else if (id == "friendspagetitle") {
                this.cancelTitle(evt, "journaltitle");
                this.cancelTitle(evt, "journalsubtitle");
            }

            Event.stop(evt);
        },
        cancelTitle: function (evt, id) {
            $(id + "_modify").style.display = "none";
            $(id + "_view").style.display = "inline";

            // reset appropriate field to default
            if (id == "journaltitle") {
                $("journaltitle").value = this.journaltitle_value;
            } else if (id == "journalsubtitle") {
                $("journalsubtitle").value = this.journalsubtitle_value;
            } else if (id == "friendspagetitle") {
                $("friendspagetitle").value = this.friendspagetitle_value;
            }

            Event.stop(evt);
        },
        saveTitle: function (evt, id) {
            $("save_btn_" + id).disabled = true;

            this.doPostAndUpdateContent({
                which_title: id,
                title_value: $(id).value
            });

            Event.stop(evt);
        },
        onRefresh: function (data) {
            this.initWidget();
        }
    ];    
}

1;
