package IRC::Logger;

use AnyEvent;
use AnyEvent::IRC::Client;
use Carp;
use Config::Pit;
use Encode;
use File::Path qw/mkpath/;
use IO::File;
use Time::Piece;
use YAML qw/LoadFile DumpFile/;

use constant RECONNECT_CHECK_INTERVALS => 60;

our $VERSION = 0.01;

sub new {
    my ( $class,$yaml ) = @_;
    croak "config yaml file required!" if !-f $yaml;
    my $self = bless {},$class;
    $self->cv( AnyEvent->condvar );
    $self->yaml($yaml);
    $self->init;
    return $self;
}

sub cv {
    my $self = shift;
    $self->{cv} = shift if @_;
    return $self->{cv};
}

sub init_irc {
    my ( $self,$server ) = @_;
    $self->{irc}{$server} = AnyEvent::IRC::Client->new();;
    return $self->{irc}{$server};
}

sub irc {
    my ( $self,$server ) = @_;
    return $self->{irc}{$server} || $self->init_irc( $server );
}

sub yaml {
    my ( $self,$yaml ) = @_;
    $self->{yaml} = $yaml if $yaml;
    return $self->{yaml};
}
sub conf {
    my ( $self,$conf ) = @_;
    $self->{conf} = $conf if $conf;
    return $self->{conf};
}

sub bot_info {
    my $self = shift;
    if ( @_ == 1 ){
        return $self->{_bot_info}{+shift};
    }
    elsif ( @_ == 5 ){
        @{$self->{_bot_info}}{qw/nick real logdir file_encoding format/} = @_;
    }
    return $self->{_bot_info};
}

sub info {
    my %self = shift;
    $self->{info} = shift if @_;
    return wantarray ? %{ $self->{info} } : $self->{info};
}

sub nick  {+shift->bot_info("nick")}
sub real  {+shift->bot_info("real")}
sub logdir{+shift->bot_info("logdir")}
sub file_encoding{+shift->bot_info("file_encoding")}
sub log_format{+shift->bot_info("format")}
sub server{+shift->info->{+shift}{server}}
sub server_nick{+shift->info->{+shift}{server_nick}}
sub charset{+shift->info->{+shift}{charset}}
sub password{+shift->info->{+shift}{password}}
sub ssl{+shift->info->{+shift}{ssl}}
sub port{+shift->info->{+shift}{port}}
sub channels {
    my ( $self,$server ) = @_;
    return wantarray ? @{ $self->info->{$server}{channels} } : $self->info->{$server}{channels};
}

sub log_date {
    my $self = shift;
    $self->{_log_date} = shift if @_;
    return $self->{_log_date};
}

sub log_file {
    my ( $self,$server,$channel ) = @_;
    $self->info->{$server}{$channel}{_log_file} = $_[-1] if @_ == 4;
    return $self->info->{$server}{$channel}{_log_file};
}

sub _log_handle {
    my ( $self,$server,$channel ) = @_;
    if ( @_ == 4 ){
        $self->{_log_handles}{$server}{$channel} = $_[-1];
        $self->{_log_handles}{$server}{$channel}->autoflush(1);
    }
    return $self->{_log_handles}{$server}{$channel};
}

sub connect_irc {
    my $self = shift;
    for my $server ( keys %{ $self->info } ){
        my $opt = {};
        @$opt{qw/nick real password/} = ( $self->nick,$self->real,$self->password($server) );
        $self->init_irc( $server );
        $self->irc($server)->enable_ssl if $self->ssl($server);
        $self->irc($server)->connect( $self->server($server), $self->port($server), $opt );
    }
    return $self;
}

sub join {
    my $self = shift;
    for my $server ( keys $self->info ){
        for my $channel ( $self->channels( $server ) ){
            $self->irc($server)->send_srv( JOIN => "\#$channel" );
            $self->register( $server,$channel );
        }
    }
    return $self;
}

sub register {
    my ( $self,$server,$channel ) = @_;
    chomp ( my $date = `date '+%Y%m%d'`);
    $self->log_date( $date );
    $self->log_file( $server,$channel,$self->logdir."/".$self->server_nick( $server )."/$channel/$date.log" );
    #open $self->{_log_handles}{$server}{$channel},">>",$self->info->{$server}{$channel}{_log_file}
    #    or die "Can't open $self->info->{$server}{$channel}{_log_file}:$!";
    my $fh = IO::File->new( $self->info->{$server}{$channel}{_log_file},"a" )
        or die "Can't open $self->info->{$server}{$channel}{_log_file}:$!";
    return $self->_log_handle( $server,$channel,$fh );
}

sub fh {
    my ( $self,$server,$channel ) = @_;
    $channel =~ s/^\#//;
    chomp ( my $date = `date '+%Y%m%d'`);
    if ( my $log_file = $self->log_file( $server,$channel ) ){
        my ( $log_date ) = $log_file =~ /\/(\d+)\.log$/;
        return $self->register( $server,$channel ) if $log_date != $date;
    }
    return $self->_log_handle( $server,$channel ) || $self->register( $server,$channel );
}

sub make_log_msg {
    my ( $self,$nick,$comment ) = @_;
    local $_ = $self->log_format;
    my $now = localtime->new;
    s/%Y/$now->year/eg;
    s/%m/sprintf "%02d",$now->mon/eg;
    s/%d/sprintf "%02d",$now->mday/eg;
    s/%H/sprintf "%02d",$now->hour/eg;
    s/%M/sprintf "%02d",$now->min/eg;
    s/%S/sprintf "%02d",$now->sec/eg;
    s/%n/$nick/g;
    s/%s/$comment/g;
    return $_;
}

sub add_log_channel {
    my ( $self,$server,$channel ) = @_;
    push @{ $self->conf->{servers}{ $self->server_nick( $server ) } },$channel;
    DumpFile( $self->yaml,$self->conf );
    if ( !-d $self->logdir."/".$self->server_nick( $server )."/$channel" ){
        mkpath( $self->logdir."/".$self->server_nick( $server )."/$channel" )
            or die $!;
    }
}

sub register_callback {
    my $self = shift;
    for my $server ( keys $self->info ){
        $self->irc($server)->reg_cb(
            connect   => $self->on_connect,
            publicmsg => $self->on_publicmsg,
            irc_invite => $self->on_invite,
            disconnect => $self->on_disconnect
        );
    }
}

sub on_connect {
    my $self = shift;
    return sub {
        my ($irc, $error) = @_;
        if ( defined $error ) {
            warn "Can't connect: $error";
            $cv->send();
        }
    };
}

sub on_publicmsg {
    my $self = shift;
    return sub {
        my ( $irc, $channel, $msg ) = @_;
        my $server = $irc->{host};
        my $comment = decode( $self->charset( $server ), $msg->{params}->[1] );
        my ( $nick ) = $msg->{prefix} =~ /^(.+?)!/;
        my $log_msg = $self->make_log_msg( $nick,$comment );
        print {$self->fh( $server,$channel )} encode( $self->file_encoding, "$log_msg\n" );
    };
}

sub on_invite {
    my $self = shift;
    return sub {
        my ($irc, $arg) = @_;
        my $channel = $arg->{params}->[1];
        my $server = $irc->{host};
        $irc->send_srv( JOIN => $channel );
        $channel =~ s/^\#//;
        $self->add_log_channel( $server, $channel );
    };
}

sub on_disconnect {
    my $self = shift;
    return sub {
       my $reconnect_timer = AnyEvent->timer(
           after    => RECONNECT_CHECK_INTERVALS,
           interval => RECONNECT_CHECK_INTERVALS,
           cb       => sub {
               $self->init;
               undef $reconnect_timer;
           }
       );        
    };
}

sub run {
    +shift->cv->recv;
}

sub finish {
    my $self = shift;
    for my $server ( keys %{ $self->info  } ){
        $self->irc($server)->disconnect("Bye!");
    }
}

sub init {
    my $self = shift;
    my $info = {};
    $self->conf( LoadFile( $self->yaml ) )
        or die "Can't read config to hashref from $yaml";

    my $log_conf = $self->conf;
    for my $s ( keys %{ $log_conf->{servers} } ){
        my $conf = Config::Pit::pit_get("irc_$s", require => {
            server      => "SERVER_NAME",
            port        => "PORT",
            password    => "DROWSSAP"
        });
        die "Not enough information to connect irc server" if !%$conf;
        my $server_name = $conf->{server};
        $info->{$server_name}{$_} = $conf->{$_} for qw/server port password charset ssl/;
        $info->{$server_name}{charset} ||= 'utf8';
        $info->{$server_name}{channels} = $log_conf->{servers}{$s};
        $info->{$server_name}{server_nick} = $s;
        $self->bot_info( @{$log_conf->{profile}}{qw/nick real/},@{$log_conf->{global}}{qw/logdir file_encoding format/} );
        for my $c ( @{ $info->{$server_name}{channels} } ){
            if ( !-d $self->logdir."/$s/$c" ){
                mkpath( $self->logdir."/$s/$c" )
                    or die $!;
            }
        }
    }
    $self->info( $info );
    $self->connect_irc->join;
    $self->register_callback;
    $self->set_signal;
}

sub set_signal {
    my $self = shift;
    $self->{_sig_hook}{USR1} = AnyEvent->signal(
        signal => "USR1",
        cb     => sub {
            warn $self->irc->registered() ? "Registered OK!\n" : "Registered NOT OK!\n";
        },
    );
    my $disconnect_cb = sub {
        warn "Give interrupt.\n";
        $self->irc->disconnect("Give interrupt.\n");
        exit;
    };
    $sig_hook{INT} = AnyEvent->signal( signal => "INT", cb => $disconnect_cb );
    $sig_hook{HUP} = AnyEvent->signal( signal => "HUP", cb => $disconnect_cb );
}
1;
