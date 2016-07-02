#!/usr/bin/env perl

use strict;
use warnings;

use 5.014;
use Forecast::IO;
use YAML::Tiny;
use DBI;

my $config = YAML::Tiny->read('config.yml')->[0];

my %forecast_args = (
    key       => $config->{forecast_io},
    longitude => $config->{longitude},
    latitude  => $config->{latitude},
);

my $dbh = DBI->connect('dbi:SQLite:dbname=' . $config->{db_path}) or die;

my $sth = $dbh->prepare(q{
  SELECT * FROM `history` WHERE `time` = '00:00:00' AND `clouds` IS NULL
});

my $set_clouds = $dbh->prepare(q{
  UPDATE `history` SET `clouds` = ? WHERE `date` = ? AND `time` = '00:00:00'
});

$sth->execute;
while (my $row = $sth->fetchrow_hashref) {
  my $data = Forecast::IO->new( %forecast_args, time => "$row->{date}T12:00:00" );
  my $cloud_cover = int( $data->{daily}{data}[0]{cloudCover} * 100 );
  say "$row->{date} $cloud_cover%";
  $set_clouds->execute( $cloud_cover, $row->{date} );
}
