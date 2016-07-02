#!/usr/bin/env perl

use strict;
use warnings;
use autodie;

use 5.014;

use DBI;
use YAML::Tiny;
use DateTime;
use POSIX 'strftime';

use Chart::Clicker;
use Chart::Clicker::Data::Series;
use Chart::Clicker::Data::DataSet;
use Chart::Clicker::Data::Marker;
use Chart::Clicker::Axis::DateTime;
use Chart::Clicker::Renderer::StackedBar;

my $config          = YAML::Tiny->read('config.yml')->[0];

my $DEBUG = 1;

#my $ted = 'http://192.168.200.182';

my $dbh = DBI->connect('dbi:SQLite:dbname=' . $config->{db_path}) or die;

my $date     = DateTime->today( time_zone => $config->{time_zone} )->subtract( days => 1 );
say $date->strftime('%F');
my $title    = $date->strftime('%B %Y');
my $filename = $date->strftime('%Y-%m');

my $sth = $dbh->prepare(q{
  SELECT strftime('%s',`date`) AS `date`,
    SUM(`solar`)       AS `solar`,
    SUM(`consumption`) AS `consumption`,
    SUM(`clouds`)      AS `clouds`
  FROM `history`
  WHERE `date` BETWEEN
    DATE('now','localtime','-1 day', 'start of month')
    AND
    DATE('now','localtime','-1 day', 'start of month','+1 month','-1 day')
  GROUP BY `date`
  ORDER BY `date` ASC
});
$sth->execute;

  say join( "\t", qw(date . solar used net deficit surplus used_solar));


my ( $month_solar, $month_consumption ) = ( 0, 0 );
my @data;
while ( my $row = $sth->fetchrow_hashref ) {
  $row->{$_} /= 1000 for (qw(consumption solar));
  my $net = $row->{consumption} - $row->{solar};
  $month_solar       += $row->{solar};
  $month_consumption += $row->{consumption};
  my ($deficit, $surplus, $solar);
  if ($net > 0) {
    $deficit = $net;
    $surplus = 0;
    $solar = $row->{solar};
  }
  else {
    $deficit = 0;
    $surplus = $net * -1;
    $solar = $row->{solar} + $net;
  }
  say join( "\t", $row->{date}, $row->{solar}, $row->{consumption}, $net, $deficit, $surplus, $solar );

  push @data, [ $row->{date}, $solar, $row->{consumption}, $net, $deficit, $surplus, $row->{clouds} ];
}

my $month_net = sprintf('%.2f', $month_solar - $month_consumption);
my $sub_title = "Solar $month_solar kWh, Consumed $month_consumption kWh, Grid $month_net kWh";
say $sub_title;
generate_graph();

sub generate_graph {
  my $cc = Chart::Clicker->new(width => 900, height => 400, format => 'png');
  $cc->color_allocator->add_to_colors( Graphics::Color::RGB->from_hex_string('#377eb8') );
  $cc->color_allocator->add_to_colors( Graphics::Color::RGB->from_hex_string('#4daf4a') );
  $cc->color_allocator->add_to_colors( Graphics::Color::RGB->from_hex_string('#e41a1c') );

  my %serieses;
  my %name_for = ( solar => 'Consumption from Solar', surplus => 'Excess Solar', deficit => 'Consumption from Grid', clouds => '% Cloud Cover' );
  for my $series (qw{ solar deficit surplus clouds } ) {
    $serieses{ $series } = Chart::Clicker::Data::Series->new( name => $name_for{$series} );
  }

  say "Graph Data:";
  my (@ticks, @tick_labels);
  for my $row (@data) {
    say join ("\t", @{$row}[0,1,4,5, 6]);
    push @ticks, $row->[0];
    push @tick_labels, strftime('%m/%d', gmtime $row->[0]);
    $serieses{solar}->add_pair( $row->[0], $row->[1] );
    $serieses{deficit}->add_pair( $row->[0], $row->[4] );
    $serieses{surplus}->add_pair( $row->[0], $row->[5] );
    #$serieses{clouds}->add_pair(  $row->[0], $row->[6] );
  }

  my $ds = Chart::Clicker::Data::DataSet->new( series => [ $serieses{solar}, $serieses{surplus}, $serieses{deficit} ] );
  $cc->add_to_datasets( $ds );

  my $ctx = $cc->get_context('default');
  $ctx->range_axis->label('kWh');
  $ctx->range_axis->label_font->size(16);
  $ctx->renderer( Chart::Clicker::Renderer::StackedBar->new(opacity => .6) );

  my $daxis = $ctx->domain_axis;
  $daxis->label('Date');
  $daxis->staggered(1);
  $daxis->tick_values( \@ticks );
  $daxis->tick_labels( \@tick_labels );
  $daxis->label_font->size(16);

  #my $ds_clouds = Chart::Clicker::Data::DataSet->new( series => [ $serieses{clouds} ] );
  #my $cctx = Chart::Clicker::Context->new(name => 'clouds');
  #$cctx->renderer(Chart::Clicker::Renderer::Line->new);
  #$ds_clouds->context( 'clouds' );
  #$cc->add_to_contexts( $cctx );
  #$cc->add_to_datasets( $ds_clouds );

  $cc->legend->font->size(18);
  $cc->title->text( "Energy for $title" );
  $cc->title->padding->bottom(5);
  $cc->title->font->size(20);
  $cc->write_output( $filename . '.png' );
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

