#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

use 5.014;

use DBI;
use DateTime;
use YAML::Tiny;
use Data::Printer;
use Net::Twitter;

my $config          = YAML::Tiny->read('config.yml')->[0];
my $date = DateTime->today( time_zone => $config->{time_zone} )->subtract( days => 1)->strftime('%F');

my $nt = Net::Twitter->new(
    traits   => [qw/OAuth API::RESTv1_1/],
    consumer_key        => $config->{consumer_key},
    consumer_secret     => $config->{consumer_secret},
    access_token        => $config->{token},
    access_token_secret => $config->{token_secret},
    ssl => 1,
);

my $dbh = DBI->connect('dbi:SQLite:dbname=' . $config->{db_path}) or die;


my $sth = $dbh->prepare(q{
  SELECT
    SUM(`solar`)       AS `solar`,
    SUM(`consumption`) AS `consumption`
  FROM `history`
  WHERE `date` = ?
});
$sth->execute($date);
my ( $generated, $consumption ) = $sth->fetchrow_array();
$_ = sprintf( '%.2f', $_ / 1000 ) for ( $generated, $consumption );

my $status_string = generate_status_string( $generated, $consumption );
say $status_string;

if ( -e 'graphs/' . $date . '.png' ) {
  $nt->update_with_media( $status_string, [ 'graphs/' . $date . '.png' ] );
}
else {
  warn "Didn't find image";
  $nt->update($status_string);
}

sub generate_status_string {
  my ($generated, $consumed) = @_;
  my $net = sprintf('%.2f', $consumed - $generated);
  return "Yesterday, Solar: $generated kWh Consumed: $consumed kWh Grid: $net kWh";
}
