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

my $DEBUG  = shift;
my $config = YAML::Tiny->read('config.yml')->[0];
my $ted    = $config->{ted_url};
my $dbh    = DBI->connect( 'dbi:SQLite:dbname=' . $config->{db_path} ) or die;

my $furl = Furl->new(
  timeout         => 300,
  capture_request => 1,
  ssl_opts        => { SSL_ca_path => '/etc/ssl/certs' },
  agent =>
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36',
);

get_consumption();
get_generation();
$dbh->disconnect();
system 'scp', 'energy.db', 'michael@thegrebs.com:energy/energy.db';


sub furl_get {
  my $url = shift;
  say STDERR "Fetching $url..." if $DEBUG;
  my $res = $furl->get($url);
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

