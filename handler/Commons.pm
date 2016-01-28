package Guidepost::Commons;

use utf8;

use Apache2::Reload;
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::URI ();

use APR::URI ();
use APR::Brigade ();
use APR::Bucket ();
use Apache2::Filter ();

#use Apache2::Const -compile => qw(MODE_READBYTES);
#use APR::Const    -compile => qw(SUCCESS BLOCK_READ);

use constant IOBUFSIZE => 8192;
use Apache2::Connection ();
use Apache2::RequestRec ();

use APR::Const -compile => qw(URI_UNP_REVEALPASSWORD);
use Apache2::Const -compile => qw(OK);

use DBI;

use Data::Dumper;
use Scalar::Util qw(looks_like_number);

use Sys::Syslog;                        # all except setlogsock()
use HTML::Entities;

################################################################################
sub handler
################################################################################
{
  $r = shift;
  openlog('commonsapi', 'cons,pid', 'user');

  my $uri = $r->uri; 
  &parse_query_string($r);

  if (exists $get_args{bbox}) {
    &parse_bbox($get_args{bbox});
  }

   return Apache2::Const::OK;
}

################################################################################
sub parse_query_string
################################################################################
{
  my $r = shift;

  %get_args = map { split("=",$_) } split(/&/, $r->args);

  #sanitize
  foreach (sort keys %get_args) {
    $get_args{$_} =~ s/\%2C/,/g;
    $get_args{$_} =~ s/\%2F/\//g;
    if (lc $_ eq "bbox" ) {
      $get_args{$_} =~ s/[^A-Za-z0-9\.,-]//g;
    } elsif ($_ =~ /output/i ) {
      $get_args{$_} =~ s/[^A-Za-z0-9\.,-\/]//g;
    } else {
      $get_args{$_} =~ s/[^A-Za-z0-9 ]//g;
    }
    syslog('info', "getdata " . $_ . "=" . $get_args{$_});
  }
}

################################################################################
sub parse_bbox
################################################################################
{
  my $b = shift;
#BBox=-20,-40,60,40

  @bbox = split(",", $b);
  $minlon = $bbox[0];
  $minlat = $bbox[1];
  $maxlon = $bbox[2];
  $maxlat = $bbox[3];
  $BBOX = 1;
}

################################################################################
sub output_geojson
################################################################################
{
  use utf8;

  my $query = "select * from commons";
  if ($BBOX) {
    $query .= " lat < $maxlat and lat > $minlat and lon < $maxlon and lon > $minlon";
  }

  my $pt;
  my $ft;
  my @feature_objects;

  my $a;

  my $dbh = DBI->connect(
      "dbi:SQLite:/var/www/mapy/commons", "", "",
      {
          RaiseError     => 1,
          sqlite_unicode => 1,
      }
  );

  my $sql = qq{SET NAMES 'utf8';};
  $dbh->do($sql);

  $res = $dbh->selectall_arrayref($query);
  print $DBI::errstr;

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note) = @$row;

    my $fixed_lat = looks_like_number($lat) ? $lat : 0;
    my $fixed_lon = looks_like_number($lon) ? $lon : 0;

    $pt = Geo::JSON::Point->new({
      coordinates => [$fixed_lon, $fixed_lat],
      properties => ["prop0", "value0"],
    });

    my %properties = (
      'id' => $id,
      'url' => $url,
      'attribution' => $attribution,
      'name' => $name,
      'ref' => $ref,
      'note' => $note,
    );

    $ft = Geo::JSON::Feature->new({
      geometry   => $pt,
      properties => \%properties,
    });

    push @feature_objects, $ft;
  }


  my $fcol = Geo::JSON::FeatureCollection->new({
     features => \@feature_objects,
  });


  print $fcol->to_json."\n";
}

1;
