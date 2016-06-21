#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

use 5.014;

use DBI;
use Furl;
use JSON::XS;
use DateTime;
use YAML::Tiny;
use XML::LibXML;
use Data::Printer;
use Net::Twitter;

use Chart::Clicker;
use Chart::Clicker::Data::Series;
use Chart::Clicker::Data::DataSet;
use Chart::Clicker::Data::Marker;



my $config          = YAML::Tiny->read('config.yml')->[0];

my $DEBUG = 1;

#my $ted = 'http://192.168.200.182';
my $ted = $config->{ted_url};
my $history_url_day = $ted . '/history/dailyhistory.csv?MTU=0&COUNT=2&INDEX=0';
my $history_url_hour = $ted . '/history/hourlyhistory.csv?MTU=0&COUNT=48&INDEX=0';

my $date = DateTime->today( time_zone => $config->{time_zone} )->subtract( days => 1);
my $date_8601 = $date->strftime('%F');
my $end   = $date_8601 . 'T23:59:59';
my $start = $date_8601 . 'T00:00:00';

my $nt = Net::Twitter->new(
    traits   => [qw/OAuth API::RESTv1_1/],
    consumer_key        => $config->{consumer_key},
    consumer_secret     => $config->{consumer_secret},
    access_token        => $config->{token},
    access_token_secret => $config->{token_secret},
    ssl => 1,
);

my $dbh = DBI->connect('dbi:SQLite:dbname=' . $config->{db_path}) or die;

my $furl = Furl->new(
  timeout         => 300,
  capture_request => 1,
#  ssl_opts        => { SSL_ca_path => '/etc/ssl/certs' },
  agent =>
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36',
);


my $consumption   = get_consumption();
my $generated     = get_generation();

my $status_string = generate_status_string( $generated, $consumption );
say $status_string;

generate_graph();

if ( -e $date_8601 . '.png' ) {
  $nt->update_with_media( $status_string, [ $date_8601 . '.png' ] );
}
else {
  warn "Didn't find image";
  $nt->update($status_string);
}

sub generate_graph {
  my $cc = Chart::Clicker->new(width => 900, height => 400, format => 'png');
  $cc->color_allocator->seed_hue(180);;

  my %serieses;
  for my $series (qw{ net solar consumption } ) {
    $serieses{ $series } = Chart::Clicker::Data::Series->new( name => ucfirst $series );
  }

  my $sth = $dbh->prepare(q{
    SELECT `time`, `solar`, `consumption`, consumption - solar AS `net`
    FROM history
    WHERE `date` = ?
    ORDER BY `time` ASC
  });
  $sth->execute( $date_8601 );

  my @ticks;
  my @tick_labels;
  while ( my $row = $sth->fetchrow_hashref ) {
    my ($tick) = ( $row->{time} =~ m/0?(\d+):00:00/ );
    $row->{time} =~ s/:00$//;
    push @ticks,       $tick;
    push @tick_labels, $row->{time};
    $serieses{$_}->add_pair( $tick, $row->{$_} / 1000 ) for (qw(net solar consumption));
  }

  my $ds = Chart::Clicker::Data::DataSet->new( series => [ values %serieses ] );
  $cc->add_to_datasets( $ds );

  my $ctx = $cc->get_context('default');
  $ctx->range_axis->label('kWh');
  $ctx->range_axis->fudge_amount( .10 );
  $ctx->add_marker( Chart::Clicker::Data::Marker->new( value => 0 ) );


  my $axis = $ctx->domain_axis;
  $axis->label('Time');
  $axis->tick_values( \@ticks );
  $axis->tick_labels( \@tick_labels );
  $axis->staggered( 1 );

  $cc->title->text( "Energy Consumption for $date_8601" );
  $cc->title->padding->bottom(5);
  $cc->write_output( $date_8601 . '.png' );
}

sub furl_get {
  my $url = shift;
  say STDERR "Fetching $url..." if $DEBUG;
  my $res = $furl->get($url);
  die $res->status_line unless $res->is_success;
  say STDERR "Done. "  . $res->status_line if $DEBUG;
  return $res;
}

sub get_consumption {
  my $res = furl_get( $history_url_hour );
  die "Didn't recognize returned data from TED" unless $res->content =~ /^"mtu/;
  my $total_kwh;
  my $target_date = $date->strftime('%m/%d/%Y');
  my $check_row = qr{^0,\Q$target_date\E}o;
  my $log_row = $dbh->prepare(q{INSERT INTO `history` (`date`, `time`, `consumption`) VALUES (?, ?, ?)});
  my @data = split /\n/, $res->content;
  say STDERR "Got " . scalar(@data) . " rows of data and header from TED" if $DEBUG;
  for my $row (reverse @data) {
    next unless $row =~ /$check_row/;
    my ( $date_time, $power ) = ( split /,/, $row )[ 1, 2 ];
    my ($h_date, $h_time) = split ' ', $date_time;
    $total_kwh += $power;
    $log_row->execute( $date_8601, $h_time, $power * 1000 );
  }

  return $total_kwh;
}

sub get_generation {

  my $res = $furl->get(
    "https://mysolarcity.com/solarcity-api/powerguide/v1.0/measurements/882c62ee-412e-467a-a5ba-f9d9390c2c51?EndTime=${end}&ID=31681080-05e0-4f52-825e-a548f4188426&IsByDevice=true&Period=Hour&StartTime=${start}",
    [
      Pragma     => 'no-cache',
      get        => '[object Object]',
      Accept     => 'application/json, text/plain, */*',
      Referer    => 'https://mysolarcity.com/Share/882C62EE-412E-467A-A5BA-F9D9390C2C51',
      Cookie     => 'ASP.NET_SessionId=wp3k20kidxxenlziinsle5ra; BIGipServerMySolarCity_80=990408458.20480.0000; _gat=1; BIGipServerPowerguide-80=604532490.20480.0000; _ga=GA1.2.1649526364.1466208154',
      Connection => 'keep-alive',
      'Accept-Language' => 'en-US,en;q=0.8',
      'Accept-Encoding' => 'gzip, deflate, sdch, br',
      'Cache-Control'   => 'no-cache'
    ] );

  die p $res unless $res->is_success;
  my $data = decode_json( $res->content );
  my %hour_data;


  for my $device ( @{ $data->{Devices} } ) {
    for my $measurement ( @{ $device->{Measurements} } ) {
      my (undef, $hour) = split /T/, $measurement->{Timestamp};
      $hour_data{ $hour } += $measurement->{EnergyInIntervalkWh} * 1000;
    }
  }

  my $log_row = $dbh->prepare( q{UPDATE `history` SET `solar` = ? WHERE `date` = ? AND `time` = ?} );
  for my $hour (keys %hour_data) {
    $log_row->execute( $hour_data{ $hour }, $date_8601, $hour );
  }

  return $data->{TotalEnergyInIntervalkWh};
}

sub generate_status_string {
  my ($generated, $consumed) = @_;
  my $net = $consumed - $generated;
  return "Yesterday, Solar: $generated kWh Consumed: $consumed kWh Grid: $net kWh";
}

__END__

CREATE TABLE history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    date        DATE    NOT NULL,
    time        TIME    NOT NULL,
    solar       INTEGER DEFAULT (0),
    consumption INTEGER,
    CONSTRAINT date_time UNIQUE (
        date,
        time
    )
    ON CONFLICT FAIL
);

