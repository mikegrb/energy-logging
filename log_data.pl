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
use Data::Printer;
use Data::Dumper;
use IO::Socket::SSL;
use DateTime::Format::ISO8601;

my $DEBUG        = shift;
my $config       = YAML::Tiny->read('config.yml')->[0];
my $ted          = $config->{ted_url};
my $hass_url     = $config->{hass_url};
my $hass_api_key = $config->{hass_api_key};
my $dbh          = DBI->connect( 'dbi:SQLite:dbname=' . $config->{db_path} ) or die;


my $furl = Furl->new(
  timeout         => 300,
  capture_request => 1,
  ssl_opts        => { SSL_ca_path => '/etc/ssl/certs', },
  agent =>
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36',
);

get_consumption();
get_generation();
get_car();
$dbh->disconnect();
system 'scp', 'energy.db', 'michael@thegrebs.com:energy/energy.db';


sub furl_get {
  my ( $url, $headers ) = @_;
  say STDERR "Fetching $url..." if $DEBUG;
  my $res = $furl->get( $url, $headers );
  die $res->status_line unless $res->is_success;
  say STDERR "Done. " . $res->status_line if $DEBUG;
  return $res;
}

sub get_consumption {
  my $history_url_hour = $ted . '/history/hourlyhistory.csv?MTU=0&COUNT=36&INDEX=0';
  my $res = furl_get($history_url_hour);
  die "Didn't recognize returned data from TED" unless $res->content =~ /^"mtu/;

  my $insert_date = $dbh->prepare(q{
    INSERT OR IGNORE INTO `history` (`date`, `time`) VALUES (?, ?)
  });
  my $log_row = $dbh->prepare(q{
    UPDATE `history` SET `consumption` = ? WHERE  `date` = ? AND  `time` = ?
  });

  my @data = split /\n/, $res->content;
  shift @data;    # first row is header

  for my $row ( reverse @data ) {
    my ( $date_time, $power ) = ( split /,/, $row )[ 1, 2 ];
    my ( $date, $time ) = split ' ', $date_time;
    $date = convert_to_8601($date);
    $insert_date->execute( $date, $time );
    $log_row->execute( $power * 1000, $date, $time );
  }

}
sub convert_to_8601 {
  my $ted_date = shift;
  return join '-', (split '/', $ted_date)[2,0,1];
}

sub get_generation {
  my $now   = DateTime->now( time_zone => $config->{time_zone} )->truncate( to => 'hour' );
  my $end   = $now->datetime();
  my $start = $now->subtract( hours => 36 )->datetime();

  my $res = furl_get(
    "https://mysolarcity.com/solarcity-api/powerguide/v1.0/measurements/882c62ee-412e-467a-a5ba-f9d9390c2c51?EndTime=${end}&ID=31681080-05e0-4f52-825e-a548f4188426&IsByDevice=false&Period=Hour&StartTime=${start}",  );

  print $res->content if $DEBUG > 2;
  my $data = decode_json( $res->content );
  my $log_row = $dbh->prepare(q{UPDATE `history` SET `solar` = ? WHERE `date` = ? AND `time` = ?});

  for my $measurement ( @{ $data->{Measurements} } ) {
    my ( $date, $hour ) = split /T/, $measurement->{Timestamp};
    $log_row->execute( $measurement->{EnergyInIntervalkWh} * 1000, $date, $hour );
  }
}

sub get_car {
  my $iso8601 = DateTime::Format::ISO8601->new;

  # /api/history/period/2018-04-28T14:00:00+00:00\?filter_entity_id\=sensor.juicenet_device_energy_added
  #[[{"attributes": {"friendly_name": "JuiceNet Device Energy added", "icon": "mdi:flash", "unit_of_measurement": "Wh"}, "entity_id": "sensor.juicenet_device_energy_added", "last_changed": "2018-04-28T14:00:00+00:00", "last_updated": "2018-04-28T14:00:00+00:00", "state": "15900"}]]

  my $log_row = $dbh->prepare(q{
    UPDATE `history` SET `car_used` = ?, `car_total` = ? WHERE  `date` = ? AND  `time` = ?
  });

  my ($cumulative) = $dbh->selectrow_array(q{
    SELECT `car_total` FROM `history`
    WHERE `car_total` NOT NULL
    ORDER BY `date` DESC, `time` DESC LIMIT 1
    });

  my $BACKFILL = defined $cumulative ? 0 : 1;

  my $when = DateTime->now->truncate( to => 'hour');
  $when = $when->subtract(days => 1) if $BACKFILL;

  my $ts   = $when->datetime . '+00:00';
  my $res  = furl_get( $hass_url . "api/history/period/$ts?filter_entity_id=sensor.juicenet_device_energy_added", [ 'x-ha-access' => $hass_api_key ] );
  my $data = decode_json( $res->content )->[0];

  my %hour_data;

  for my $datapoint (@$data){
    my $dt = $iso8601->parse_datetime( $datapoint->{last_changed} )->truncate( to => 'hour' )->subtract( hours => 1 )->set_time_zone('America/New_York');
    next if exists $hour_data{$dt->ymd}{$dt->hour};

    unless (defined $cumulative) {
      $cumulative = $datapoint->{state};
      next;
    }

    my $consumption = $datapoint->{state};
    $consumption -= $cumulative if $datapoint->{state} >= $cumulative;
    $cumulative = $datapoint->{state};

    $log_row->execute( $consumption, $cumulative, $dt->ymd, $dt->hms );
    $hour_data{ $dt->ymd }{ $dt->hour } = 1;
  }
}
__END__

CREATE TABLE history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    date        DATE    NOT NULL,
    time        TIME    NOT NULL,
    solar       INTEGER DEFAULT (0),
    consumption INTEGER,
    car_used    INTEGER,
    car_total   INTEGER
    CONSTRAINT date_time UNIQUE (
        date,
        time
    )
    ON CONFLICT FAIL
);

