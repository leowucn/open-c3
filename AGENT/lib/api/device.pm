package api::device;
use Dancer ':syntax';
use Dancer qw(cookie);
use Encode qw(encode);
use JSON   qw();
use POSIX;
use api;

my $datapath = '/data/open-c3-data/device/curr';

sub getdatacount
{
    my ( $datafile, $greptreename, $treeid, $type, $subtype  ) = @_;
    if( $greptreename )
    {
        my    @data = `c3mc-device-cat $type $subtype`;
        chomp @data;

        my $title = shift @data;

        utf8::decode($title);
        my @title = split /\t/, $title;

        my $colmap;
        my $cmf = $datafile;
        $cmf =~ s/data.tsv$/colmap.yml/;
        if( -f $cmf )
        {
            $colmap = eval{ YAML::XS::LoadFile $cmf; };
            die "load colmap fail: $@" if $@;
        }

        my $treenamecol = ( $colmap && $colmap->{treename} ) ? $colmap->{treename} : undef;

        my $c = 0;
        for my $data ( @data )
        {
             utf8::decode($data);
             my @d = split /\t/, $data;

             my %d = map{ $title[ $_ ] => $d[ $_ ] } 0 .. @title - 1;

            my $treenamematch = 1;
            if( $greptreename )
            {
                if( $treenamecol )
                {
                     $treenamematch = 0 unless $d{ $treenamecol }  && ( $d{ $treenamecol } eq $greptreename || ( 0 == index( $d{ $treenamecol } , "$greptreename."  ) ) );
                }
                else
                {
                     $treenamematch = 0 unless $treeid == 4000000000;
                }
            }

             $c ++ if $treenamematch;

        }
        return $c;
    }
    else
    {
        my $c = `wc -l $datafile | awk '{print \$1}'`;
        chomp $c;
        return $c -1;
    }
};

get '/device/menu/:treeid' => sub {
    my $param = params();
    my $error = Format->new(
        treeid     => qr/^\d+$/, 1,
    )->check( %$param );

    return  +{ stat => $JSON::false, info => "check format fail $error" } if $error;

    my %re = map{ $_ => [] }qw( compute database domain networking others storage );
    return +{ stat => $JSON::true, data => \%re  } if ! $param->{treeid} || $param->{treeid} > 4000000000;

    my $pmscheck = $param->{treeid} == 4000000000
        ? api::pmscheck( 'openc3_job_root'                    )
        : api::pmscheck( 'openc3_job_write', $param->{treeid} );
    return $pmscheck if $pmscheck;

    my $greptreename = $param->{treeid} == 4000000000 ? undef : eval{ gettreename( $param->{treeid} ) };;
    return +{ stat => $JSON::false, info => $@ } if $@;

    for my $f ( sort glob "$datapath/*/*/data.tsv" )
    {
        my ( undef, $subtype, $type ) = reverse split /\//, $f;
        my $c = getdatacount( $f, $greptreename, $param->{treeid}, $type, $subtype );
        next unless $c > 0;
        push @{$re{$type}}, [ $subtype, $c ] if defined $re{$type};
    }

    my ( %re2, %subtypecount, %max );

    for my $type (  keys %re )
    {
        $re2{$type} = +{};
        for my $subtype ( @{ $re{$type} } )
        {
            my ( $name, $count ) = @{ $subtype };
            my ( $g, @alias ) = split /-/, $name;
            $subtypecount{$type}{$g} ++;
            $re2{$type}{$g} ||= [];
            push @{ $re2{$type}{$g}}, [ $g, @$subtype, join "-", @alias ];
            $max{$type} = @{ $re2{$type}{$g}} - 1 if $max{$type} < @{ $re2{$type}{$g}} - 1;
        }
    }

    for my $type (  keys %re )
    {
        for my $group ( keys %{ $re2{ $type  } } )
        {
            for ( 1.. 15 )
            {
                next unless @{ $re2{ $type  }{ $group }} <= $max{$type};
                push @{ $re2{ $type  }{ $group }}, [];
            }
        }
    }

    my %re3;
    for my $type ( keys %re2 )
    {
        $re3{ $type } = [];
        for my $group ( sort{ $subtypecount{$type}{$b} <=> $subtypecount{$type}{$a} }keys %{ $re2{ $type } } )
        {
            my @x = @{ $re2{ $type }{ $group } };
            map{ push @{ $re3{ $type }[ $_] }, $x[$_]  } 0 .. @x -1;
        }
    }

    return +{ stat => $JSON::true, data => \%re3 };
};


sub gettreename
{
    my $treeid = shift @_;
    my @x = `c3mc-base-treemap cache| grep "^$treeid;"|awk -F';'  '{print \$2}'`;
    chomp @x;
    die "get treename by id: $treeid fail" unless @x;
    return $x[0];
};

any '/device/data/:type/:subtype/:treeid' => sub {
    my $param = params();
    my $error = Format->new(
        type       => qr/^[a-z\d\-_]+$/, 1,
        subtype    => qr/^[a-z\d\-_]+$/, 1,
        treeid     => qr/^\d+$/, 1,
#       grepdata
    )->check( %$param );

    return  +{ stat => $JSON::false, info => "check format fail $error" } if $error;

    return +{ stat => $JSON::true, data => []  } if ! $param->{treeid} || $param->{treeid} > 4000000000;

    my $pmscheck = $param->{treeid} == 4000000000
        ? api::pmscheck( 'openc3_job_root'                    )
        : api::pmscheck( 'openc3_job_write', $param->{treeid} );
    return $pmscheck if $pmscheck;

    my $greptreename = $param->{treeid} == 4000000000 ? undef : eval{ gettreename( $param->{treeid} ) };
    return +{ stat => $JSON::false, info => $@ } if $@;

    my    @data = `c3mc-device-cat $param->{type} $param->{subtype}`;
    chomp @data;

    my $title = shift @data;
    return +{ stat => $JSON::true, data => [] } unless @data;

    my @re;

    my $outline = eval{ YAML::XS::LoadFile "$datapath/$param->{type}/$param->{subtype}/outline.yml"; };
    return +{ stat => $JSON::false, info => "load outline fail: $@" } if $@;

    my $colmap;
    if( -f "$datapath/$param->{type}/$param->{subtype}/colmap.yml" )
    {
        $colmap = eval{ YAML::XS::LoadFile "$datapath/$param->{type}/$param->{subtype}/colmap.yml"; };
        return +{ stat => $JSON::false, info => "load colmap fail: $@" } if $@;
    }

    my $treenamecol = ( $colmap && $colmap->{treename} ) ? $colmap->{treename} : undef;

    my $filter = [];
    my $filterdata = {};
    my %filterdata;

    $filter = eval{ YAML::XS::LoadFile "$datapath/$param->{type}/$param->{subtype}/filter.yml"; } if -f "$datapath/$param->{type}/$param->{subtype}/filter.yml";
    return +{ stat => $JSON::false, info => "load filter fail: $@" } if $@;
    my %filter; map{ $filter{$_->{name}} = 1; $filterdata->{$_->{name}} = [];  }@$filter;

    utf8::decode($title);
    my @title = split /\t/, $title;

    my @debug;

    my $grepdata = $param->{grepdata} && ref $param->{grepdata} eq 'HASH' && %{ $param->{grepdata} } ?  $param->{grepdata} : undef;
    my $search = $grepdata && $grepdata->{_search_} ? delete $grepdata->{_search_} : undef;

    for my $data ( @data )
    {
        utf8::decode($data);
        my $searchmath = 1;
        if( $search )
        {
            $searchmath = 0 if index( $data, $search ) < 0;
        }
        my @d = split /\t/, $data;

        my %d = map{ $title[ $_ ] => $d[ $_ ] } 0 .. @title - 1;

        for my $f ( keys %filter )
        {
            $filterdata{$f}{$d{$f}} ++;
        }

        push @debug , \%d if $param->{debug};

        my $treenamematch = 1;
        if( $greptreename )
        {
            if( $treenamecol )
            {
                 $treenamematch = 0 unless $d{ $treenamecol }  && ( $d{ $treenamecol } eq $greptreename || ( 0 == index( $d{ $treenamecol } , "$greptreename."  ) ) );
            }
            else
            {
                 $treenamematch = 0 unless $param->{greeid} == 4000000000;
            }
        }

        my $match = 1;
        if( $grepdata )
        {
            for my $grep ( keys %$grepdata )
            {
                $match = 0 if $grepdata->{$grep} ne $d{$grep};
            }
        }
        push @re, +{
            map{
                $_ => join( ' | ', map{ $d{ $_ } || '' }@{ $outline->{ $_ } } )
            }qw( uuid baseinfo system contact )
        } if $match && $searchmath && $treenamematch;
    }

    for my $name ( keys %filterdata )
    {
        my %v = %{ $filterdata{$name} };
        for my $k ( sort{ $v{$b} <=> $v{$a} } keys %v )
        {
            push @{$filterdata->{$name}}, +{ name => $k, count => $v{$k} };
        }
    }
    return +{ stat => $JSON::true, data => \@re, debug => \@debug, filter => $filter, filterdata => $filterdata  };
};

any '/device/detail/:type/:subtype/:treeid/:uuid' => sub {
    my $param = params();
    my $error = Format->new(
        type       => qr/^[a-z\d\-_]+$/, 1,
        subtype    => qr/^[a-z\d\-_]+$/, 1,
        treeid     => qr/^\d+$/, 1,
        uuid       => qr/^[a-z\d\-_]+$/, 1,
    )->check( %$param );

    return  +{ stat => $JSON::false, info => "check format fail $error" } if $error;

    return +{ stat => $JSON::true, data => []  } if $param->{treeid} > 4000000000;
    my $pmscheck = $param->{treeid} == 4000000000
        ? api::pmscheck( 'openc3_job_root'                    )
        : api::pmscheck( 'openc3_job_write', $param->{treeid} );
    return $pmscheck if $pmscheck;

    my $greptreename = $param->{treeid} == 4000000000 ? undef : eval{ gettreename( $param->{treeid} ) };
    return +{ stat => $JSON::false, info => $@ } if $@;

    my    @data = `c3mc-device-cat $param->{type} $param->{subtype}`;
    chomp @data;

    my $title = shift @data;
    return +{ stat => $JSON::true, data => [] } unless @data;

    my @re;

    my $colmap;
    if( -f "$datapath/$param->{type}/$param->{subtype}/colmap.yml" )
    {
        $colmap = eval{ YAML::XS::LoadFile "$datapath/$param->{type}/$param->{subtype}/colmap.yml"; };
        return +{ stat => $JSON::false, info => "load colmap fail: $@" } if $@;
    }

    my $uuidcol = ( $colmap && $colmap->{uuid} ) ? $colmap->{uuid} : 'UUID';
    my $treenamecol = ( $colmap && $colmap->{treename} ) ? $colmap->{treename} : undef;

    utf8::decode($title);
    my @title = split /\t/, $title;

    for my $data ( @data )
    {
        utf8::decode($data);
        my @d = split /\t/, $data;
        my %d = map{ $title[ $_ ] => $d[ $_ ] } 0 .. @title - 1;

        my $treenamematch = 1;
        if( $greptreename )
        {
            if( $treenamecol )
            {
                 $treenamematch = 0 unless $d{ $treenamecol }  && ( $d{ $treenamecol } eq $greptreename || ( 0 == index( $d{ $treenamecol } , "$greptreename."  ) ) );
            }
            else
            {
                 $treenamematch = 0 unless $param->{greeid} == 4000000000;
            }
        }

        next unless $treenamematch;

        push @re , \%d if ( $d{ $uuidcol } && $d{ $uuidcol } eq $param->{uuid} );

    }

    my @re2;
    for my $r ( @re )
    {
        map{
            $r->{$_} =~ s/_sys_temp_newline_temp_sys_/\n/g;
            $r->{$_} =~ s/_sys_temp_delimiter_temp_sys_/\t/g;
        } @title;
        my @x = map{ [ $_ => $r->{$_} ] } @title;
        push @re2, \@x;
    }
    return +{ stat => $JSON::true, data => \@re2, treenamecol => $treenamecol };
};

true;
