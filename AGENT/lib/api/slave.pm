package api::slave;
use Dancer2;
use Dancer2::Plugin::WebSocket;
use EV;
use FindBin qw( $RealBin );
use MYDB;
use Code;
use Logs;
use Util;

set show_errors => 1;

our %conn;

our ( $mysql, $myname, $sso, $pms, $cookiekey, $logs );
BEGIN{
    use lib "$RealBin/../private/lib";

    $myname = Util::myname();
    $mysql = MYDB->new( "$RealBin/../conf/conn" );

    ( $sso, $pms ) = map{ Code->new( "auth/$_" ) }qw( sso pms );

    my %env = Util::envinfo( qw( cookiekey ) );
    $cookiekey = $env{cookiekey};

    $logs = Logs->new( 'apislave' );
};

sub replace
{
    my $s = shift;
    $s =~ s/.\[1m.\[31m/<font color="#FF0000">/g;
    $s =~ s/.\[1m.\[32m/<font color="#00FF00">/g;
    $s =~ s/\[31m.\[42m/<font color="#0000FF">/g;
    $s =~ s/\[0m.\[0m/<\/font>/g;
    return $s;
}


websocket_on_open sub {
    my( $conn, $env ) = @_;
    my ( $HTTP_COOKIE, $QUERY_STRING ) = @$env{qw( HTTP_COOKIE QUERY_STRING )};

    my %cookie = map{ split /=/, $_, 2 }split /;\s*/, $HTTP_COOKIE;
    my %query = map{ split /=/, $_, 2 } split /&/, $QUERY_STRING;

    my $uuid = $query{uuid};
    my $error = 'open log fail:';
    unless( defined $uuid && $uuid =~ /^[a-zA-Z0-9]+$/ )
    {
        $conn->send("$error uuid format error");
        return;
    }

    my $checklog = $uuid =~ /^\d+$/ ? 1 : 0;
    unless( $ENV{MYDan_DEBUG} )
    {
        my $installuuid = $uuid;
        unless( $cookie{$cookiekey} )
        {
            $conn->send("$error: nocookie");
            return;
        }

        my $user = eval{ $sso->run( cookie =>  $cookie{$cookiekey} ) };
        $logs->say( sprintf "user:$user uri:/ws?uuid=$uuid method:ws HTTP_X_FORWARDED_FOR:'' param:''", );
   
        my $projectid;

        if( $checklog )
        {
            $projectid  = $uuid;
        }
        else
        {
             my @col = qw( projectid );
             my $r = eval{ $mysql->query( sprintf( "select %s from install where uuid='$installuuid'", join ',', @col ), \@col )};

             unless( $r && @$r )
             {
                 $conn->send("$error: Non-existent uuid:$installuuid");
                 return;
             }

             my $data = $r->[0];
             unless( defined $data->{projectid} && $data->{projectid} =~ /^\d+$/ )
             {
                 $conn->send("$error: projectid format error");
                 return;
             }
             $projectid = $data->{projectid};
         }
         my $p = eval{ $pms->run( cookie => $cookie{$cookiekey},
                 treeid => $projectid, point => 'openc3_agent_read' ) };
         if( $@ )
         {
              $conn->send("$error: pms code error:$@");
              return;
         }
         unless( $p )
         {
              $conn->send("$error: Unauthorized");
              return;
         }
    }

    my ( $file, $h ) = sprintf "$RealBin/../logs/%s/$uuid", $checklog ? 'check' :'install';

    system( "touch '$file'" )unless -f $file;
    unless( open $h, "<$file" )
    {
        $conn->send("$error: open file fail: $!");
        return;
    }

    while( <$h> ) { $conn->send(replace($_)); }

    $conn{$conn} = EV::stat $file, 10, sub {
        while( <$h> ) { $conn->send(replace($_)); }
    };
  
};

websocket_on_close sub
{
    my( $conn ) = @_;
    delete $conn{$conn};
};

get '/installlog/:uuid' => sub {
  my $uuid = params()->{uuid};
  my $ws_url = request->env->{HTTP_X_REAL_IP}
            ? sprintf( "ws://%s/slave/$myname/ws", request->env->{HTTP_HOST} )
            : websocket_url;

  return <<"END";
    <html>
      <head><script>
          var urlMySocket = "$ws_url?uuid=$uuid";
          var mySocket = new WebSocket(urlMySocket);
          mySocket.onmessage = function (evt) {
            setMessageInnerHTML(evt.data);
          };
          mySocket.onopen = function(evt) {
            console.log("opening");
          };
          function setMessageInnerHTML(innerHTML) {
              document.getElementById('message').innerHTML += innerHTML + '<br/>';
           }
    </script></head>
    <body style="background:#000; color:#FFF" ><div id="message"></div></body>
  </html>
END
};

del '/killinstall/:uuid' => sub {
  my $uuid = params()->{uuid};
  
  return JSON::to_json( +{ stat => $JSON::false, info => 'uuid format error' } )
      unless $uuid =~ /^[a-zA-Z0-9]+$/;

  unless( $ENV{MYDan_DEBUG} )
  {
      return JSON::to_json( +{ stat => $JSON::false, code => 10000 } )
          unless (  cookie( $cookiekey ) || ( request->headers->{appkey} && request->headers->{appname} ) );

      my $user = eval{ $sso->run( cookie => cookie( $cookiekey ), map{ $_ => request->headers->{$_} }qw( appkey appname ) ) };
      my $uri = request->path_info;
      $logs->say( sprintf "user:$user uri:$uri method:%s HTTP_X_FORWARDED_FOR:%s param:%s", 
            request->method, request->env->{HTTP_X_FORWARDED_FOR}, YAML::XS::Dump YAML::XS::Dump request->params() );
  }

  my @col = qw( pid projectid slave status );
  my $r = eval{ $mysql->query( sprintf( "select %s from install where uuid='$uuid'", join ',', @col ), \@col )};
  return JSON::to_json( +{ stat => $JSON::false, info => "Non-existent uuid:$uuid" } ) unless $r && @$r;

  my $data = $r->[0];

  return JSON::to_json( +{ stat => $JSON::false, info => "install $uuid in slave $data->{slave}" } )
      unless $data->{slave} && $data->{slave} eq $myname;
  return JSON::to_json( +{ stat => $JSON::true, info => "install $uuid has been closed, status is $data->{status}" } )
      if $data->{status} && ( $data->{status} eq 'success' || $data->{status} eq 'fail' );

  map{ 
      return JSON::to_json( +{ stat => $JSON::false, info => "$_ format error" } )
          unless defined $data->{$_} && $data->{$_} =~ /^\d+$/
  }qw( pid projectid );

  unless( $ENV{MYDan_DEBUG} )
  {
      my $p = eval{ $pms->run( cookie => cookie( $cookiekey ), 
          treeid => $data->{projectid}, point => 'openc3_agent_write',
          map{ $_ => request->headers->{$_} }qw( appkey appname ) ) };
      return JSON::to_json( +{ stat => $JSON::false, info => "get data from pms error:$@" } ) if $@;
      return JSON::to_json( +{ stat => $JSON::false, info =>  'Unauthorized' } ) unless $p;
  }

  return JSON::to_json( +{ stat => $JSON::true, info => "install $uuid has been exit,nofind pid $data->{pid}" } )
      unless kill( 0, $data->{pid} );


  system "killall -9 agent_worker_install_$uuid 1>/dev/null 2>&1";

  return kill( 0, $data->{pid} )
      ? JSON::to_json( +{ stat => $JSON::false, info => "kill install fail" } )
      : JSON::to_json( +{ stat => $JSON::true, info => "kill install succcess" } );
};

any '/mon' => sub {
     eval{ $mysql->query( "select count(*) from keepalive" )};
     return $@ ? "ERR:$@" : "ok";
};

true;
