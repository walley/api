#!/usr/bin/perl
use DBI;
use File::Basename;
use File::Copy;

use Getopt::Long;

# setup my defaults
my $name     = 'Bob';
my $age      = 26;
my $employed = 0;
my $help     = 0;

GetOptions(
    'dir=s'    => \$dir,
    'age=i'     => \$age,
    'employed!' => \$employed,
    'help!'     => \$help,
) or die "Incorrect usage!\n";

if( $help ) {
    print "Common on, it's really not that hard.\n";
}


#  if (scalar @ARGV == 0) {die("not enough parameters, died");}

  $i = $ARGV[0];
  $author = $ARGV[1];
  $new_location = $ARGV[2];
  $ref = $ARGV[3];
  $note = $ARGV[4];
  $license = $ARGV[5];

  if ($license eq "") {
    $license = "CCBYSA4";
  }


my $from_dir = $dir;


print "MASS INSERTION\n";

print "doing $from_dir\n";

&do_dir($from_dir);

sub exif_coords
{
  my $i = shift;

  #GPS Latitude : N 49d 43m 49.22s
  #GPS Longitude: E 17d 17m 56.25s

  # insert into guidepost values (NULL, 50.1, 17.1, 'x', 'znacka');

  $debug = 1;

  &debuglog("exifme", "start");


  @output = `jhead '$i'`;

  #print @output;

  &debuglog("params:",$i,$author,$new_location,$ref,$license);

  @exiflat = grep(/^GPS Latitude/, @output);
  @exiflon = grep(/^GPS Longitude/, @output);

  if (!scalar(@exiflat) || !scalar(@exiflon)) {
    &debuglog("No geo info");
    exit 1;
  }

  @l1 = split (" ", substr($exiflat[0], 14));
  @l2 = split (" ", substr($exiflon[0], 14));

  foreach (@l1) {chop();}
  foreach (@l2) {chop();}

  $lat = $l1[1] + $l1[2] / 60 + $l1[3] / 3600;
  $lon = $l2[1] + $l2[2] / 60 + $l2[3] / 3600;
  &debuglog( "coordinates result: $lat $lon");
}

sub insert_file
{
  my $filename;
  if (-e $new_location.basename($i)) {
    $r = int(rand(1000));
    $url = $new_location.$r.basename($i);
    $filename = $r.basename($i);
    &debuglog("file exists, renamed to $filename");
  } else {
    $url = $new_location.basename($i);
    $filename = $r.basename($i);
  }

  $move_from = "uploads/".basename($i);
  $move_to = $url;
  $res = move($move_from, $move_to);

  if (!$res) {
    &debuglog("moving failed",$move_from, $move_to);
    die;
  }

  my $dbfile = 'guidepost';
  my $dbh = DBI->connect( "dbi:SQLite:$dbfile" );
  if (!$dbh) {
    &debuglog("db failed","Cannot connect: ".$DBI::errstr);
    die;
  }

  $q = "insert into guidepost values (NULL, $lat, $lon, '".$url."','".$filename."', '$author', '$ref', '$note', '$license');\n";
  &debuglog($q);

  $res = $dbh->do($q);
  if (!$res) {
    &debuglog("query failed","Cannot connect: $DBI::errstr");
    die;
  }
  $dbh->disconnect();

  &debuglog("done");
}

#  $row_id = $dbh->sqlite_last_insert_rowid();

sub debuglog
{
  $x = join("-",@_);
#  system ("/usr/bin/logger -t guidepostexifme '$x'");
print $x;
}

sub do_dir
{

  $dirname = shift;

  opendir ( DIR, $dirname ) || die "Error in opening dir $dirname\n";
  while( ($filename = readdir(DIR))) {
   next if $filename =~ /\A\.\.?\z/;
   print("$diurname/$filename \n");
   &exif_coords($dirname."/".$filename);
  }

  closedir(DIR);
}