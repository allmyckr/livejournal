package LJ::HTML::Template;
use strict;

# Returns a new HTML::Template object
# with some redefined default values.
sub new {
    my $class = shift;
    my $opts = (ref $_[0]) ? shift : {};

    my %common_params = (
        'lj_siteroot'   => $LJ::SITEROOT,
        'lj_statprefix' => $LJ::STATPREFIX,
    );

    if ($opts->{'use_expr'}) {
        require HTML::Template::Pro; # load module on demand

        HTML::Template::Pro->register_function(
            ml => sub {
                my $key = shift;
                my %opts = @_;
                return LJ::Lang::ml($key, \%opts);
            },
            ehtml => sub {
                my $string = shift;
                return LJ::ehtml($string);
            },
            ejs => sub {
                my $string = shift;
                return LJ::ejs($string);
            },
        );

        my $template = HTML::Template::Pro->new(
            global_vars => 1, # normally variables declared outside a loop are not available inside
                              # a loop.  This option makes <TMPL_VAR>s like global variables in Perl
                              # - they have unlimited scope.
                              # This option also affects <TMPL_IF> and <TMPL_UNLESS>

            die_on_bad_params => 0, # if set to 0 the module will let you call
                                    # $template->param(param_name => 'value') even
                                    # if 'param_name' doesn't exist in the template body.
                                    # Defaults to 1.
            loop_context_vars => 1, # special loop variables: __first__, __last__, __odd__, __inner__, __counter__
            @_
        );

        $template->param(%common_params);

        return $template;
    } else {
        require HTML::Template; # load on demand
        my $template = HTML::Template->new(
            global_vars => 1, # normally variables declared outside a loop are not available inside
                              # a loop.  This option makes <TMPL_VAR>s like global variables in Perl
                              # - they have unlimited scope.
                              # This option also affects <TMPL_IF> and <TMPL_UNLESS>

            die_on_bad_params => 0, # if set to 0 the module will let you call
                                    # $template->param(param_name => 'value') even
                                    # if 'param_name' doesn't exist in the template body.
                                    # Defaults to 1.
            @_
        );

        $template->param(%common_params);

        return $template;
    }
}


1;
