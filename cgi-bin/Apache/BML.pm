#!/usr/bin/perl
#

package Apache::BML;

use strict;
use Apache::Constants qw(:common REDIRECT);
use Apache::File ();
use Apache::URI;
use CGI;                  # unused, but pre-loaded.
use Digest::MD5;

use vars qw($config @confdirs);   # loaded once
use vars qw($cur_req);    # current request hash
use vars qw($ML_GETTER);  # normally undef
use vars qw(%HOOK);
use vars qw(%Lang);       # iso639-2 2-letter lang code -> BML lang code
use vars qw(%CodeBlockOpts);
use vars qw(%FileModTime %FileBlockData %FileBlockFlags);

my (%CodeBlockMade);
my (%SchemeData, %SchemeFlags); # scheme -> key -> scalars (data has {s} blocks expanded)
my (%SchemeRefs);               # scheme -> key -> refs to %SchemeData scalars, OR scalars (from LOCALBLOCKS)

# load BML Config
{
    my $conf_file = $ENV{'BMLConfig'};
    $conf_file =~ s/\$(\w+)/$ENV{$1}/g;
    load_config($conf_file);

    my $err;
    foreach my $is (split(/\s*,\s*/, $config->{'/'}->{'VarInitScript'})) {
        unless (load_look_from_initscript($is, \$err)) {
            die "Error running VarInitScript ($is): $err\n";                
        }
    }
}

tie %BML::ML, 'BML::ML';

sub handler
{
    my $r = shift;
    my $file = $r->filename;

    unless (-e $r->finfo) {
        $r->log_error("File does not exist: $file");
        return NOT_FOUND;
    }

    unless (-r _) {
        $r->log_error("File permissions deny access: $file");
        return FORBIDDEN;
    }
  
    my $modtime = (stat _)[9];

    unless (open F, $file) {
        $r->log_error("Couldn't open $file for reading: $!");
        return SERVER_ERROR;
    }

    ### read the data to mangle
    my $bmlsource;
    { local $/ = undef; $bmlsource = <F>; }
    close F;

    # create new request
    my $req = $cur_req = {
        'r' => $r,
        'BlockStack' => [""],
        'scratch' => {},        # _CODE blocks can play
    };

    # consider the file's mod time
    note_mod_time($req, $modtime);

    # and all the config files:
    note_mod_time($req, $config->{'/'}->{'base_mod_time'});

    # setup env
    my $uri = $r->uri;
    foreach (@confdirs)
    {
        next unless $uri =~ /^$_/;
        foreach my $k (keys %{$config->{$_}}) {
            $req->{'env'}->{$k} = $config->{$_}->{$k};
        }
    }

    # setup cookies
    *BMLCodeBlock::COOKIE = *BML::COOKIE;
    %BML::COOKIE = ();
    foreach (split(/;\s+/, $r->header_in("Cookie"))) {
        next unless ($_ =~ /(.*)=(.*)/);
        $BML::COOKIE{BML::durl($1)} = BML::durl($2);
    }
    
    # tied interface to BML::ml();
    *BMLCodeBlock::ML = *BML::ML;

    # let BML code blocks see input
    %BMLCodeBlock::GET = ();
    %BMLCodeBlock::POST = ();
    %BMLCodeBlock::FORM = ();  # whatever request method is
    my %input_target = ( GET  => [ \%BMLCodeBlock::GET  ],
                         POST => [ \%BMLCodeBlock::POST ], );
    push @{$input_target{$r->method}}, \%BMLCodeBlock::FORM;
    foreach my $id ([ [ $r->args    ] => $input_target{'GET'}  ],
                    [ [ $r->content ] => $input_target{'POST'} ])
    {
        while (my ($k, $v) = splice @{$id->[0]}, 0, 2) {
            foreach my $dest (@{$id->[1]}) {
                $dest->{$k} .= "\0" if exists $dest->{$k};
                $dest->{$k} .= $v;
            }
        }
    }

    if ($HOOK{'startup'}) {
        eval {
            $HOOK{'startup'}->();
        };
        return report_error($r, "<b>Error running startup hook:</b><br />\n$@")
            if $@;
    }

    # global template file
    load_look($req, "", "global");
    
    # decide which scheme template file to use
    my $ideal_scheme = "";
    if ($r->header_in("User-Agent") =~ /^Lynx\//) {
        $ideal_scheme = "lynx";
    }

    $req->{'scheme'} = $req->{'env'}->{'ForceScheme'} || 
        $BML::COOKIE{'BMLschemepref'} || 
        $BMLCodeBlock::GET{'usescheme'} || 
        $ideal_scheme ||
        $req->{'env'}->{'DefaultScheme'};

    # to finish deciding, we have to load it to see if it exists:
    unless (load_look($req, $req->{'scheme'}, "generic")) {
        $req->{'scheme'} = $req->{'env'}->{'DefaultScheme'};
        load_look($req, $req->{'scheme'}, "generic");
    }

    # now we have to combine both of these (along with the VARINIT)
    # and then expand all the static stuff
    unless (exists $SchemeData{$req->{'scheme'}}) {
        my @files;
        push @files, "VARINIT" if $req->{'env'}->{'VarInitScript'};
        push @files, "$req->{'env'}->{'LookRoot'}/global.look";
        push @files, "$req->{'env'}->{'LookRoot'}/$req->{'scheme'}/generic.look";

        my $sd = $SchemeData{$req->{'scheme'}} = {};
        my $sf = $SchemeFlags{$req->{'scheme'}} = {};

        my @expandconstants;
        foreach my $file (@files) {
            foreach my $k (keys %{$FileBlockData{$file}}) {
                $sd->{$k} = $FileBlockData{$file}->{$k};
                $sf->{$k} = $FileBlockFlags{$file}->{$k};
            }
        }
        foreach my $k (keys %$sd) {
            next unless $sf->{$k} =~ /s/;
            $sd->{$k} =~ s/\(=([A-Z0-9\_]+?)=\)/$sd->{$1}/g;
        }
    }

    # now, this request needs a copy of (well, references to) the
    # data above.  can't use that directly, since it might
    # change using _INFO LOCALBLOCKS to declare new file-local blocks
    $req->{'blockflags'} = {
        '_INFO' => 'F', '_INCLUDE' => 'F',
    };
    foreach my $k (keys %{$SchemeData{$req->{'scheme'}}}) {
        $req->{'blockflags'}->{$k} = $SchemeFlags{$req->{'scheme'}}->{$k};
        $req->{'blockref'}->{$k} = \$SchemeData{$req->{'scheme'}}->{$k};
    }

    $req->{'lang'} = BML::decide_language();
    
    # print on the HTTP header
    my $html;
    bml_decode($req, \$bmlsource, \$html, { DO_CODE => $req->{'env'}->{'AllowCode'} });

    # redirect, if set previously
    if ($req->{'location'}) {
        $r->header_out(Location => $req->{'location'});
        return REDIRECT;
    }

    # insert all client (per-user, cookie-set) variables
    if ($req->{'env'}->{'UseBmlSession'}) {
        $html =~ s/%%c\!(\w+)%%/BML::ehtml(BML::get_var($1))/eg;
    }

    my $rootlang = substr($req->{'lang'}, 0, 2);
    unless ($req->{'env'}->{'NoHeaders'}) {
        $r->content_languages([ $rootlang ]);
    }

    my $modtime = modified_time($req);
    my $notmod = 0;

    my $content_type = $req->{'content_type'} ||
        $req->{'env'}->{'DefaultContentType'} ||
        "text/html";

    unless ($req->{'env'}->{'NoHeaders'}) 
    {
        if ($ENV{'HTTP_IF_MODIFIED_SINCE'} &&
            ! $req->{'env'}->{'NoCache'} &&
            $ENV{'HTTP_IF_MODIFIED_SINCE'} eq $modtime) 
        {
            print "Status: 304 Not Modified\n";
            $notmod = 1;
        }

        $r->content_type($content_type);

        if ($req->{'env'}->{'NoCache'}) {        
            $r->header_out("Cache-Control", "no-cache");
            $r->no_cache(1);
        }

        $r->header_out("Last-Modified", modified_time($req))
            if $req->{'env'}->{'Static'};
        $r->header_out("Cache-Control", "private, proxy-revalidate");
        $r->header_out("ETag", Digest::MD5::md5_hex($html));
    }
    
    $r->send_http_header();
    $r->print($html) unless $req->{'env'}->{'NoContent'} || $r->header_only;

    # clear the code package for next request if necessary
    $r->register_cleanup(\&reset_codeblock) if $req->{'didcode'};

    return OK;
}

sub report_error
{
    my $r = shift;
    my $err = shift;
    
    $r->content_type("text/html");
    $r->send_http_header();
    $r->print($err);

    return OK;  # TODO: something else?
}

sub load_config
{
    my $conf_file = shift;

    my ($currentpath, $var, $val);

    my $cfg = Apache::File->new($conf_file);

    die "Couldn't open BML config ($conf_file) for reading: $!"
        unless $cfg;

    $config = {};
    while (my $line = <$cfg>)
    {
        chomp $line;
        next if $line =~ /^\#/;
        if (($var, $val) = ($line =~ /^(\w+):?\s*(.*)/))
        {
            if ($var eq "Location") {
                $currentpath = $val;
            } else {
                # expand environment variables
                $val =~ s/\$(\w+)/$ENV{$1}/g;
                $config->{$currentpath}->{$var} = $val;
            }
        }
    }
    $cfg->close;

    grep { $config->{$_}->{'_size'} = length($_);  } keys %$config;
    @confdirs = sort { $config->{$a}->{'_size'} <=>
                       $config->{$b}->{'_size'} } keys %$config;

    return OK;
}

sub compile
{
    eval $_[0];
}

sub reset_codeblock
{
    no strict;
    local $^W = 0;
    my $package = "main::BMLCodeBlock::";
    *stab = *{"main::"};
    while ($package =~ /(\w+?::)/g)
    {
        *stab = ${stab}{$1};
    }
    while (my ($key,$val) = each(%stab))
    {
        return if $DB::signal;
        deleteglob ($key, $val);
    }
}

sub deleteglob
{
    no strict;
    return if $DB::signal;
    my ($key, $val, $all) = @_;
    local(*entry) = $val;
    my $fileno;
    if ($key !~ /^_</ and defined $entry)
    {
        undef $entry;
    }
    if ($key !~ /^_</ and defined @entry)
    {
        undef @entry;
    }
    if ($key ne "main::" && $key ne "DB::" && defined %entry
        && $key !~ /::$/
        && $key !~ /^_</ && !($package eq "dumpvar" and $key eq "stab"))
    {
        undef %entry;
    }
    if (defined ($fileno = fileno(*entry))) {
        # do nothing to filehandles?
    }
    if ($all) {
        if (defined &entry) {
                # do nothing to subs?
        }
    }
}

# $type - "THINGER" in the case of (=THINGER Whatever THINGER=)
# $data - "Whatever" in the case of (=THINGER Whatever THINGER=)
# $option_ref - hash ref to %BMLEnv
sub bml_block
{
    my ($req, $type, $data, $option_ref) = @_;
    my $realtype = $type;
    my $previous_block = $req->{'BlockStack'}->[-1];

    if (exists $req->{'blockref'}->{"$type/FOLLOW_${previous_block}"}) {
        $realtype = "$type/FOLLOW_${previous_block}";
    }

    my $blockflags = $req->{'blockflags'}->{$realtype};

    # trim off space from both sides of text data
    $data =~ s/^\s+//;
    $data =~ s/\s+$//;
    
    # executable perl code blocks
    if ($type eq "_CODE")
    {
        return inline_error("_CODE block failed to execute by permission settings")
            unless $option_ref->{'DO_CODE'};

        %CodeBlockOpts = ();

        my $Package = "BMLCodeBlock";
        my $need_compile;
        my $subpack;
        if ($data =~ /^\#BML:cache(:(\w+))?/) {
            $subpack = $2 || Digest::MD5::md5_hex($data);
            $Package = "BML::CodeBlock::$subpack";
            $need_compile = not $CodeBlockMade{$subpack};
        } else {
            $req->{'didcode'} = 1; # only reset this package; not cached ones.
            $need_compile = 1;
        }

        if ($need_compile) {
            compile(join('',
                         'package ',
                         $Package,
                         ';',
                         "no strict;",
                         "*ML = *BML::ML;",
                         "*COOKIE = *BML::COOKIE;",
                         "*GET = *BMLCodeBlock::GET;",
                         "*POST = *BMLCodeBlock::POST;",
                         "*FORM = *BMLCodeBlock::FORM;",
                         'sub handler {',
                         $data,
                         "\n}"));
            if ($@) { return "<B>[Error: $@]</B>"; }
            if ($subpack) { $CodeBlockMade{$subpack} = 1; }
        }
        
        my $cv = \&{"$Package\::handler"};
        my $ret = eval { &{$cv}($req, $req->{'scratch'}) };
        if ($@) { return "<B>[Error: $@]</B>"; }
        
        return $ret if $CodeBlockOpts{'raw'} or $ret eq "";

        my $newhtml;
        bml_decode($req, \$ret, \$newhtml, {});  # no opts on purpose: _CODE can't return _CODE
        return $newhtml;
    }

    # load in the properties defined in the data
    my %element = ();
    my @elements = ();
    if ($blockflags =~ /F/)
    {
        load_elements(\%element, $data, { 'declorder' => \@elements });
    } 
    elsif ($blockflags =~ /P/)
    {
        my @itm = split(/\s*\|\s*/, $data);
        my $ct = 0;
        foreach (@itm) {
            $ct++;
            $element{"DATA$ct"} = $_;
            push @elements, "DATA$ct";
        }
    }
    else
    {
        # single argument block (goes into DATA element)
        $element{'DATA'} = $data;
        push @elements, 'DATA';
    }
    
    # multi-linguality stuff
    if ($type eq "_ML")
    {
        return "[ml_getter not defined]" unless $ML_GETTER;
        my $code = $data;
        $code = $req->{'r'}->parsed_uri()->path() . $code
            if $code =~ /^\./;
        return $ML_GETTER->($req->{'lang'}, $code);
    }
        
    # an _INFO block contains special internal information, like which
    # look files to include
    if ($type eq "_INFO")
    {
        foreach (split(/\s*\,\s*/, trim($element{'INCLUDE'}))) {
            load_look($req, $req->{'scheme'}, $_);
        }
        if ($element{'PACKAGE'}) { $req->{'package'} = $element{'PACKAGE'}; }
        if ($element{'NOCACHE'}) { $req->{'env'}->{'NoCache'} = 1; }
        if ($element{'STATIC'}) { $req->{'env'}->{'Static'} = 1; }
        if ($element{'NOHEADERS'}) { $req->{'env'}->{'NoHeaders'} = 1; }
        if ($element{'NOCONTENT'}) { $req->{'env'}->{'NoContent'} = 1; }
#        if ($element{'NOFORMREAD'}) { $FORM_READ = 1; } # don't step on CGI.pm, if used
        if ($element{'LOCALBLOCKS'} && $req->{'env'}->{'AllowCode'}) {
            my (%localblock, %localflags);
            load_elements(\%localblock, $element{'LOCALBLOCKS'});
            # look for template types
            foreach my $k (keys %localblock) {
                if ($localblock{$k} =~ s/^\{([A-Za-z]+)\}//) {
                    $localflags{$k} = $1;
                }
            }
            my @expandconstants;
            foreach my $k (keys %localblock) {
                $req->{'blockref'}->{$k} = \$localblock{$k};
                $req->{'blockflags'}->{$k} = $localflags{$k};
                if ($localflags{$k} =~ /s/) { push @expandconstants, $k; }
            }
            foreach my $k (@expandconstants) {
                $localblock{$k} =~ s/\(=([A-Z0-9\_]+?)=\)/${$req->{'blockref'}->{$1}}/g;
            }
        }
        return "";
    }
    
    if ($type eq "_INCLUDE") 
    {
        my $code = 0;
        $code = 1 if ($element{'CODE'});
        foreach my $sec (qw(CODE BML)) {
            next unless $element{$sec};
            if ($req->{'IncludeStack'} && ! $req->{'IncludeStack'}->[-1]->{$sec}) {
                return inline_error("Sub-include can't turn on $sec if parent include's $sec was off");
            }
        }
        unless ($element{'FILE'} =~ /^[a-zA-Z0-9-_\.]{1,255}$/) {
            return inline_error("Invalid characters in include file name: $element{'FILE'} (code=$code)");
        }

        if ($req->{'IncludeOpen'}->{$element{'FILE'}}++) {
            return inline_error("Recursion detected in includes");
        }
        push @{$req->{'IncludeStack'}}, \%element;
        my $isource = "";
        my $file = $req->{'env'}->{'IncludePath'} . "/" . $element{'FILE'};
        open (INCFILE, $file) || return inline_error("Could not open include file.");
        { local $/ = undef; $isource = <INCFILE>; }
        close INCFILE;
        
        if ($element{'BML'}) {
            my $newhtml;
            bml_decode($req, \$isource, \$newhtml, { DO_CODE => $code });
            $isource = $newhtml;
        } 
        $req->{'IncludeOpen'}->{$element{'FILE'}}--;
        pop @{$req->{'IncludeStack'}};
        return $isource;
    }
    
    if ($type eq "_COMMENT" || $type eq "_C") {
        return "";
    }

    if ($type eq "_EH") {
        return BML::ehtml($element{'DATA'});
    }
    
    if ($type eq "_EB") {
        return BML::ebml($element{'DATA'});
    }
    
    if ($type eq "_EU") {
        return BML::eurl($element{'DATA'});
    }
    
    if ($type eq "_EA") {
        return BML::eall($element{'DATA'});
    }
    
    if ($type =~ /^_/) {
        return inline_error("Unknown core element '$type'");
    }
        
    $req->{'BlockStack'}->[-1] = $type;
        
    # traditional BML Block decoding ... properties of data get inserted
    # into the look definition; then get BMLitized again
    return inline_error("Undefined custom element '$type'")
        unless defined $req->{'blockref'}->{$realtype};

    my $preparsed = ($blockflags =~ /p/);

    if ($preparsed) {
        ## does block request pre-parsing of elements?
        ## this is required for blocks with _CODE and AllowCode set to 0
        foreach my $k (@elements) {
            my $decoded;
            bml_decode($req, \$element{$k}, \$decoded, $option_ref);
            $element{$k} = $decoded;
        }
    }
    
    # template has no variables or BML tags:
    return ${$req->{'blockref'}->{$realtype}} if $blockflags =~ /S/;

    my $expanded;
    if ($preparsed) {
        $expanded = ${$req->{'blockref'}->{$realtype}};
    } else {
        $expanded = parsein(${$req->{'blockref'}->{$realtype}}, \%element);
    }

    # {R} flag wants variable interpolation, but no expansion:
    unless ($blockflags =~ /R/)
    {    
        my $out;
        push @{$req->{'BlockStack'}}, "";
        my $opts = { %{$option_ref} };
        if ($preparsed) {
            $opts->{'DO_CODE'} = $req->{'env'}->{'AllowTemplateCode'};
        }
        bml_decode($req, \$expanded, \$out, $opts);
        pop @{$req->{'BlockStack'}};
        $expanded = $out;
    }

    $expanded = parsein($expanded, \%element) if $preparsed;
    return $expanded;    
}

######## bml_decode
#
# turns BML source into expanded HTML source
#
#   $inref    scalar reference to BML source.  $$inref gets destroyed.
#   $outref   scalar reference to where output is appended.
#   $opts     security flags

sub bml_decode
{
    my ($req, $inref, $outref, $opts) = @_;

    my $block = "";    # what (=BLOCK ... BLOCK=) are we in?
    my $data = "";          # what is (=BLOCK inside BLOCK=) the current block.
    my $depth = 0;     # how many blocks we are deep of the *SAME* type.

  EAT:
    while ($$inref ne "" && ! $req->{'stop_flag'})
    {
        # currently not in a BML tag... looking for one!
        if ($block eq "") {
            if ($$inref =~ s/^(.*?)\(=([A-Z0-9\_]+)\b//s) {
                $$outref .= $1;
                $block = $2;
                $depth = 1;
                next EAT;
            }
            
            # no BML left? append it all and be done.
            $$outref .= $$inref;
            $$inref = "";
            last EAT;
        }
        
        # now we're in a FOO tag: (=FOO
        # things to look out for:
        #   * Increasing depth:
        #      - some text, then another opening (=FOO, increading our depth
        #          (=FOO bla blah (=FOO
        #   * Decreasing depth: (if depth==0, then we're done)
        #      - immediately closing the tag, empty tag
        #          (=FOO=)
        #      - closing the tag (if depth == 0, then we're done)
        #          (=FOO blah blah FOO=)
        
        if ($$inref =~ s/^=\)//) {
            $depth--;
        } elsif ($$inref =~ s/^(.+?)((?:\(=$block\b )|(?:\b$block=\)))//s) {
            $data .= $1;
            if ($2 eq "(=$block") {
                $data .= $2;
                $depth++;
            } elsif ($2 eq "$block=)") {
                $depth--;
                if ($depth) { $data .= $2; }
            }
        } else {
            $$outref .= inline_error("BML block '$block' has no close");
            return;
        }

        # handle finished blocks
        if ($depth == 0) {

            $$outref .= bml_block($req, $block, $data, $opts);    
            $data = "";
            $block = "";
        }
    }
}

sub split_vars
{
    my ($dataref, $hashref) = @_;
    
    # Split the name-value pairs
    my $pair;
    my @pairs = split(/&/, $$dataref);
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= defined $hashref->{$name} ? "\0$value" : $value;
    }

}

# takes a scalar with %%FIELDS%% mixed in and replaces
# them with their correct values from an anonymous hash, given
# by the second argument to this call
sub parsein
{
    my ($data, $hashref) = @_;
    $data =~ s/%%(\w+)%%/$hashref->{$1}/eg;
    return $data;
}

sub inline_error
{
    return "[Error: <B>@_</B>]";
}

# returns lower-cased, trimmed string
sub trim
{
    my $a = $_[0];
    $a =~ s/^\s+//;
    $a =~ s/\s+$//;
    return $a;
}

sub load_look_from_initscript
{
    my ($file, $errref) = @_;
    my $dummy;
    $errref ||= \$dummy;

    my $modtime = (stat($file))[9];
    unless ($modtime) {
        $$errref = "Can't find VarInitScript: $file";
        return 0;
    }

    note_mod_time(undef, $modtime);
    unless (open (F, $file)) {
        $$errref = "Couldn't open $file";
        return 0;
    }
    my $init = join('', <F>);
    close F;
    
    my $ret = eval $init;
    
    if ($@) {
        $$errref = $@;
        return 0;
    }

    return 1;
}

# given the name of a look file, loads definitions into %look
sub load_look
{
    my ($req, $scheme, $file) = @_;
    return 0 if $scheme =~ /[^a-zA-Z0-9_\-]/;
    return 0 if $file =~ /[^a-zA-Z0-9_\-]/ or length($file) > 40;
    
    my $root = $req->{'env'}->{'LookRoot'};
    $file = $scheme ? "$root/$scheme/$file.look" : "$root/$file.look";
    
    my $modtime;
    if ($req->{'env'}->{'CacheUntilHUP'} && $FileModTime{$file}) {
        $modtime = $FileModTime{$file};
    } else {
        $modtime = (stat($file))[9];
    }
    return 0 unless $modtime;

    note_mod_time($req, $modtime);
    if ($modtime > $FileModTime{$file}) 
    {
        $FileBlockData{$file} = {};

        open (LOOK, $file);
        load_elements($FileBlockData{$file}, sub { scalar <LOOK> });
        close LOOK;
            
        $FileModTime{$file} = $modtime;

        # look for template types
        foreach my $k (keys %{$FileBlockData{$file}}) {
            if ($FileBlockData{$file}->{$k} =~ s/^\{([A-Za-z]+)\}//) {
                $FileBlockFlags{$file}->{$k} = $1;
            }
        }
    } 
    
    return 1;
}

# given a block of data, loads elements found into 
sub load_elements
{
    my ($hashref, $data, $opts) = @_;
    my $ol = $opts->{'declorder'};
    my $getter;
    if (ref $data eq "CODE") {
        $getter = $data;
    } else {
        my @data = split(/\n/, $data);
        $getter = sub { shift @data; }
    }

    my $curitem = "";
    my $depth;
    
    while (defined ($_ = $getter->()))
    {
        chomp;
        if ($curitem eq "" && /^([A-Z0-9\_\/]+)=>(.*)/)
        {
            $hashref->{$1} = $2;
            push @$ol, $1;
        }
        elsif (/^([A-Z0-9\_\/]+)<=\s*$/)
        {
            if ($curitem eq "")
            {
                $curitem = $1;
                $depth = 1;
                $hashref->{$curitem} = "";
                push @$ol, $curitem;
            }
            else
            {
                if ($curitem eq $1)
                {
                    $depth++;
                }
                $hashref->{$curitem} .= $_ . "\n";
            }
        }
        elsif ($curitem && /^<=$curitem\s*$/)
        {
            $depth--;
            if ($depth == 0)
            {
                $curitem = "";
            } 
            else
            {
                $hashref->{$curitem} .= $_ . "\n";
            }
        }
        else
        {
            $hashref->{$curitem} .= $_ . "\n" if $curitem;
        }
    }
}

# given a file, checks it's modification time and sees if it's
# newer than anything else that compiles into what is the document
sub note_file_mod_time
{
    my ($req, $file) = @_;
    note_mod_time($req, (stat($file))[9]);
}

sub note_mod_time
{
    my ($req, $mod_time) = @_;
    if ($req) {
        if ($mod_time > $req->{'most_recent_mod'}) { 
            $req->{'most_recent_mod'} = $mod_time; 
        }
    } else {
        if ($mod_time > $config->{'/'}->{'base_recent_mod'}) { 
            $config->{'/'}->{'base_recent_mod'} = $mod_time; 
        }
    }
}

# formatting
sub modified_time
{
    my $req = shift;
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($req->{'most_recent_mod'});
    my @day = qw{Sun Mon Tue Wed Thu Fri Sat};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};
    
    if ($year < 1900) { $year += 1900; }
    
    return sprintf("$day[$wday], %02d $month[$mon] $year %02d:%02d:%02d GMT",
                   $mday, $hour, $min, $sec);
}


package BML;

sub noparse
{
    $Apache::BML::CodeBlockOpts{'raw'} = 1;
    return $_[0];
}

sub decide_language
{
    my $req = $Apache::BML::cur_req;

    # GET param 'uselang' takes priority
    if (exists $Apache::BML::Lang{$BMLCodeBlock::GET{'uselang'}}) {
        return $BMLCodeBlock::GET{'uselang'};
    }

    # next is their cookie preference
    if ($BML::COOKIE{'langpref'} =~ m!^(\w{2,10})/(\d+)$!) {
        if (exists $Apache::BML::Lang{$1}) {
            # make sure the document says it was changed at least as new as when
            # the user last set their current language, else their browser might
            # show a cached (wrong language) version.
            note_mod_time($req, $2);
            return $1;
        }
    }
    
    # next is their browser's preference
    my %lang_weight = ();
    my @langs = split(/\s*,\s*/, lc($req->{'r'}->header_in("Accept-Language")));
    my $winner_weight = 0.0;
    my $winner;
    foreach (@langs)
    {
        # do something smarter in future.  for now, ditch country code:
        s/-\w+//;
        
        if (/(.+);q=(.+)/) {
            $lang_weight{$1} = $2;
        } else {
            $lang_weight{$_} = 1.0;
        }
        if ($lang_weight{$_} > $winner_weight && defined $Apache::BML::Lang{$_}) {
            $winner_weight = $lang_weight{$_};
            $winner = $Apache::BML::Lang{$_};
        }
    }
    return $winner if $winner;

    # next is the default language
    return $req->{'env'}->{'DefaultLanguage'} if $req->{'env'}->{'DefaultLanguage'};
    
    # lastly, english.
    return "en";
}

sub register_language
{
    my ($isocode, $langcode) = @_;
    next unless $isocode =~ /^\w{2,2}$/;
    $Apache::BML::Lang{$isocode} ||= $langcode;
}

sub note_mod_time
{
    my $mod_time = shift;
    Apache::BML::note_mod_time($Apache::BML::cur_req, $mod_time);
}

sub redirect
{
    my $url = shift;
    $Apache::BML::cur_req->{'location'} = $url;
    finish_suppress_all();
    return;
}

sub do_later
{
    my $subref = shift;
    return 0 unless ref $subref eq "CODE";
    $Apache::BML::cur_req->{'r'}->register_cleanup($subref);
    return 1;
}

sub register_block
{
    my ($type, $flags, $def) = @_;
    $type = uc($type);

    $Apache::BML::FileBlockData{"VARINIT"}->{$type} = $def;
    $Apache::BML::FileBlockFlags{"VARINIT"}->{$type} = $flags;
    return 1;
}

sub register_hook
{
    my ($name, $code) = @_;
    $Apache::BML::HOOK{$name} = $code;
}

sub register_ml_getter
{
    my $getter = shift;
    $Apache::BML::ML_GETTER = $getter;
}

sub get_query_string
{
    return $Apache::BML::cur_req->{'r'}->parsed_uri()->query;
}

sub http_response
{
    my ($code, $msg) = @_;
    finish_suppress_all();
    # FIXME: pretty lame.  be smart about code & their names & whether or not to send
    # msg or not.
    print "Status: $code\nContent-type: text/html\n\n$msg";
}

sub finish_suppress_all
{
    finish();
    suppress_headers();
    suppress_content();
}

sub suppress_headers
{
    $Apache::BML::cur_req->{'env'}->{'NoHeaders'} = 1;
}

sub suppress_content
{
    $Apache::BML::cur_req->{'env'}->{'NoContent'} = 1;
}

sub finish
{
    $Apache::BML::cur_req->{'env'}->{'stop_flag'} = 1;
}

sub set_content_type
{
    $Apache::BML::cur_req->{'content_type'} = $_[0] if $_[0];
}

sub set_default_content_type
{
    $Apache::BML::config->{'/'}->{'DefaultContentType'} = $_[0];

    # also, since config merge to $req->{'env'} has already happened,
    # need to set the current request's env also:
    $Apache::BML::cur_req->{'env'}->{'DefaultContentType'} = $_[0];
}

sub eall
{
    return ebml(ehtml($_[0]));
}


# escape html
sub ehtml
{
    my $a = $_[0];
    $a =~ s/\&/&amp;/g;
    $a =~ s/\"/&quot;/g;
    $a =~ s/\'/&\#39;/g;
    $a =~ s/</&lt;/g;
    $a =~ s/>/&gt;/g;
    return $a;	
}

sub ebml
{
    my $a = $_[0];
    $a =~ s/\(=/\(&#0061;/g;
    $a =~ s/=\)/&#0061;\)/g;
    return $a;
}

sub get_language
{
    return $Apache::BML::cur_req->{'lang'};
}

sub get_language_default
{
    return $Apache::BML::cur_req->{'env'}->{'DefaultLanguage'} || "en";
}

sub set_language
{
    $Apache::BML::cur_req->{'lang'} = $_[0];
}

# multi-lang string
# note: duplicated code for performance in BML::ML below!
sub ml
{
    my ($code, $vars) = @_;
    return "[ml_getter not defined]" unless $Apache::BML::ML_GETTER;
    $code = $Apache::BML::cur_req->{'r'}->parsed_uri()->path() . $code
        if $code =~ /^\./;
    my $data = $Apache::BML::ML_GETTER->($Apache::BML::cur_req->{'lang'}, $code);
    return $data unless $vars;
    $data =~ s/\[\[(.+?)\]\]/$vars->{$1}/g;
    return $data;
}

sub eurl
{
    my $a = $_[0];
    $a =~ s/([^a-zA-Z0-9_\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

sub durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

sub randlist
{
    my @rlist = @_;
    my $size = scalar(@rlist);
    
    my $i;
    for ($i=0; $i<$size; $i++)
    {
        unshift @rlist, splice(@rlist, $i+int(rand()*($size-$i)), 1);
    }
    return @rlist;
}

sub page_newurl
{
    my $page = $_[0];
    my @pair = ();
    foreach (sort grep { $_ ne "page" } keys %BMLCodeBlock::FORM)
    {
        push @pair, (eurl($_) . "=" . eurl($BMLCodeBlock::FORM{$_}));
    }
    push @pair, "page=$page";
    return $Apache::BML::cur_req->{'r'}->parsed_uri()->path() . "?" . join("&", @pair);
}

sub paging
{
    my ($listref, $page, $pagesize) = @_;
    $page = 1 unless ($page && $page==int($page));
    my %self;
    
    $self{'itemcount'} = scalar(@{$listref});
    
    $self{'page'} = $page;
    
    $self{'pages'} = $self{'itemcount'} / $pagesize;
    $self{'pages'} = $self{'pages'}==int($self{'pages'}) ? $self{'pages'} : (int($self{'pages'})+1);
    
    $self{'itemfirst'} = $pagesize * ($page-1) + 1;
    $self{'itemlast'} = $self{'pages'}==$page ? $self{'itemcount'} : ($pagesize * $page);
    
    $self{'items'} = [ @{$listref}[($self{'itemfirst'}-1)..($self{'itemlast'}-1)] ];
    
    unless ($page==1) { $self{'backlink'} = "<A HREF=\"" . page_newurl($page-1) . "\">&lt;&lt;&lt;</A>"; }
    unless ($page==$self{'pages'}) { $self{'nextlink'} = "<A HREF=\"" . page_newurl($page+1) . "\">&gt;&gt;&gt;</A>"; }
    
    return %self;
}

# $expires = 0  to expire when browser closes
# $expires = undef to delete cookie
sub set_cookie
{
    my ($name, $value, $expires, $path, $domain) = @_;

    # let the domain argument be an array ref, so callers can set
    # cookies in both .foo.com and foo.com, for some broken old browsers.
    if ($domain && ref $domain eq "ARRAY") {
        foreach (@$domain) {
            set_cookie($name, $value, $expires, $path, $_);
        }
        return;
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($expires);
    $year+=1900;

    my @day = qw{Sunday Monday Tuesday Wednesday Thursday Friday Saturday};
    my @month = qw{Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec};
    
    my $cookie = eurl($name) . "=" . eurl($value);

    # this logic is confusing potentially
    unless (defined $expires && $expires==0) {
        $cookie .= sprintf("; expires=$day[$wday], %02d-$month[$mon]-%04d %02d:%02d:%02d GMT", 
                           $mday, $year, $hour, $min, $sec);
    }
    $cookie .= "; path=$path" if $path;
    $cookie .= "; domain=$domain" if $domain;

    # use err_headers_out so we can set cookies along with a redirect
    $Apache::BML::cur_req->{'r'}->err_headers_out->add("Set-Cookie" => $cookie);

    if (defined $expires) {
        $BML::COOKIE{$name} = $value;
    } else {
        delete $BML::COOKIE{$name};
    }
}

# provide %BML::ML & %BMLCodeBlock::ML support:
package BML::ML;

sub TIEHASH {
    my $class = shift;
    my $self = {};
    bless $self;
    return $self;
}

# note: duplicated code for performance in BML::ml() above!
sub FETCH {
    my ($t, $code) = @_;

    return "[ml_getter not defined]" unless $Apache::BML::ML_GETTER;
    $code = $Apache::BML::cur_req->{'r'}->parsed_uri()->path() . $code
        if $code =~ /^\./;
    return $Apache::BML::ML_GETTER->($Apache::BML::cur_req->{'lang'}, $code);
}

# do nothing
sub CLEAR { }

# deprecated:
package BMLClient;
*BMLClient::COOKIE = *BML::COOKIE;
sub set_cookie { BML::set_cookie(@_); }

1;
