#
#   Guideposts, mod_perl2 handler
#   Copyright (C) 2015 - 2024 Michal Grezl
#                 2016 Marián Kyral
#                 2016 Miroslav Suchý
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software Foundation,
#   Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
#

package Guidepost::Table;

use utf8;
use JSON;

use Apache2::Connection ();
use Apache2::Const -compile => qw(OK SERVER_ERROR NOT_FOUND MODE_READBYTES);
use Apache2::Filter ();
use Apache2::Reload;
use Apache2::Request;
use Apache2::RequestIO ();
use Apache2::RequestRec ();
use Apache2::ServerRec;
use Apache2::URI ();
use Apache2::Cookie;

use APR::Brigade ();
use APR::Bucket ();
use APR::Const -compile => qw(URI_UNP_REVEALPASSWORD SUCCESS BLOCK_READ);
use APR::URI ();
use constant IOBUFSIZE => 8192;

use DBI;

use Data::Dumper;
use Scalar::Util qw(looks_like_number);

use Geo::JSON;
use Geo::JSON::Point;
use Geo::JSON::Feature;
use Geo::JSON::FeatureCollection;

use Sys::Syslog;
use HTML::Entities;

use File::Copy;
use File::Basename;
use Encode;

use Net::Subnet;
use Net::OAuth;
use Net::OAuth::AccessTokenRequest;

use Image::ExifTool;
use LWP::Simple;

use Geo::Inverse;
use Geo::Distance;

use Data::Uniqid qw ( suniqid uniqid luniqid );
use Time::HiRes;

my $dbh;
my $BBOX = 0;
my $LIMIT = 0;
my $OFFSET = 0;
my $PROJECT = "";
my $PROJECTID = 0;

my $image_root = "/var/www/api/";
my $cdn =  "//cdn.openstreetmap.social/";
my $main_site =  "openstreetmap.social";

my $minlon;
my $minlat;
my $maxlon;
my $maxlat;
my $error_result;
my $remote_ip;
my $dbpath;
my $githubclientid;
my $githubclientsecret;
my $user;
my $hostname;
my $api_request;
my $api_param;
my $request_id;
my $cookie_jar;

################################################################################
sub handler
################################################################################
{

  $start_run_time = Time::HiRes::time();

  $BBOX = 0;
  $LIMIT = 0;
  $OFFSET = 0;
  $PROJECT = "";
  $PROJECTID = 0;

  $api_request = "";
  $api_param = "";

  $r = shift;

  openlog('guidepostapi', 'cons,pid', 'user');

  my $cookie_jar = Apache2::Cookie::Jar->new($r);
  my $sessid_cookie = $cookie_jar->cookies("oauth2sessid");

  my $s = $r->server;
  $s->timeout(20_000_000);

  $request_id = uniqid;

#  $r = Apache2::Request->new(shift,
#                               POST_MAX => 10 * 1024 * 1024, # in bytes, so 10M
#                               DISABLE_UPLOADS => 0);



  $dbpath = $r->dir_config("dbpath");
  $githubclientid = $r->dir_config("githubclientid");
  $githubclientsecret = $r->dir_config("githubclientsecret");

  $nextcloudclientid = $r->dir_config("nextcloudclientid");
  $nextcloudclientsecret = $r->dir_config("nextcloudclientsecret");
  $nextcloudserver = $r->dir_config("nextcloudserver");

  if ($r->connection->can('remote_ip')) {
    $remote_ip = $r->connection->remote_ip
  } else {
    $remote_ip = $r->useragent_ip;
  }

  &connect_db();

  $user = $ENV{REMOTE_USER};

  if ($sessid_cookie ne "") {
    wsyslog('info', 'cookie:' . $sessid_cookie);
    @s = split('=', $sessid_cookie);
    my $u = &get_session_username($s[1]);
    if ($u ne "") {
      $user = $u;
    }
  }

  $is_https = $ENV{HTTPS};
  $referrer = $ENV{HTTP_REFERER};


  wsyslog('info', 'referrer:' . $referrer);

  if (&check_ban()) {
    wsyslog('info', 'access denied:' . $remote_ip);
    return Apache2::Const::OK;
  }

#  syslog('info', 'start method:'. $r->method());

  my $uri = $r->uri;
  $hostname = $r->get_server_name();

  &parse_query_string($r);
  &parse_post_data($r);

  if (exists $get_data{bbox}) {
    &parse_bbox($get_data{bbox});
  }

  if (exists $get_data{limit}) {
    $LIMIT = $get_data{limit};
  }

  if (exists $get_data{offset}) {
    $OFFSET = $get_data{offset};
  }

  if (exists $get_data{project}) {
    $PROJECT = $get_data{project};
  }

  if (!exists $get_data{output} or $get_data{output} eq "html") {
    $OUTPUT_FORMAT = "html";
    $r->content_type('text/html; charset=utf-8');
  } elsif ($get_data{output} eq "geojson") {
    $OUTPUT_FORMAT = "geojson";
    $r->content_type('text/plain; charset=utf-8');
  } elsif ($get_data{output} eq "json") {
    $OUTPUT_FORMAT = "json";
    $r->content_type('text/plain; charset=utf-8');
  } elsif ($get_data{output} eq "gpx") {
    $OUTPUT_FORMAT = "gpx";
    $r->content_type('text/plain; charset=utf-8');
  } elsif ($get_data{output} eq "kml") {
    $OUTPUT_FORMAT = "kml";
    $r->content_type('text/plain; charset=utf-8');
  }

  $r->no_cache(1);


  @uri_components = split("/", $uri);

  foreach $text (@uri_components) {
    $text = &smartdecode($text);
    $text =~ s/[^A-Za-z0-9ěščřžýáíéůúňĚŠČŘŽÝÁÍÉŮÚŇ.:, \/\p{IsLatin}]//g;
  }

  $error_result = Apache2::Const::OK;

  $api_version = $uri_components[1];
  $api_request = $uri_components[2];
  $api_param = $uri_components[3];

  if ($user eq "") {
    $user = "anon.openstreetmap.social";
  }

  wsyslog('info', "request to $hostname from $remote_ip by $user");
  wsyslog('info', "v: $api_version, r: $api_request, m: " . $r->method());
  wsyslog('info', "output " . $OUTPUT_FORMAT . ", limit " . $LIMIT. ", offset " . $OFFSET);
  if ($PROJECT ne "") {
    wsyslog('info', "project " . $PROJECT . "id is " . $PROJECTID);
  }

  if ($api_request eq  "all") {
    &output_all();
  } elsif ($api_request eq "goodbye") {
    &say_goodbye($r);
  } elsif ($api_request eq "count") {
    print &get_gp_count();
  } elsif ($api_request eq "get") {
    &table_get($uri_components[3], $uri_components[4]);
  } elsif ($api_request eq "leaderboard") {
    &leaderboard();
  } elsif ($api_request eq "ref") {
    my $joined_ref = substr(join('/', @uri_components[3 .. scalar @uri_components]), 0, -1);
    &show_by_ref($joined_ref);
  } elsif ($api_request eq "id") {
    &show_by_id($uri_components[3]);
  } elsif ($api_request eq "name") {
    &show_by_name($uri_components[3]);
  } elsif ($api_request eq "note") {
    &show_by($uri_components[3],"note");
  } elsif ($api_request eq "setbyid") {
    &set_by_id($post_data{id}, $post_data{value});
  } elsif ($api_request eq "move") {
    if ($post_data{lname} ne "" ) {
      $user = $post_data{lname};
      wsyslog('info', "osmcz username: $user");
    } else {
      wsyslog('info', "no osmcz username provided");
    }
    &move_photo($post_data{id}, $post_data{lat}, $post_data{lon});
  } elsif ($api_request eq "isedited") {
    #/isedited/ref/id
    &is_edited($uri_components[3], $uri_components[4]);
  } elsif ($api_request eq "isdeleted") {
    &is_deleted($uri_components[3]);
  } elsif ($api_request eq "approve") {
    &approve_edit($uri_components[3]);
  } elsif ($api_request eq "reject") {
    &reject_edit($uri_components[3]);
  } elsif ($api_request eq "review") {
    &review_form();
  } elsif ($api_request eq "delete") {
    &delete_id($uri_components[3]);
  } elsif ($api_request eq "remove") {
    &remove($uri_components[3]);
  } elsif ($api_request eq "close") {
#default output must be geojson
#params: $get_data{lat}, $get_data{lon}, $get_data{distance}, $get_data{limit}
    &get_nearby($get_data{lat}, $get_data{lon}, $get_data{distance}, $get_data{limit});
  } elsif ($api_request eq "hashtag") {
    #tag search
    &hashtag($uri_components[3]);
  } elsif ($api_request eq "tags") {
    if ($r->method() eq "GET") {
      my $out = &get_tags($uri_components[4]);
      $r->print($out);
    } elsif ($r->method() eq "DELETE") {
      my $joined_ref = substr(join('/', @uri_components[4 .. scalar @uri_components]), 0, -1);
      &delete_tags($uri_components[3], $joined_ref);
    } elsif ($r->method() eq "POST") {
      &add_tags($post_data{id}, $post_data{tag});
    }
  } elsif ($api_request eq "exif") {
    &exif($uri_components[3]);
  } elsif ($api_request eq "robot") {
    &robot();
  } elsif ($api_request eq "login") {
#    &login();
  } elsif ($api_request eq "logout") {
    &logout();
  } elsif ($api_request eq "logingithub") {
    &login_github();
  } elsif ($api_request eq "okgithub") {
    &debug_postdata();
    &login_ok_github($get_data{code});
  } elsif ($api_request eq "loginnextcloud") {
    &login_nextcloud();
  } elsif ($api_request eq "oknextcloud") {
    &debug_postdata();
    &login_ok_nextcloud($get_data{code});
  } elsif ($api_request eq "username") {
    &get_user_name();
  } elsif ($api_request eq "ping") {
    $r->print("pong");
  } elsif ($api_request eq "authcheck") {
    if (&authorized()) {
      $r->print("$user is ok");
    } else {
      $r->print("go away $user");
    }
  } elsif ($api_request eq "serverinfo") {
    if (&check_privileged_access()) {
      $r->print("<pre>".Dumper(\%ENV)."</pre>");
    }
  } elsif ($api_request eq "licenseinfo") {
    &show_licenses();
  } elsif ($api_request eq "notify") {
    if ($r->method() eq "POST") {
      &notify($post_data{lat}, $post_data{lon}, $post_data{text});
    } else {
      $error_result = 400;
    }
  } elsif ($api_request eq "sequence") {
    &sequence($uri_components[3]);
  } elsif ($api_request eq "timeadded") {
    &get_time_added($uri_components[3]);
  } elsif ($api_request eq "timetaken") {
    &get_time_taken($uri_components[3]);
  } elsif ($api_request eq "projectlist") {
    if ($r->method() eq "GET") {
      &list_projects();
    } elsif ($r->method() eq "POST") {
      &debug_postdata();
      &add_project($post_data{add});
    } elsif ($r->method() eq "DELETE") {
      &remove_project($post_data{project});
    }
  } elsif ($api_request eq "project") {
    if ($r->method() eq "GET") {
      #get - list of photos, probably ids
      &list_assigned($uri_components[3]);
    } elsif ($r->method() eq "POST") {
      #post - add photo to project
      assign_to_project($post_data{gp_id}, $post_data{project});
    } elsif ($r->method() eq "DELETE") {
      &debug_postdata();
      remove_from_project($post_data{gp_id}, $post_data{project})
      #delete - remove photo from project
    }
  } elsif ($api_request eq "resolve") {
    my $out = &resolve_project_id($uri_components[3]);
    $r->print($out);
  } else {
    wsyslog('info', "unknown request: $uri");
    $error_result = 400;
  }

#Dumper(\%ENV);
#    connection_info($r->connection);
#    $r->send_http_header;   # Now send the http headers.

  $dbh->disconnect;

  $end_run_time = Time::HiRes::time();

  if ($error_result) {
    if ($error_result == 400) {error_400();}
    if ($error_result == 401) {error_401();}
    if ($error_result == 403) {error_403();}
    if ($error_result == 404) {error_404();}
    if ($error_result == 412) {error_412();}
    if ($error_result == 500) {error_500();}
    $r->status($error_result);
  }

  wsyslog('info', "handler result $remote_ip :" . $error_result . " in " . ($end_run_time - $start_run_time) . "s");

  closelog();
  return Apache2::Const::OK;
}

################################################################################
sub wsyslog
################################################################################
{
  my ($a, $b) = @_;
  syslog($a, $request_id. " " . $b);
}

################################################################################
sub error_400()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>400 Bad request</title>
</head><body>
<h1>This is bad</h1>
<p>and you should feel bad</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at  Port 80</address>
</body></html>
');
}

################################################################################
sub error_401()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>401 Unauthorized</title>
</head><body>
<h1>You can not do this</h1>
<p>we do not know you</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at  Port 80</address>
</body></html>
');
}


################################################################################
sub error_403()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>403 Forbidden</title>
</head><body>
<h1>You can not do this</h1>
<p>you are not allowed to</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at  Port 80</address>
</body></html>
');
}

################################################################################
sub error_404()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>404 Not Found</title>
</head><body>
<h1>Not Found</h1>
<p>We know nothing about this</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at  Port 80</address>
</body></html>
');
}

################################################################################
sub error_412()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>412 Precondition Failed</title>
</head><body>
<h1>FAAAAAAAAAAAAAIIIIIIIIIIIIIILLLLLLL!!!11</h1>
<p>Do NOT fail our preconditions, not cool!</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at  Port 80</address>
</body></html>
');
}

################################################################################
sub error_500()
################################################################################
{
  $r->content_type('text/html; charset=utf-8');

  $r->print('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html><head>
<title>500 Boo Boo</title>
</head><body>
<h1>YAY!</h1>
<p>Error, sorry ;p</p>
<hr>
<address>'.$main_site.'/2 Ulramegasuperdupercool/0.0.1 Server at ' . $hostname . ' Port 80</address>
</body></html>
');
}

################################################################################
sub sequence()
################################################################################
{
  my $seq = shift;

  my $out = &page_header([],[],"guidepost sequence");

  $out .= "<style>\n";
  $out .= "li.g { background: green; }\n";
  $out .= "li,r { background: red; }\n";
  $out .= "</style>\n";

  $out .= "<ul>";
  for (my $i = 0; $i < 1000; $i++) {
    my $zeropadi = sprintf("%03d", $i);

    if (&tag_query("ref",$seq.$i)) {
    $out .= "<li class='g'> $i: ";
      $out .= "<a href=" . &https() . "://" . $hostname . "/table/ref/" . uc $seq . $zeropadi . "'>".$seq.$zeropadi."</a>";
    } else  {
    $out .= "<li  class='r'> $i: ";
      $out .= uc $seq . $zeropadi;
    }
  }
  $out .= "</ul>";
  $out .= &page_footer();

  $r->print($out);
}

################################################################################
sub output_all()
################################################################################
{
  my $query;

  if ($PROJECT ne "") {
    $prj_id = &get_project_id($PROJECT);
    $query = "select g.*, (select GROUP_CONCAT(k||':'||v, ';') from tags t where t.gp_id = g.id) from guidepost g,prjgp where g.id=prjgp.gp_id and prjgp.prj_id=$prj_id ";
    $query = &add_uri_params_to_query($query);
  } else {
    $query = "select g.*, (select GROUP_CONCAT(k||':'||v, ';') from tags t where t.gp_id = g.id) from guidepost g ";
    $query = &add_uri_params_to_query($query, 1);
  }

  $error_result = &output_data($query);
}

################################################################################
sub check_ban()
################################################################################
{
  my $banned = subnet_matcher qw(
    66.249.69.0/24
    66.249.64.0/24
    66.249.64.0/19
    151.80.31.102/32
    157.60.0.0/16
    157.56.0.0/14
    157.54.0.0/15
    91.232.82.106/32
    164.132.161.7/32
    137.74.207.164/32
    51.254.0.0/16
    51.255.0.0/16
  );

#doubrava  185.93.61.0/24
  return ($banned->($remote_ip));
}

################################################################################
sub check_privileged_access()
################################################################################
{
  my $ok = subnet_matcher qw(
    185.93.61.0/24
    185.93.60.0/22
    195.113.123.32/28
    193.164.133.120/32
    85.93.161.17/32
  );

#tmobile    62.141.23.8/32
#vodafone    46.135.14.8/32
  if ($ok->($remote_ip)) {
    wsyslog('info', 'privileged access approved:' . $remote_ip);
    return 1;
  } else {
    wsyslog('info', 'privileged access denied:' . $remote_ip);
    return 0;
  }
}

################################################################################
sub authorized()
################################################################################
{
#  return &check_privileged_access();

  my @ok_users = (
    "https://walley.mojeid.cz/#p8sRbfdmZu",
  );

#  my $is_ok = ($user ~~ @ok_users);
  my $is_ok = ($user ne "" and $user ne "anon.openstreetmap.social");
  my $ok = ($is_ok) ? "ok" : "bad";

  wsyslog('info', "authorized(): " . $user . " is " . $ok . " from " . $remote_ip);

  return $is_ok;
}

################################################################################
sub get_user_name()
################################################################################
{
  $r->print($user);
}

################################################################################
sub connection_info
################################################################################
{
  my ($c) = @_;
  print $c->id();
  print $c->local_addr();
  print $c->remote_addr();
  print $c->local_host();
  print $c->get_remote_host();
  print $c->remote_host();
  print $c->local_ip();
  print $c->remote_ip();
}

################################################################################
sub rrr
################################################################################
{
  $parsed_uri = $r->parsed_uri();

  print "s".$parsed_uri->scheme;print "<br>";
  print "u".$parsed_uri->user;print "<br>";
  print "pw".$parsed_uri->password;print "<br>";
  print "h".$parsed_uri->hostname;print "<br>";
  print "pt".$parsed_uri->port;print "<br>";
  print "pa".$parsed_uri->path;print "<br>";
  print "rpa".$parsed_uri->rpath;print "<br>";
  print "q".$parsed_uri->query;print "<br>";
  print "f".$parsed_uri->fragment;print "<br>";
  print "<hr>\n";
}

################################################################################
sub say_goodbye
################################################################################
{
  my $r = shift;
  print $r->args;

  &parse_query_string($r);

  foreach (sort keys %get_data) {
    print "$_ : $get_data{$_}\n";
  }
}

################################################################################
sub smartdecode
################################################################################
{
#  wsyslog('info', "before smartdecode:".$_[0]);

  use URI::Escape qw( uri_unescape );
  my $x = my $y = uri_unescape($_[0]);

#  wsyslog('info', "after smartdecode: x:".$x.", y:".$y);

  return $x if utf8::decode($x);
  return $y;
}

################################################################################
sub parse_query_str
################################################################################
{
  my $str = shift;
  my %h = ();
  if (length ($str) > 0) {
    my @pairs = split(/&/, $str);
    foreach my $pair (@pairs) {
      my ($name, $value) = split(/=/, $pair);
      $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
      $h{$name} = $value;
    }
  }
  return %h;
}

################################################################################
sub parse_query_string
################################################################################
{
  my $r = shift;

  %get_data = map { split("=",$_) } split(/&/, $r->args);

  #sanitize
  foreach (sort keys %get_data) {
    $get_data{$_} =~ s/\%2C/,/g;
    $get_data{$_} =~ s/\%2F/\//g;
    if (lc $_ eq "bbox" or lc $_ eq "lat" or lc $_ eq "lon" ) {
      $get_data{$_} =~ s/[^A-Za-z0-9\.,-]//g;
    } elsif ($_ =~ /output/i ) {
      $get_data{$_} =~ s/[^A-Za-z0-9\.,-\/]//g;
    } elsif ($_ =~ /project/i ) {
      $get_data{$_} =~ s/[^A-Za-z0-9]//g;
    } else {
      $get_data{$_} =~ s/[^A-Za-z0-9 ]//g;
    }
#    syslog('info', "getdata " . $_ . "=" . $get_data{$_});
  }
}

################################################################################
sub debug_postdata
################################################################################
{
  foreach (sort keys %post_data) {
    wsyslog('debug', "postdata:" . $_ . "=" . $post_data{$_});
  }
}

################################################################################
sub parse_post_data
################################################################################
{
  my $r = shift;

  $raw_data = decode_entities(&read_post($r));

  %post_data = map { split("=",$_) } split(/&/, $raw_data);

  #sanitize
  foreach (sort keys %post_data) {
#    wsyslog('debug', "postdata before:" . $_ . "=" . $post_data{$_});
    $post_data{$_} = &smartdecode($post_data{$_});
    $post_data{$_} =~ s/\+/ /g;
    $post_data{$_} =~ s/\%2F/\//g;
    $post_data{$_} =~ s/\%2C/,/g;

    if (lc $_ eq "id" ) {
      $post_data{$_} =~ s/[^A-Za-z0-9_\/]//g;
    } elsif (lc $_ eq "value" ) {
      $post_data{$_} =~ s/[^A-Za-z0-9_ \p{IsLatin}\/,\;]//g;
    } elsif (lc $_ eq "lat" or lc $_ eq "lon") {
      $post_data{$_} =~ s/[^0-9.\-]//g;
    } elsif (lc $_ eq "tag") {
      $post_data{$_} =~ s/[^A-Za-z0-9_: \p{IsLatin},\/]//g;
    } else {
      $post_data{$_} =~ s/[^A-Za-z0-9 ]//g;
    }
    wsyslog('info', "postdata after:" . $_ . "=" . $post_data{$_});
  }
}

################################################################################
sub connect_db
################################################################################
{
  my $dbfile = $dbpath.'/guidepost';

  $dbh = DBI->connect("dbi:SQLite:$dbfile", "", "",
    {
#       RaiseError     => 1,
       sqlite_unicode => 1,
    }
  );

  if (!$dbh) {
    wsyslog('info', "Cannot connect to db: " . $DBI::errstr);
    die;
  }
}

################################################################################
sub parse_bbox
################################################################################
{
  my $b = shift;
#BBox=-20,-40,60,40

  #print $b;

  @bbox = split(",", $b);
  $minlon = $bbox[0];
  $minlat = $bbox[1];
  $maxlon = $bbox[2];
  $maxlat = $bbox[3];
  $BBOX = 1;
}

################################################################################
sub add_bbox
################################################################################
{
  if ($BBOX) {
    return "lat < $maxlat and lat > $minlat and lon < $maxlon and lon > $minlon";
  }
}

################################################################################
sub show_by_ref
################################################################################
{
  my $ref = shift;
  &show_by($ref,'ref');
}

################################################################################
sub show_by_id
################################################################################
{
  my $id = shift;
  &show_by($id,'id');
}

################################################################################
sub show_by_name
################################################################################
{
  my $name = shift;
  &show_by($name, "attribution");
}

################################################################################
sub add_uri_params_to_query()
################################################################################
{
  my ($query, $add_where) = @_;


  if ($BBOX) {
    if ($add_where) {
      $query .= " where ";
    } else {
      $query .= " and ";
    }

    $query .= " ".&add_bbox();
  }

  if ($LIMIT) {
    $query .= " limit " . $LIMIT;
  }

  if ($OFFSET) {
    $query .= " offset " . $OFFSET;
  }

  return $query;
}

################################################################################
sub show_by
################################################################################
{
  my ($val, $what) = @_;
  my $query;

  wsyslog('info', "show_by($val, $what)");

  if ($PROJECT ne "") {
    #project query
    $query = "select * from guidepost,prjgp where guidepost.id=prjgp.gp_id and prjgp.prj_id=2 and guidepost.$what='$val'";
  } else {
    $query = "select * from guidepost where $what='$val' ";
  }

  wsyslog('info', "show_by $query");

  $query = &add_uri_params_to_query($query);

  wsyslog('info', "show_by $query");

  $error_result = &output_data($query);
}

################################################################################
sub hashtag
################################################################################
{
  my ($tag) = @_;
  my ($k, $v) = split(":", $tag);
  my $query = "";

  if ($k ne "" && $v ne "") {
    $query = "select guidepost.* from guidepost,tags where guidepost.id=tags.gp_id and tags.k='$k' and tags.v='$v'";
  } elsif ($k ne "" && $v eq "") {
    $query = "select guidepost.* from guidepost,tags where guidepost.id=tags.gp_id and tags.k='$k'";
  } elsif ($k eq "" && $v ne "") {
    $query = "select guidepost.* from guidepost,tags where guidepost.id=tags.gp_id and tags.v='$v'";
  } else {
    wsyslog("info", "hashtag bad? ($tag)");
  }

  $query = &add_uri_params_to_query($query);

  wsyslog("info", "hashtag query:" . $query . "(k:v)" . "($k:$v)");

  $error_result = &output_data($query);
}

################################################################################
sub output_data
################################################################################
{
  my ($query) = @_;
  my $ret;

  wsyslog("info", "output_data in $OUTPUT_FORMAT");
  wsyslog("debug", "output_data query:" . $query);

  if ($OUTPUT_FORMAT eq "html") {
    $ret = output_html($query);
  } elsif ($OUTPUT_FORMAT eq "geojson") {
    $ret = output_geojson($query);
  } elsif ($OUTPUT_FORMAT eq "json") {
    $ret = output_json($query);
  } elsif ($OUTPUT_FORMAT eq "gpx") {
    $ret = output_gpx($query);
  } elsif ($OUTPUT_FORMAT eq "kml") {
    $ret = output_kml($query);
  }

  wsyslog("info", "output_data returning: $ret");

  return $ret;
}

################################################################################
sub output_json
################################################################################
{
  use utf8;

  my ($query) = @_;

  my $pt;
  my $ft;
  my @feature_objects;

  $res = $dbh->selectall_arrayref($query) or do {
    wsyslog('info', "output_json: select err " . $DBI::errstr);
    return Apache2::Const::SERVER_ERROR;
  };

  if (!$r->print(encode_json($res))) {
    wsyslog('info', "output_json: r->print failed");
    return Apache2::Const::SERVER_ERROR;
  }

  return Apache2::Const::OK;
}

################################################################################
sub output_kml
################################################################################
{
  use utf8;

  my ($query) = @_;
  my $out = "";

  my $style = q(
 <Style id="guidepost">
  <IconStyle>
   <Icon>
    <href>http://maps.google.com/mapfiles/kml/pal4/icon28.png</href>
   </Icon>
  </IconStyle>
 </Style>
);

  $out .= q(<?xml version="1.0" encoding="UTF-8"?>);
  $out .= "\n";
  $out .= q(<kml xmlns="http://www.opengis.net/kml/2.2">);
  $out .= "\n";
  $out .= "<Document>\n";

  $out .= $style;

  my $sth = $dbh->prepare($query);
  $sth->execute();
  while($ref = $sth->fetchrow_hashref) {
#     print join (", ", keys %$ref), "\n";
#     print join (", ", values %$ref), "\n";

  $desc = "<h1>Guidepost</h1>"
  . "<ul>"
  . "<li>pozn:" . %$ref{note}
  . "<li>ref:" . %$ref{ref}
  . "<li>attr:" . %$ref{attribution}
  . "</ul>"
  . "<img src='http://api.".$main_site."/".%$ref{url}."'>";

  $out .= " <Placemark id=\"w" . %$ref{id}."\">\n";
  $out .= "  <styleUrl>#guidepost</styleUrl>\n";
  $out .= "  <name>" . %$ref{name} . "</name>\n";
  $out .= "  <description>\n<![CDATA[\n" . $desc . "\n]]>\n</description>\n";
  $out .= "  <Point>\n";
  $out .= "   <coordinates>". %$ref{lon} . "," . %$ref{lat} . ",0</coordinates>\n";
  $out .= "  </Point>\n";
  $out .= " </Placemark>\n";
  }

  $out .= "</Document>\n";
  $out .= "</kml>\n";

  $r->print($out);

  return Apache2::Const::OK;
}

################################################################################
sub output_gpx
################################################################################
{
  use utf8;

  my ($query) = @_;
  my $out = "";
  my $pt;
  my $ft;

  $res = $dbh->selectall_arrayref($query) or do {
    wsyslog('info', "output_gpx: select err " . $DBI::errstr);
    $error_result = 500;
    return Apache2::Const::SERVER_ERROR;
  };

  my $gpx = '<gpx xmlns="http://www.topografix.com/GPX/1/1" creator="walley" version="1.1" xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd http://www.garmin.com/xmlschemas/GpxExtensions/v3 http://www8.garmin.com/xmlschemas/GpxExtensions/v3/GpxExtensionsv3.xsd">';
  #my $gpx = '<gpx xmlns="http://www.topografix.com/GPX/1/1" creator="" version="1.1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">'
  $out .= q(<?xml version="1.0" encoding="UTF-8" standalone="no" ?>);
  $out .= "\n";
  $out .= $gpx;
  $out .= "\n";

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license) = @$row;
    $cmt = "$attribution $ref $note";
    $out .= " <wpt lat=\"$lat\" lon=\"$lon\">\n";
    $out .= "  <ele>0</ele>\n";
    $out .= "  <time>2007-08-26T16:08:17Z</time>\n";
    $out .= "  <name>$name</name>\n";
    $out .= "  <cmt>$cmt</cmt>\n";
    $out .= "  <extensions>\n";
    $out .= "   <gpxx:WaypointExtension>\n";
    $out .= "   <gpxx:Proximity>100</gpxx:Proximity>\n";
    $out .= "   </gpxx:WaypointExtension>\n";
    $out .= "  </extensions>\n";
  }

  $out .= " </wpt>\n";
  $out .= "</gpx>\n";

  $r->print($out);

  return Apache2::Const::OK;
}

################################################################################
sub output_html_pager()
################################################################################
{
  my $out = "";

  if ($LIMIT == 0) {
    $LIMIT = 5;
  }

  $nextoffset = $OFFSET + $LIMIT;
  $prevoffset = $OFFSET - $LIMIT;

  if ($prevoffset < 0) {
    $prevoffset = 0;
  }

#lol
  $prev = &get_protocol()."://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=" . $LIMIT . "&offset=" . $prevoffset . &project_uri_param();
  $next = &get_protocol()."://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=" . $LIMIT . "&offset=" . $nextoffset . &project_uri_param();

  $lm = $LIMIT - 1;
  if ($lm < 1) {
    $lm = 1;
  }

  $lp = $LIMIT + 1;
#no check ....
#  if ($lp > ??????) {
#    $lm = 1;
#  }

#lolx2
  $limit_plus  = &get_protocol()."://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=" . $lp . "&offset=" . $OFFSET . &project_uri_param();
  $limit_minus = &get_protocol()."://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=" . $lm . "&offset=" . $OFFSET . &project_uri_param();

  $out .= "<a href='$prev'>&lt;- prev</a>";
  $out .= " | ";
  $out .= "<a href='$next'>next -&gt;</a>\n";
  $out .= " limit ";
  $out .= "<a href='" . $limit_plus . "'>[+]</a>";
  $out .= "<a href='" . $limit_minus . "'>[-]</a>";

  $out .= "\n<br>";

  return $out;
}

################################################################################
sub https
################################################################################
{
  my $https;
  if ($is_https) {
    $https = "https";
  } else {
    $https = "http";
  }
  return $https;
}

################################################################################
sub output_html
################################################################################
{
  my ($query) = @_;

  @s = (
    "https://code.jquery.com/jquery-1.12.4.min.js",
    "https://cdn.jsdelivr.net/jquery.jeditable/1.7.3/jquery.jeditable.js",
    "https://api.".$main_site."/wheelzoom.js",
    "https://code.jquery.com/ui/1.13.3/jquery-ui.min.js",
    "https://cdn.openstreetmap.social/tageditor/jquery.caret.min.js",
    "https://cdn.openstreetmap.social/tageditor/jquery.tag-editor.js"
  );

  @l = (
    "https://cdn.openstreetmap.social/tageditor/jquery.tag-editor.css"
  );

  $https = &https();

  my $out = &page_header(\@s,\@l);

  $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "output_html dberror" . $DBI::errstr);
    $error_result = 500;
    return 500;
  };

  my $num_elements = @$res;

  if (!$num_elements) {
    return Apache2::Const::NOT_FOUND;
  }

  $out .= &output_html_pager();

#  if ($num_elements > 5 or $OFFSET or $LIMIT) {
#    $nextoffset = $OFFSET + 5;
#    $prevoffset = $OFFSET - 5;
#
#    if ($prevoffset < 0) {
#      $prevoffset = 0;
#    }
#
#    $prev = "$https://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=5&offset=" . $prevoffset . &project_uri_param();
#    $next = "$https://" . $hostname . "/" . $api_version . "/" . $api_request . "/" . $api_param . "?limit=5&offset=" . $nextoffset . &project_uri_param();
#    $out .= "<a href='$prev'>&lt;- prev</a>";
#    $out .= " | ";
#    $out .= "<a href='$next'>next -&gt;</a><br>\n";
#  }

  if ($PROJECT ne "") {
    $out .= "<h1>projekt: $PROJECT</h1>\n";
  }

  $out .= "<!-- user is $user -->\n";

  my $counter = 0;

  foreach my $row (@$res) {
    if ($counter > $LIMIT - 1) {
      last;
    }
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license) = @$row;
    $out .= &gp_line($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license);
    $out .= "\n";
    $counter++;
  }

#  wheelzoom disabled
#  $out .= "<script>wheelzoom(document.querySelectorAll('img'));</script>";

  $out .= &init_inplace_edit();

  $out .= &output_html_pager();

  $out .= &page_footer();

  $r->print($out);

  return Apache2::Const::OK;
}

################################################################################
sub output_geojson
################################################################################
{
  use utf8;

  my ($query) = @_;

  my $pt;
  my $ft;
  my @feature_objects;

  $res = $dbh->selectall_arrayref($query);

  if (!$res) {
    print $DBI::errstr;
    return Apache2::Const::SERVER_ERROR;
  }

  my $num_elements = @$res;

  if (!$num_elements) {
    return Apache2::Const::NOT_FOUND;
  }

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license, $tags) = @$row;

    my $fixed_lat = looks_like_number($lat) ? $lat : 0;
    my $fixed_lon = looks_like_number($lon) ? $lon : 0;

    $pt = Geo::JSON::Point->new({
      coordinates => [$fixed_lon, $fixed_lat],
      properties => ["yay", "woohoo"],
    });

    my %properties = (
      'id' => $id,
      'url' => $url,
      'attribution' => $attribution,
      'name' => $name,
      'ref' => $ref,
      'note' => $note,
      'tags' => $tags,
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

  #print $fcol->to_json."\n";
  $r->print($fcol->to_json."\n");

  return Apache2::Const::OK;
}


################################################################################
sub table_get
################################################################################
{
  my ($pf, $pt) = @_;

  my $out = "";

  my $from_gp = looks_like_number($pf) ? $pf : 0;
  my $to_gp = looks_like_number($pt) ? $pt : 0;

  my $query = "select * from guidepost LIMIT " . ($to_gp - $from_gp) . " OFFSET $from_gp";

  $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "table_get dberror" . $DBI::errstr);
    $out = "table_get: DB error";
    $error_result = 500;
    return 500;
  };

  foreach my $row (@$res) {
    my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license) = @$row;
    $out .= &gp_line($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license);
    $out .=  "</p>\n";
  }

  $out .=  &init_inplace_edit();
  $out .=  "<script>wheelzoom(document.querySelectorAll('img'));</script>";

  $r->print($out);
}

################################################################################
sub play_badge()
################################################################################
{
return '<a href="https://play.google.com/store/apps/details?id=org.walley.guidepost">
<img alt="Android app on Google Play" width="100px"
 src="https://play.google.com/intl/en_us/badges/images/generic/en-play-badge.png">
</a>';
}

################################################################################
sub leaderboard
################################################################################
{
  my $out = "";

  $out .= &page_header();
  $out .= "<h1>Leaderboard</h1>";

  my $query = "select attribution, count (*) as num from guidepost group by attribution COLLATE NOCASE order by num desc ";
  my $pos = 1;

  $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    $out .= $DBI::errstr;
  }

  $out .= &play_badge();

  $out .= "<table>\n";
  $out .= "<tr><th>position</th><th>name</th><th>count</th></tr>";
  foreach my $row (@$res) {
    my ($name, $count) = @$row;
    $out .= "<tr><td>" . $pos++. "</td><td>$name</td><td>$count</td></tr>";
  }
  $out .= "</table>\n";
  $out .= &page_footer();

  $r->print($out);

}

################################################################################
sub init_inplace_edit()
################################################################################
{
  my $url = "//" . $hostname . "/" . $api_version . "/setbyid";
  my $out = "";

  $out .= "<script>\n";
  $out .= "  \$('.edit').editable('" . $url. "', {\n";
  $out .= "     indicator   : 'Saving...',\n";
  $out .= "     cancel      : 'Cancel',\n";
  $out .= "     submit      : 'OK',\n";
  $out .= "     event       : 'click',\n";
  $out .= "     width       : 100,\n";
  $out .= "     select      : true,\n";
  $out .= "     placeholder : '" . &t("edited") . "...',\n";
  $out .= "     tooltip     : '" . &t("Click to edit...") . "',\n";
  $out .= "
  callback : function(value, settings) {
    console.log(this);
    console.log(value);
    console.log(settings);
  }
  ";
  $out .= "  });\n";
  $out .= "</script>\n";

  return $out;
}



################################################################################
sub maplinks()
################################################################################
{
  my ($lat, $lon) = @_;
  my $out = "<!-- maplinks -->";
#  $out .=  "<span class='maplinks'>\n";
  $out .=  "<span>\n";
  $out .=  "<ul>\n";
#  $out .=  "<li><a href='http://maps.yahoo.com/#mvt=m&lat=$lat&lon=$lon&mag=6&q1=$lat,$lon'>Yahoo</a>";
  $out .=  "<li><a href='https://".$main_site."/?mlat=$lat&mlon=$lon&zoom=16#map=16/$lat/$lon'>osm.cz</a>";
  $out .=  "<li><a href='https://www.openstreetmap.org/?mlat=$lat&mlon=$lon&zoom=16#map=16/$lat/$lon'>osm.org</a>";
  $out .=  "<li><a href='https://mapy.cz/turisticka?x=$lon&y=$lat&z=18&source=coor&id=$lon%2C$lat'>Mapy.cz</a>";
  $out .=  "<li><a href='https://maps.google.com/maps?ll=$lat,$lon&q=loc:$lat,$lon&hl=en&t=m&z=16'>Google</a>";
  $out .=  "<li><a href='https://www.bing.com/maps/?v=2&cp=$lat~$lon&style=r&lvl=16'>Bing</a>";
#  $out .=  "<li><a href='https://www.mapy.cz/?st=search&fr=loc:".$lat."N ".$lon."E'>Mapy.cz</a>";
  $out .=  "<li><a href='http://mapy.idnes.cz/#pos=".$lat."P".$lon."P13'>idnes.cz</a>";
  $out .=  "<li><a href='https://wego.here.com/?map=$lat,$lon,18,normal'>here.com</a>";
  $out .=  "</ul>\n";
  $out .=  "</span>\n";

  return $out;
}


################################################################################
sub static_map()
################################################################################
{
#minimap smallmap
  my ($lat, $lon) = @_;
  my $out = "<!-- static map -->";

  my $static_map;

#  $static_map = "https://www.mapquestapi.com/staticmap/v5/map?key=Fmjtd%7Cluu22qu1nu%2Cbw%3Do5-h6b2h&center=$lat,$lon&zoom=15&size=200,200&type=map&imagetype=png&pois=x,$lat,$lon";
#  $static_map = http://staticmap.openstreetmap.de/staticmap.php?center=$lat,$lon&zoom=14&size=200x200&maptype=mapnik&markers=$lat,$lon,lightblue1'
#  $static_map = "https://api.maptiler.com/maps/streets-v2/static/$lon,$lat,15/200x200.png?key=L67tzaVr8iKvxHky6fRl";

  $static_map = "https://maps.geoapify.com/v1/staticmap?style=osm-bright&width=200&height=200&center=lonlat:$lon,$lat&zoom=15&apiKey=d903b2dc005f4f139d97a84af7b84375";

  $out .=  "<img src='".$static_map."'/>";
  return $out;
}


################################################################################
sub delete_button
################################################################################
{
  my $ret = "";
  $ret .= "<span title='" . &t("remove_picture") ."'>";
#FIXME introduce cdn for images
  $ret .= "delete <img src='" . $cdn . "img/delete.png' width=16 height=16>";
  $ret .= "</span>";
  return $ret;
}

################################################################################
sub report_illegal
################################################################################
{
  my ($id) = @_;
  my $ret = "";
  $ret .= "<span title='" . &t("remove_picture") ."'>";
  $ret .= "<img src='" . $cdn . "img/delete.png' width=16 height=16>";
  $ret .= "<a href='mailto:openstreetmap\@".$main_site."?Subject=osm%20photo%20" . $id . "%20is%20illegal' target='_top'>".&t("illegal")."</a>";
  $ret .= "</span>";
  return $ret;
}

################################################################################
sub id_stuff
################################################################################
{
  my ($id) = @_;
  my $ret = "<!-- is stuff -->";
  $ret .= "<div class='Table'>\n";
  $ret .= "<div class='Row'>\n";
  $ret .= "<div class='Cell'>\n";
  $ret .= "<h2><a href='/". $api_version ."/id/$id' target='_blank'>$id</a></h2>\n";
  $ret .= "</div>\n";
  $ret .= "</div>\n";
  $ret .= "<div class='Row'>\n";
  $ret .= "<div class='Cell'>\n";

  if (&check_privileged_access()) {
    $ret .= "<div id='remove$id'>\n";
    $ret .= &delete_button();
    $ret .= "</div>";
  } else {
    $ret .= "<div id='remove$id'>\n";
    $ret .= &report_illegal($id);
    $ret .= "</div>";
  }

  $ret .= "</div>\n";
  $ret .= "</div>\n";
  $ret .= "</div>\n";

  $ret .= "
  <script>
  \$('#remove$id').click(function() {
    \$.ajax({
       url: '//" . $hostname . "/" . $api_version . "/remove/$id',
    }).done(function() {
      \$('#remove$id').html('marked for deletion')
    });
  });
  </script>
  ";

  return $ret;
}

################################################################################
sub t()
################################################################################
{
  my ($s, $lang) = @_;

  if ($s eq "Click to show items containing") {return "Zobraz položky obsahující";}
  if ($s eq "note") {return "Poznámka";}
  if ($s eq "nothing") {return "Vlož text ...";}
  if ($s eq "edited") {return "Editováno";}
  if ($s eq "remove_picture") {return "Smazat obrázek. Smazána budou pouze metadata, fotka bude skryta.";}
  if ($s eq "attribute") {return "Atribut";}
  if ($s eq "value") {return "Hodnota";}
  if ($s eq "isedited") {return "Bylo editováno?";}
  if ($s eq "Click to edit...") {return "Klikněte a editujte...";}
  if ($s eq "marked for delete") {return "Označeno pro smazání";}
  if ($s eq "times") {return "krát";}
  if ($s eq "license") {return "licence";}
  if ($s eq "Create date:") {return "Datum vytvoření:";}
  if ($s eq "illegal") {return "Nahlásit závadný obsah";}

#  return  utf8::decode($s);
  return $s;
}

################################################################################
sub show_table_row()
################################################################################
{
  my ($p1, $p2, $id, $col) = @_;

  my $out = "<!-- table row -->\n";
  $out .=
  "<div class='Row'>
    <div class='Cell'>
      <span>". $p1 ."</span>
    </div>
    <div class='Cell'>
       <span>" . $p2 . "</span>
    </div>
    <div class='Cell'>";

  if ($id ne "" and $col ne "") {
    $out .= "  <div id='edited" . $col . $id . "'>checking ...</div>";
  }

  $out .=  " </div>
  </div>\n";
  $out .= "<!-- end table row -->\n";

  return $out;
}

################################################################################
sub show_table_header()
################################################################################
{
  my ($c1, $c2, $c3) = @_;

  my $out = "<!-- table header -->\n";
  $out .=
  "<div class='Row'>
    <div class='Cell'>
      <span>". $c1 ."</span>
    </div>
    <div class='Cell'>
       <span>" . $c2 . "</span>
    </div>
    <div class='Cell'>
       <span>" . $c3 . "</span>
    </div>
  </div>\n";
  $out .= "<!-- end table row -->\n";

  return $out;
}

################################################################################
sub edit_stuff
################################################################################
{
  my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license) = @_;

  my $out;

  $out .= "<div class='Table'>";
  $out .= &show_table_header(&t("attribute"),&t("value"),&t("isedited"));
  $out .= &show_table_row("latitude", $lat, $id, "lat");
  $out .= &show_table_row("longtitude", $lon, $id, "lon");

  my $p1 = "<a title='" . &t("Click to show items containing") . " ref' href='/" . $api_version . "/ref/" . $ref . "'>" . &t("ref") . "</a>:";
  my $p2 = "<div class='edit' id='ref_$id'>" . $ref . "</div>";
  $out .= &show_table_row($p1, $p2, $id, "ref");

  $out .= &show_table_row(
   "<a title='" . &t("Click to show items containing") . " name' href='/" . $api_version . "/name/$attribution'>" . &t("by") . "</a>:",
   "<div class='edit' id='attribution_$id'>$attribution</div>",
   $id, "attribution"
  );
  $out .= &show_table_row(
   "<a title='" . &t("Click to show items containing") . " note' href='/" . $api_version . "/note/$note'>" . &t("note") . "</a>:",
   "<div class='edit' id='note_$id'>$note</div>",
   $id, "note"
  );

  $out .= &show_table_row(
    &t("Create date:"),
    &get_exif_data($id, "EXIF", "Create Date"),
    "",""
  );

  $out .= &show_table_row(
    &t("license"),
    $license,
    "",""
  );

  $out .= "</div>";

  return $out;
}

################################################################################
sub gp_line()
################################################################################
{
  my ($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license) = @_;

  my $https = "http";

  if ($api_version eq "openid") {
   $https = "https";
  }

  if ($is_https) {
    $https = "https";
  }

  my $out = "<!-- GP LINE -->";

  if ($ref eq "") {
    $ref = "none";
  }

  if ($note eq "") {
    $note = &t("nothing");
  }

  $out .= "<hr>\n";
  $out .= "<div class='gp_line'>\n";

  $out .= "<div class='master_table'>";
  $out .= "<div class='Row'>";

  #id stuff
  $out .= "<div class='Cell'>\n";
  $out .= &id_stuff($id);
  $out .= "</div>\n";

  #edit stuff
  $out .= "<div class='Cell cell_middle'>\n";

  $out .= &edit_stuff($id, $lat, $lon, $url, $name, $attribution, $ref, $note, $license);

  $out .= "<span>";
  $out .= "<a href='" . $https . "://" . $hostname . "/" . $api_version . "/exif/" . $id . "'>" . &t("exif") . " " . "</a>";
  $out .= "</span>";

  $out .= "<span>";
  $out .= "<a href='" . $https . "://" . $hostname . "/" . $api_version . "/timeadded/" . $id . "'>" . &t("date added") . " " . "</a>";
  $out .= "</span>";

  $out .= "</div>";

  @attrs= ("lat", "lon", "ref", "attribution", "note");


  $out .= "<script>";
  foreach $col (@attrs) {
    $out .= "
  \$.ajax({
    url: '" . $https . "://" . $hostname . "/" . $api_version . "/isedited/". $col ."/" . $id . "',
    timeout:5000
  })
  .done(function(data) {
    \$('#edited" . $col . $id . "').text(data);
  })
  .fail(function(jqXHR, textStatus, errorThrown ) {
    var status = jqXHR.status;
    console.log('isedited check fail ' + status);
    if (textStatus === 'timeout') {
      \$('#edited" . $col . $id . "').text('timeout');
    } else {
      \$('#edited" . $col . $id . "').text('error');
    }
  })
  .always(function(data) {
  });";
  }

    if (&check_privileged_access()) {
      $out .= "
  var text = \"" . &delete_button() . "\";
  \$.ajax({
    url: '" . $https . "://" . $hostname . "/" . $api_version . "/isdeleted/" . $id . "',
    timeout:4000
  })
  .done(function(data) {
    if (data.length > 1) {
      \$('#remove" . $id . "').text(data);
    } else {
      \$('#remove" . $id . "').html(text);
    }
  })
  .fail(function() {
    \$('#remove" . $id . "').html(text + '??');
  })
  .always(function(data) {
  });";
    }

  $out .= "  </script>";

  $out .= "<div class='Cell cell_middle'>";
  $out .= &maplinks($lat, $lon);
  $out .= "</div>\n";

  $out .= "<div class='Cell cell_middle'>";
  $out .= &static_map($lat, $lon);
  $out .= "</div>\n";


  $out .= "<div class='Cell'>";

  $full_uri = $https.":"."//" . $hostname . "/".$url;

#  $out .= "<a href='$full_uri'><img src='$full_uri' height='150px'><br>$name</a>";

  my $thumbnailurl = "http://" . $hostname . "/p/phpThumb.php?h=150&src=" . $full_uri;
  $out .= "<a href='$full_uri'><img src='".$thumbnailurl."' height='150px'><br>$name</a>";
  $out .= "</div>\n";

  $out .= "</div> <!-- row -->\n";
  $out .= "</div> <!-- table -->\n";

  $out .= "<textarea id='ta" . $id . "'>";
  $out .= &get_tags($id);
  $out .= "</textarea>\n";
  $out .= "<script>\n";
  $out .= "\$('#ta" . $id . "').tagEditor({

   autocomplete: { 
     delay: 0, 
     position: { collision: 'flip' }, 
     source: [
       'infotabule',
       'mapa',
       'cyklo',
       'ref',
       'panorama',
       'lyzarska',
       'konska',
       'rozcestnik',
       'naucna',
       'znaceni',
       'zelena', 'cervena', 'zluta', 'modra', 'bila',
       'rozmazane',
       'necitelne',
       'zastavka',
       'memorial',
       'eurodotace',
       'historicke',
       'smerovatabule',
       'vozickar',
       'most'
     ]
   },
   placeholder: 'Vložte tagy ...',
   delimiter:';',
   onChange: function(field, editor, tags) {
   },

   beforeTagSave: function(field, editor, tags, tag, val) {
     \$.ajax({
      type: 'POST',
      url: '" . $https . "://" . $hostname . "/" . $api_version . "/tags/',
      data: 'id=" . $id . "&tag=' + val,
      timeout:4000
    })
    .done(function(data, textStatus, jqXHR) {
      var status = jqXHR.status;
      console.log('tag save ' + status);
      return true;
    })
    .fail(function(jqXHR, textStatus, errorThrown ) {
      var status = jqXHR.status;
      console.log('tag save fail ' + status);
      if (status == 400) {
        alert('tag uz zrejme existuje');
      }
      if (status == 401) {
        alert('tag bude pridan po schvaleni');
      }
      return false;
    })
    .always(function(data) {
    });
   },

   beforeTagDelete: function(field, editor, tags, val) {
     \$.ajax({
      url: '" . $https . "://" . $hostname . "/" . $api_version . "/tags/" . $id . "/' + val,
      type: 'DELETE',
      timeout:4000
    })
    .done(function(data) {
      return true;
    })
    .fail(function() {
      return false;
    })
  }

  });\n";
  $out .= "</script>\n";

  $out .= "</div> <!-- gp_line --><br><br>\n";
#  syslog('info', $out);

  return $out;
}

################################################################################
sub get_gp_count
################################################################################
{
  my $query = "select count() from guidepost";
  my $sth = $dbh->prepare($query);
  my $rv = $sth->execute() or die $DBI::errstr;
  my @row = $sth->fetchrow_array();
  return $row[0];
}

################################################################################
sub page_header()
################################################################################
{
  my ($scripts, $links, $title) = @_;
  my $out = '
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="cache-control" content="no-cache">
  <meta http-equiv="pragma" content="no-cache">
  <link rel="stylesheet" type="text/css" href="//api.'.$main_site.'/webapps/editor/editor.css">
';

  if ($title) {
    $out .= "<title>$title</title>";
  } else {
    $out .= "<title>".$main_site." guidepost editor</title>";
  }

  foreach $i (@$links) {
    $out .= "  <link rel='stylesheet' type='text/css' href='";
    $out .= $i;
    $out .= "'>\n";
  }

  foreach $i (@$scripts) {
    $out .= "  <script type='text/javascript' src='";
    $out .= $i;
    $out .= "'></script>\n";
  }

  $out .= '</head>
<body>
';

  return $out;
}

################################################################################
sub page_footer()
################################################################################
{
return '
</body>
</html>
';
}

################################################################################
sub set_by_id()
################################################################################
{
  my ($id, $val) = @_;
  my @data = split("_", $id);
  $db_id = $data[1];
  $db_col = $data[0];

  if ($db_col eq 'license') {
    wsyslog("info", "set_by_id($id, $val): cannot change license this way");
    $error_result = 500;
  }

  if ($db_col eq 'lat' or $db_col eq 'lon') {
    $query = "insert into changes (gp_id, col, value, action) values ($db_id, '$db_col', '$val', 'position')";
  } else {
    $query = "insert into changes (gp_id, col, value, action) values ($db_id, '$db_col', '$val', 'edit')";
  }

  wsyslog('info', $remote_ip . " wants to change id:$db_id, '$db_col' to '$val'");
  my $sth = $dbh->prepare($query) or do {
    wsyslog('info', "500: prepare error, query is:" . $query);
    $error_result = 500;
    return;
  };

  my $res = $sth->execute();

  if (!$res) {
    wsyslog("info", "500: set_by_id($id, $val): dbi error " . $DBI::errstr);
    $error_result = 500;
  } else {
    &auto_approve();
  }

}


################################################################################
sub move_photo()
################################################################################
{
  my ($id, $lat, $lon) = @_;

  if (is_something($id, "position")) {
    #already moved
    wsyslog('info', $remote_ip . " wants to move id:$id again");
    $error_result = 412;
    return;
  }

  my $query = "insert into changes (gp_id, col, value, action) values (?, ?, ?, 'position')";
  $old_lat = &get_gp_column_value($id, "lat");
  $old_lon = &get_gp_column_value($id, "lon");
  wsyslog('info', $remote_ip . " wants to move id:$id, from '$old_lat', '$old_lon' to '$lat', '$lon'");

  my $res = $dbh->do($query, undef, $id, $lat, $lon) or do {
    wsyslog("info", "500: move_photo($id, $lat, $lon): dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };

  wsyslog("info", "move_photo($id, $lat, $lon): done");

# if (&check_privileged_access()) {&auto_approve();} 
# osmcz web sends username from osm oauth
  &auto_approve();
}

################################################################################
sub read_post()
################################################################################
{
  my $r = shift;
  my $bb = APR::Brigade->new($r->pool, $r->connection->bucket_alloc);
  my $data = '';
  my $seen_eos = 0;
  do {
    $r->input_filters->get_brigade($bb, Apache2::Const::MODE_READBYTES, APR::Const::BLOCK_READ, IOBUFSIZE);
    for (my $b = $bb->first; $b; $b = $bb->next($b)) {
      if ($b->is_eos) {
          $seen_eos++;
        last;
      }
      if ($b->read(my $buf)) {
        $data .= $buf;
      }
      $b->remove; # optimization to reuse memory
    }
  } while (!$seen_eos);
  $bb->destroy;
  return $data;
}


################################################################################
sub review_entry
################################################################################
{
  my ($req_id, $id, $gp_id, $col, $value, $img, $action) = @_;

  my $out = "";

  $out .= "<div id='reviewdiv$req_id'>";
  $out .= "<table>";
  $out .= "<tr>\n";

  $out .= "<td>change id:$id</td>";
  $out .= "<td>guidepost id:<a href='//" . $hostname . "/" . $api_version . "/id/$gp_id'>$gp_id</a></td>";

  $out .= "</tr>\n";
  $out .= "<tr>\n";

  if ($action eq "remove") {
    $out .= "<td><h2>DELETE</h2></td>";
  } elsif ($action eq "addtag") {
    $out .= "<td> <h2>add tags</h2></td>";
    $out .= "<td>Key: $col</td>";
    $out .= "<td>Value: $value</td>";
  } elsif ($action eq "position") {
    $out .= "<td><h2>move photo</h2></td>";

    $oldlat = &get_gp_column_value($gp_id, 'lat');
    $oldlon = &get_gp_column_value($gp_id, 'lon');

    my $lat = $col;
    my $lon = $value;

    my $obj = Geo::Inverse->new(); # default "WGS84"

    my $dist = $obj->inverse($oldlat,$oldlon,$lat,$lon);

    my $static_map = "https://open.mapquestapi.com/staticmap/v4/getmap?key=Fmjtd%7Cluu22qu1nu%2Cbw%3Do5-h6b2h&center=$oldlat,$oldlon&zoom=15&size=200,200&type=map&imagetype=png&pois=f,$oldlat,$oldlon|t,$lat,$lon";
    $out .= "<td>\n";
    $out .=  "<img class='xzoom' src='".$static_map."'/>";
    $out .= "</td>\n";

    $out .= "<td>from lat;lon: <font color='red'>$oldlat;$oldlon</font></td>";
    $out .= "<td>to lat;lon: <font color='green'>$col;$value</font></td>";
    $out .= "<td>distance: <font color='blue'>$dist</font></td>";
    wsyslog("info", "review position: $oldlat,$oldlon,$lat,$lon");

  } elsif ($action eq "deltag") {
    $out .= "<td> <h2>delete tags</h2></td>";
    $out .= "<td> tag $col:$value.</td>";
  } elsif ($action eq "edit") {

    $out .= "<td> <h2>change value</h2></td>";

    $original = &get_gp_column_value($gp_id, $col);

    $out .= "<td>column: $col</td>";
    $out .= "<td>original value: <font color='red'>$original</font></td>";
    $out .= "<td>new value: <font color='green'>$value</font></td>";
  }


  $out .= "\n";

  $out .= "</tr>";
  $out .= "</table>";
  $out .= "\n";

  $out .= "<table>";
  $out .= "<tr>";
  $out .= "<td>";
  $out .= "<img align='bottom' id='wheelzoom$req_id' src='//" . $hostname . "/img/guidepost/$img' width='320' height='200' alt='mapic'>";
  $out .= "</td>";
  $out .= "<td>";
  $out .= "<button style='height:200px;width:200px' onclick='javascript:reject(".$id."," . $req_id . ")' > reject </button>";
  $out .= "</td>";
  $out .= "<td>";
  $out .= "<button style='height:200px;width:200px' onclick='javascript:approve(".$id."," . $req_id . ")'> approve </button>";
  $out .= "</td>";
  $out .= "</table>";
  $out .= "\n";

  $out .= "</div>";
  $out .= "<hr>\n";

  return $out;
}

################################################################################
sub get_gp_column_value
################################################################################
{
  ($id, $column) = @_;
  $query = "select $column from guidepost where id=$id";

  if ($column eq "") {
    wsyslog("info", "get_gp_column_value $query");
  }

  $res = $dbh->selectrow_arrayref($query);

  if (!$res) {
    wsyslog("info", "get_gp_column_value: dberror '" . $DBI::errstr . "' q: $query");
    return "error" . $DBI::errstr;
  }

  return @$res[0];
}

################################################################################
sub review_form
################################################################################
{
  my $out = "";

  my $query = "select guidepost.name, changes.id, changes.gp_id, changes.col, changes.value, changes.action from changes, guidepost where changes.gp_id=guidepost.id limit 20";
  $res = $dbh->selectall_arrayref($query);
  $out .= $DBI::errstr;

  my @a = ("https://code.jquery.com/jquery-1.11.3.min.js", "https://api.openstreetmap.social/wheelzoom.js");
  $out .= &page_header(\@a);

  $out .= "<script>";
  $out .= "
function approve(id,divid)
{
  \$.ajax( '//" . $hostname . "/" . $api_version . "/approve/' + id, function(data) {
    alert( 'Load was performed.' + data );
  })
  .done(function() {
  \$('#reviewdiv'+divid).css('background-color', 'lightgreen');
  })
  .fail(function(jqXHR) {
    alert( 'server returned error ' + jqXHR.status + '.');
  })
  .always(function() {
  });
}

function reject(id,divid)
{
  \$.ajax( '//" . $hostname . "/" . $api_version . "/reject/' + id, function(data) {
    alert( 'Load was performed.'+data );
  })
  .done(function() {
  \$('#reviewdiv'+divid).css('background-color', 'red');
  })
  .fail(function(jqXHR) {
    alert( 'server returned error ' + jqXHR.status + '.' );
  })
  .always(function() {
  });
}

";

  $out .= "</script>";

  $out .= "\n<h1>Review</h1>\n";

  my $req_id = 0;
  foreach my $row (@$res) {
    my ($img, $id, $gp_id, $col, $value, $action) = @$row;
    $out .= &review_entry($req_id++, $id, $gp_id, $col, $value, $img, $action);
  }

  $out .= "<script>";
#  $out .= "wheelzoom(document.querySelector('img.wheelzoom'));";
  $out .= "wheelzoom(document.querySelectorAll('img'));";
  $out .= "</script>\n";

  $out .= &page_footer();

  $r->print($out);
}

################################################################################
sub is_edited
################################################################################
{
  $out = "";

  $r->content_type('text/plain; charset=utf-8');

  my ($what, $id) = @_;
  my $query = "select count() from changes where gp_id=$id and col='$what'";

  @res = $dbh->selectrow_array($query) or do {
    wsyslog("info", "500: is_edited dberror " . $DBI::errstr . " q: $query");
    $error_result = 500;
    return;
  };

  if ($res[0] > 0) {
    $out = " ".&t("edited"). " " . $res[0] . "x";
  } else {
    $out = "";
  }
  $r->print($out);
}

################################################################################
sub is_deleted
################################################################################
{
  my $out = "";

  my ($id) = @_;
  my $query = "select count() from changes where gp_id=$id and action='remove'";
  my @ret = $dbh->selectrow_array($query);
#  print $DBI::errstr;
  if ($ret[0] > 0) {
    $out = &t("marked for delete") . " " . $ret[0] . " " . &t("times");
  } else {
    $out = "";
  }
  $r->print($out);
}

################################################################################
sub is_something
################################################################################
{
  my $out = "";

  my ($id, $action) = @_;
  my $query = "select count() from changes where gp_id=$id and action='$action'";
  my @ret = $dbh->selectrow_array($query);

  return $ret[0];
}

################################################################################
sub reject_edit
################################################################################
{
  my ($id) = @_;
  my $query = "delete from changes where id=$id";

  wsyslog('info', "removing change id: " . $id);

  $dbh->do($query) or do {
    wsyslog("info", "reject_edit(): dberror:" . $DBI::errstr . ":" . $dbh->errstr . " q: $query");
    return 500;
  };

  return;
}

################################################################################
sub db_do
################################################################################
{
  my ($query) = @_;

  $res = $dbh->do($query) or do {
    wsyslog("info", "500: db_do(): dberror:" . $DBI::errstr . " q: $query");
    $error_result = 500;
  };
}

################################################################################
sub db_do2
################################################################################
{
  my ($query, $param) = @_;

  $res = $dbh->do($query, undef, $param) or do {
    wsyslog("info", "500: db_do2(): dberror:" . $DBI::errstr . " q: $query p: $param");
    $error_result = 500;
  };
}

################################################################################
sub approve_edit
################################################################################
{
  my ($id) = @_;
  my $query;

  if (&check_privileged_access()) {
    wsyslog('info', "approving because of privileged_access");
#  } elsif (&authorized()) {
#    wsyslog('info', "approving because authorized");
  } else {
    $error_result = 401;
    return;
  }

  wsyslog('info', "accepting change id: " . $id);

  $query = "select * from changes where id='$id'";
  @res = $dbh->selectrow_array($query) or return $DBI::errstr;
  my ($xid, $gp_id, $col, $value, $action) = @res;

  if ($action eq "remove") {
    wsyslog('info', "deleting $gp_id");
    &delete_id($gp_id);
  } elsif ($action eq "addtag") {

    if (&tag_exists($gp_id, $col, lc $value) or &tag_exists($gp_id, $col, uc $value)) {
    } else {
      my $query = "insert into tags values (null, $gp_id, '$col', '$value')";
      wsyslog('info', "adding tags " . $query);
      &db_do($query);
    }
  } elsif ($action eq "edit") {
    my $query = "update guidepost set $col='$value' where id=$gp_id";
    wsyslog('info', "updating " . $query);
    &db_do($query);
  } elsif ($action eq "position") {
    my $query = "update guidepost set lat='$col', lon='$value' where id=$gp_id";
    wsyslog('info', "moving photo " . $query);
    &db_do($query);
  } elsif ($action eq "deltag") {
    my $query = "delete from tags where gp_id=$gp_id and k='$col' and v='$value'";
    wsyslog('info', "deleting tags " . $query);
    &db_do($query);
  }

  if ($error_result > 300) {
    wsyslog('info', "approve_edit() error");
    return;
  }

  $query = "delete from changes where id=$id";
  wsyslog('info', "removing change request " . $query);
  &db_do($query);
}

################################################################################
sub delete_id
################################################################################
{
  my ($id) = @_;

  if (!&check_privileged_access()) {return;}

  wsyslog('info', "deleting id: " . $id);

  my $query = "select * from guidepost where id=$id";
  $res = $dbh->selectall_hashref($query, 'id');

  my $original_file =  $image_root . $res->{$id}->{url};
  my $new_file = $image_root . "/deleted/" . basename($res->{$id}->{url});

  if (-e $original_file) {
    #move picture to backup directory
    wsyslog('info', "delete_id: Moving $original_file to $new_file");
    if (!move($original_file, $new_file)) {
      wsyslog('info', "delete_id: Move failed($original_file,$new_file): $!");
      $error_result = 500;
      return;
    }
  } else {
    wsyslog('info', "delete_id: trying to move but $original_file was not found");
  }

#delete from db
  $query = "delete from guidepost where id='$id'";
  $dbh->do($query);
}

################################################################################
sub remove
################################################################################
{
  my ($id) = @_;
  wsyslog('info', $remote_ip . " wants to remove $id");

  if (!&check_privileged_access()) {
    wsyslog('info', $remote_ip . " was denied the right to remove $id");
    $error_result = 401;
    return;
  }

  wsyslog('info', $remote_ip . " wants to remove $id");
  $query = "insert into changes (gp_id, action) values ($id, 'remove')";
  my $sth = $dbh->prepare($query);
  my $res = $sth->execute() or do {
    wsyslog("info", "500: remove db error " . $DBI::errstr . " $query");
    $error_result = 500;
    return;
  };

  if (&check_privileged_access()) {&auto_approve();}
}

################################################################################
sub get_nearby()
################################################################################
{
  my ($lat, $lon, $m) = @_;
  wsyslog('info', "get_nearby(" . "$lat $lon $m)");
  ($minlat, $minlon) = get_latlon_offset_bbox($lat, $lon, -1 * $m, -1 * $m);
  ($maxlat, $maxlon) = get_latlon_offset_bbox($lat, $lon, $m, $m);
  $BBOX = 1;
  $OUTPUT_FORMAT = "geojson";
  &output_all();
}

################################################################################
sub get_latlon_offset_bbox()
################################################################################
{
  my ($lat, $lon, $mx, $my) = @_;

 $R = 6378137;
 $dn = $mx;
 $de = $my;
 $dLat = $dn / $R;
 $dLon = $de / ($R * cos(3.14159269 * $lat / 180));
 $o_lat = $lat + $dLat * 180 / 3.14159269;
 $o_lon = $lon + $dLon * 180 / 3.14159269;

 return ($o_lat,  $o_lon);
}

################################################################################
sub get_tags()
################################################################################
{
  my ($id) = @_;
  my $out = "";
  my @out_array;
  my $query = "select * from tags where gp_id=$id";

  my $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "get_tags dberror " . $DBI::errstr . " q: $query");
    $out = "get_tags: DB error";
    return $out;
  };

  my $i = 0;
  foreach my $row (@$res) {
    if (@$row[3] ne "") {
      $out_array[$i++] .= @$row[2] . ":" . @$row[3];
    } else {
      $out_array[$i++] .= @$row[2];
    }
  }

  if ($OUTPUT_FORMAT eq "json"){
    $out = encode_json(\@out_array);
  } else {
    $out .= join(";", @out_array);
  }

  return $out;
}

################################################################################
sub tag_query()
################################################################################
{
 my ($k, $v) = @_;
  my $query = "select * from tags where k like '".$k."' and v like '".$v."'";

  my $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "tag_query  dberror " . $DBI::errstr . " q: $query");
    return 1;
  };

  $count = scalar @{ $res };

  wsyslog("info", "tag_query q: $query c: $count");
  return $count;
}

################################################################################
sub tag_exists()
################################################################################
{
 my ($id, $k, $v) = @_;
  my $query = "select * from tags where gp_id=$id and k='".$k."' and v='".$v."'";

  my $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "tag_exists  dberror " . $DBI::errstr . " q: $query");
    return 1;
  };

  $count = scalar @{ $res };

  wsyslog("info", "tag_exists q: $query c: $count");
  return $count;
}

################################################################################
sub auto_approve()
################################################################################
{
  my $last_id = $dbh->sqlite_last_insert_rowid();
  wsyslog("info", "change id for autoapprove:" . $last_id);
  &approve_edit($last_id);
}

################################################################################
sub add_tags()
################################################################################
{
  my ($id, $tag) = @_;
  my ($k, $v) = split(":", $tag);

  wsyslog('info', $remote_ip . " wants to add tag ($k:$v) for id:$id");

  if ($id eq "" or $k eq "" and $v eq "") {
    $error_result = 400;
    return;
  }

  if (&tag_exists($id, $k, lc $v) or &tag_exists($id, $k, uc $v)) {
    $error_result = 400;
    return;
  }

  $query = "insert into changes (gp_id, col, value, action) values ($id, '$k', '$v', 'addtag')";


  my $sth = $dbh->prepare($query) or do {
    wsyslog("info", "500: add_tags($tag): prepare dbi error " . $DBI::errstr);
    $error_result = 500;
  };

  my $res = $sth->execute() or do {
    wsyslog("info", "500: add_tags($tag): dbi error " . $DBI::errstr);
    $error_result = 500;
  };

  wsyslog('info', $remote_ip . " added tag ($k:$v) for id:$id");

  &auto_approve();
}

################################################################################
sub delete_tags()
################################################################################
{
  my ($id, $tag) = @_;
  my ($k, $v) = split(":", $tag);

  if ($k eq "" and  $v eq "") {
    $error_result = 400;
    return;
  }

  my $query = "insert into changes (gp_id, col, value, action) values ($id, '$k', '$v', 'deltag')";
  wsyslog("info", "delete_tags($tag):" . $query);
  wsyslog('info', $remote_ip . " wants to delete tag ($k:$v) for id:$id");

  my $sth = $dbh->prepare($query);
  my $res = $sth->execute();

  if (!$res) {
    wsyslog("info", "500: add_tags($tag): dbi error " . $DBI::errstr);
    $error_result = 500;
  } else {
    if (&check_privileged_access()) {&auto_approve();}
  }
}

################################################################################
sub get_exif_data()
################################################################################
{
  my $image_location = $image_root;
  my ($id, $ret_group, $ret_tag) = @_;
  my $image_file = &get_gp_column_value($id, 'url');
  my $out = "";
  my $image = $image_location."/".$image_file;

#  syslog("info", "exif: " . $image);
  my $exifTool = new Image::ExifTool;
  $exifTool->Options(Unknown => 1);
  my $info = $exifTool->ImageInfo($image);
  my $group = '';
  my $tag;
  foreach $tag ($exifTool->GetFoundTags('Group0')) {
    if ($group ne $exifTool->GetGroup($tag)) {
      $group = $exifTool->GetGroup($tag);
    }
    my $val = $info->{$tag};
    if (ref $val eq 'SCALAR') {
      if ($$val =~ /^Binary data/) {
        $val = "($$val)";
      } else {
        my $len = length($$val);
        $val = "(Binary data $len bytes)";
      }
    }
    $exifdata{$group}{$exifTool->GetDescription($tag)} = $val;
  }

  return $exifdata{$ret_group}{$ret_tag};
}

################################################################################
sub exif()
################################################################################
{
  my $image_location = $image_root;
  my ($id) = @_;
  my $image_file = &get_gp_column_value($id, 'url');
  my $out = "";
  my $image = $image_location."/".$image_file;

#  syslog("info", "exif: " . $image);
  my $exifTool = new Image::ExifTool;
  $exifTool->Options(Unknown => 1);
  my $info = $exifTool->ImageInfo($image );
  my $group = '';
  my $tag;
  foreach $tag ($exifTool->GetFoundTags('Group0')) {
    if ($group ne $exifTool->GetGroup($tag)) {
      $group = $exifTool->GetGroup($tag);
#      $out .= "---- $group ----\n";
    }
    my $val = $info->{$tag};
    if (ref $val eq 'SCALAR') {
      if ($$val =~ /^Binary data/) {
        $val = "($$val)";
      } else {
        my $len = length($$val);
        $val = "(Binary data $len bytes)";
      }
    }
#    $out .= sprintf("%-32s : %s\n", $exifTool->GetDescription($tag), $val);
    $exifdata{$group}{$exifTool->GetDescription($tag)} = $val;
  }

  if ($OUTPUT_FORMAT eq "geojson" or $OUTPUT_FORMAT eq "kml") {
    #Bad Request
    $error_result = 400;
    return;
  } elsif ($OUTPUT_FORMAT eq "html") {
    $out .= "<table>\n";
    foreach $item (keys %exifdata) {
      $out .= "<tr>\n";
      $out .= "<th>$item</th>";
      $out .= "</tr>\n";
      foreach $iteminitem (keys %{$exifdata{$item}}){
      $out .= "<tr>\n";
        $out .= "<td>$iteminitem</td> <td>$exifdata{$item}{$iteminitem}</td>";
      $out .= "</tr>\n";
      }
    }
    $out .= "</table>\n";
    $r->print($out);
  } elsif ($OUTPUT_FORMAT eq "json") {
    $r->print(encode_json(\%exifdata));
  }

}

################################################################################
sub robot()
################################################################################
{
  wsyslog('info', "robot run!");

  my $query = "select * from changes";

  $res = $dbh->selectall_arrayref($query);
  if (!$res) {
    $error_result = 500;
    wsyslog('info', "500: robot error: $DBI::errstr");
    return Apache2::Const::SERVER_ERROR;
  };

  foreach my $row (@$res) {
    my ($id, $gp_id, $col, $value, $action) = @$row;
    if ($action eq "addtag") {
      wsyslog('info', "robot added tag: ($id, $gp_id, $col, $value, $action)");
      my $url = "http://" . $hostname . "/table/approve/" . $id;
      wsyslog('info', "robot: get $url");
      my $content = get($url);
      wsyslog('info', "robot: " . $content);
      $r->print("addtag returned $content ");
    } elsif ($action eq "edit") {
       my $old_value = get_gp_column_value($gp_id, $col);
       if ($old_value eq "" or $old_value eq "none") {
         wsyslog('info', "robot adding new value: old is ($old_value) new is ($id, $gp_id, $col, $value, $action)");
         my $url = "http://" . $hostname . "/table/approve/" . $id;
         my $content = get($url);
         $r->print("edit returned $content ");
       } else {
         wsyslog('info', "robot NOT adding new value: old is ($old_value) new is ($id, $gp_id, $col, $value, $action)");
       }
    } else {
    }
  }
}

################################################################################
sub logout()
################################################################################
{
  wsyslog('info', "logout: $user ...");
  my $query = "delete from session where username=?";
  db_do2($query, $user);
}

################################################################################
sub login_github()
################################################################################
{
  my $client_id = $githubclientid;
  my $uri_redirect = "https://github.com/login/oauth/authorize?client_id=$client_id";

  $r->print("<html>");
  $r->print("<head>");
  $r->print("<meta http-equiv='REFRESH' content='1;url=$uri_redirect'>");
  $r->print("</head>");
  $r->print("<body>");
  $r->print("<p>this will log you in with github and send you back to landing page, ");
  $r->print("or do it <a href='$uri_redirect'>yourself</a></p>");
  $r->print("</body>");
  $r->print("</html>");
}

################################################################################
sub login_nextcloud()
################################################################################
{
  my $client_id = $nextcloudclientid;
  my $uri_redirect = "https://cloud.grezl.eu/index.php/apps/oauth2/authorize?";
  $uri_redirect .= "response_type=code&";
  $uri_redirect .= "client_id=$client_id&";
  $uri_redirect .= "state=yo&";
  $uri_redirect .= "redirect_uri=https://api.openstreetmap.social/table/oknextcloud";

  $r->print("<html>");
  $r->print("<head>");
  $r->print("<meta http-equiv='REFRESH' content='1;url=$uri_redirect'>");
  $r->print("</head>");
  $r->print("<body>");
  $r->print("<p>this will log you in with nextcloud and send you back to landing page, ");
  $r->print("or do it <a href='$uri_redirect'>yourself</a></p>");
  $r->print("</body>");
  $r->print("</html>");
}

################################################################################
sub login_ok_github()
################################################################################
{

  my $code = shift;

  my $url = 'https://github.com/login/oauth/access_token';
  my $ua = LWP::UserAgent->new(); 

  my %form;
  $form{'client_id'} = $githubclientid;
  $form{'client_secret'} = $githubclientsecret;
  $form{'code'} = $code;
  #$form{'redirect_uri'}='';
  #$form{'state'}='';

  my $response = $ua->post($url, \%form);
  my $content = $response->decoded_content();

  my %oauth2_data = &parse_query_str($content);
  my $acc = %oauth2_data{access_token};

  if ($acc eq "") {
    $error_result = 400;
    wsyslog("info", "400: oauth2 no acc ($acc)");
    return;
  }

  $r->headers_out->set("X-AuthW" => $acc);

  my $uri_redirect = "http://api.openstreetmap.social/webapps/login.html";

  $url = "https://api.github.com/user?access_token=$acc";
  my $response = $ua->get($url);
  my $content = $response->decoded_content();

  my $parsed = decode_json($content);
  my $oauth_user = $parsed->{login};
  $oauth_user .= '@github';

  #fixme check github response

  my $sessid = $request_id."-".time();

  wsyslog("info", "login_ok_github:$oauth_user");

  $c_out = Apache2::Cookie->new($r,
             -name  => "oauth2sessid",
             -value => $sessid,
             -expires => '+10d',
  );
  $c_out->path("/");
  $c_out->bake($r);

  $query = "insert into session (acc, sessid, username) values ('$acc', '$sessid', '$oauth_user')";
  my $sth = $dbh->prepare($query);
  my $res = $sth->execute() or do {
    wsyslog("info", "500: oauth2 ok  " . $DBI::errstr . " $query");
    $error_result = 500;
    return;
  };

  $login_redirect = "http://api.openstreetmap.social/webapps/login.html";
  #$login_redirect = "http://grezl.eu/login.html";

  $r->print("<html>");
  $r->print("<head>");
  $r->print("<meta http-equiv='REFRESH' content='1;url=$login_redirect'>");
  $r->print("</head>");
  $r->print("<body>");
  $r->print("<p>login ok? ....</p> <pre>$content </pre>");

  $r->print("<h1>~=." . $parsed->{login} . " .=~</h1>");

  $r->print("<pre>" . Dumper(\%oauth2_data) . "</pre>");
  $r->print("<pre>" . Dumper(\$parsed) . "</pre>");
  $r->print("<pre>" .$response->as_string() . "</pre>");


  $r->print("</body>");
  $r->print("</html>");
}

################################################################################
sub login_ok_nextcloud()
################################################################################
{

  my $code = shift;

  my $url = 'https://cloud.grezl.eu/index.php/apps/oauth2/api/v1/token';
  my $ua = LWP::UserAgent->new();
  my %form;
  my %oauth2_data;

  $form{'client_id'} = $nextcloudclientid;
  $form{'client_secret'} = $nextcloudclientsecret;
  $form{'code'} = $code;
  $form{'grant_type'} = 'authorization_code';
  $form{'redirect_uri'} = "http://api.openstreetmap.social/webapps/login.html";
  $form{'state'}='yo';

  my $response = $ua->post($url, \%form);
  my $content = $response->decoded_content();

  $oauth2_data = decode_json($content);

  my $acc = $oauth2_data->{access_token};
  my $error = $oauth2_data->{error};
  my $user = $oauth2_data->{user_id};

  if ($error ne "") {
    $error_result = 400;
    wsyslog("info", "400: oauth2 returned error ($error)");
    return;
  }

  if ($acc eq "") {
    $error_result = 400;
    wsyslog("info", "400: oauth2 no acc ($acc)");
    return;
  }

#  my $uri_redirect = "http://api.openstreetmap.cz/webapps/login.html";
#  $r->headers_out->set("X-AuthW" => $acc);
#  $url = "https://cloud.grezl.eu/ocs/v1.php/cloud/users/$user";
#  $ua->default_header("Authorization" => "Bearer $acc");
#  my $response = $ua->get($url);
#  my $content = $response->decoded_content();
# my $parsed = decode_json($content);

  my $oauth_user = $user;
  $oauth_user .= '@cloud.grezl.eu';

  my $sessid = $request_id."-".time();

  wsyslog("info", "login_ok_nextcloud:$oauth_user");

  $c_out = Apache2::Cookie->new($r,
             -name  => "oauth2sessid",
             -value => $sessid,
             -expires => '+10d',
  );
  $c_out->path("/");
  $c_out->bake($r);

  $query = "insert into session (acc, sessid, username) values ('$acc', '$sessid', '$oauth_user')";
  my $sth = $dbh->prepare($query);
  my $res = $sth->execute() or do {
    wsyslog("info", "500: oauth2 ok  " . $DBI::errstr . " $query");
    $error_result = 500;
    return;
  };

  $login_redirect = "http://api.openstreetmap.social/webapps/login.html";

  $r->print("<html>");
  $r->print("<head>");
  $r->print("<meta http-equiv='REFRESH' content='1;url=$login_redirect'>");
  $r->print("</head>");
  $r->print("<body>");
  $r->print("<p>login ok ....</p>");

  $r->print("<h1>~=." . $oauth_user . " .=~</h1>");

  $r->print("</body>");
  $r->print("</html>");
}

################################################################################
sub notify()
################################################################################
{
  my ($lat, $lon, $text) = @_;
  wsyslog('info', "Notification: $lat, $lon, $text");
}

################################################################################
sub show_licenses()
################################################################################
{
  my $out = "";
  my $i;
  my %licenses = (
    'CCBYSA4'=>'Creative Commons Attribution ShareAlike 4.0',
    'CCBYSA3'=>'Creative Commons Attribution ShareAlike 3.0',
    'CCBY4'=>'Creative Commons Attribution 4.0',
    'CCBY3'=>'Creative Commons Attribution 3.0',
    'CCBYSA2plus'=>'Creative Commons Attribution ShareAlike 2.0 or later',
    'CC0'=>'Creative Commons CC0 Waiver',
    'C'=>'Zákon č. 121/2000 Sb.',
  );

  my %license_sites = (
    'CCBYSA4'=>'https://creativecommons.org/licenses/by-sa/4.0/',
    'CCBYSA3'=>'https://creativecommons.org/licenses/by-sa/3.0/',
    'CCBY4'=>'https://creativecommons.org/licenses/by/4.0/',
    'CCBY3'=>'https://creativecommons.org/licenses/by/3.0/',
    'CCBYSA2plus'=>'https://creativecommons.org/licenses/by-sa/2.0/',
    'CC0'=>'https://creativecommons.org/choose/zero/',
    'C'=>'https://portal.gov.cz/app/zakony/zakonPar.jsp?idBiblio=49278&nr=121~2F2000&rpp=15#local-content',
  );

  if ($OUTPUT_FORMAT eq "html") {
    $out .= page_header();
    $out .= "<h1>".&t("Known licenses")."</h1>\n";
    $out .= "<table border='1'>\n";
    foreach $i (keys %licenses) {
      $out .= "<tr><td>";
      $out .= "<a href='".$license_sites{$i}."'>" . $licenses{$i} ."</a>";
      $out .= "</td></tr>\n";
    }
    $out .= "</table>\n";
    $out .= page_footer();

    $r->print($out);

  } elsif ($OUTPUT_FORMAT eq "geojson") {
    $error_result = 400;
  } elsif ($OUTPUT_FORMAT eq "json") {
    %out = ("licenses" => \%licenses, "sites" => \%license_sites);
    $r->print(encode_json(\%out));
  } else {
    $error_result = 400;
  }

}

################################################################################
sub get_time_added
################################################################################
{
  my ($id) = @_;
  my $out = "nic";

  wsyslog('info', "get_time_added($id)");

  my $query = "select sqltime from time where gp_id=?";
  my $sth = $dbh->prepare($query);
  $sth->execute($id);

  my @row = $sth->fetchrow_array() or do {
    if ($sth->err) {
      wsyslog("info", "get_time_added dberror " . $DBI::errstr . " q: $query");
      $error_result = 400;
      return;
    } else {
      wsyslog("info", "get_time_added dberror empty q: $query");
      $error_result = 404;
      return;
    }
    $error_result = 400;
    return;
  };

  $out = $row[0];
  $r->print($row[0]);
}

################################################################################
sub get_time_taken
################################################################################
{
  my ($id) = @_;
  wsyslog('info', "get_time_taken($id)");
  my $out = &get_exif_data($id, "EXIF", "Create Date");
  $r->print($out);
}

################################################################################
sub add_to_project
################################################################################
{

  my ($gp_id, $prj_id) = @_;

  $query = "insert into prjgp (gp_id, prj_id) values ($gp_id, $prj_id)";

  wsyslog('info', "adding $gp_id into project ...");
  my $sth = $dbh->prepare($query) or do {
    wsyslog('info', "500: prepare error, query is:" . $query);
    $error_result = 500;
    return;
  };

  $sth->execute() or do {
    wsyslog("info", "500: add_to_project dbi error " . $DBI::errstr);
  };

 $r->print("a");

}

################################################################################
sub project_uri_param
################################################################################
{
  my $r;
  if ($PROJECT ne "") {
    $r = "&project=$PROJECT";
  } else {
    $r = "";
  }
  return $r;
}

################################################################################
sub get_project_id
################################################################################
{
  my $what = shift;

  if (looks_like_number($what)) {
    return $what;
  } else {
    return &resolve_project($what);
  }
}

################################################################################
sub resolve_project
################################################################################
{
  my $what = shift;
  my $query;

  if (!$what) {
    wsyslog('info', "resolve: no param.");
    return;
  }

  wsyslog('info', "resolving " . $what . ".");

  if (looks_like_number($what)) {
    wsyslog('info', "id to name");
    $query = "select name from project where id=?";
  } else {
    wsyslog('info', "name to id");
    $query = "select id from project where name=?";
  }

  my $sth = $dbh->prepare($query);
  my $rv = $sth->execute($what) or do {
    wsyslog('info', "500: resolve, query:" . $query);
    $error_result = 500;
    return;
  };

  my @row = $sth->fetchrow_array();
  $count = scalar @row;
  if ($count) {
    wsyslog('info', "resolved: " . $row[0] . ".");
    return $row[0];
  } else {
    wsyslog('info', "resolved: nothing found");
    return;
  }
}

################################################################################
sub get_protocol
################################################################################
{
  if ($is_https) {
    $https = "https";
  } else {
    $https = "http";
  }
}

################################################################################
sub list_projects
################################################################################
{
  my $out = "";
  my $id = shift;

  my $query = "select name,maintainer from project";

  my $res = $dbh->selectall_arrayref($query) or do {
    wsyslog("info", "500: list_projects(): dberror:" . $DBI::errstr . " q: $query");
    $error_result = 500;
    return;
  };

  my @outproject = (@$res);

  if ($OUTPUT_FORMAT eq "json"){
    $out .= encode_json($res);
#    $out .= encode_json(\@outproject);
  } elsif ($OUTPUT_FORMAT eq "html"){
    $out .= &page_header();
    $out .= "<ol>\n";
    foreach my $i (@$res) {
      $out .= "<li>\n";
      my $prj_name = @$i[0]."\n";
      my $prj_owner = @$i[1]."\n";
      my $url = &get_protocol() . "://" . $hostname . "/" . $api_version . "/" . "all" . "?project=" . $prj_name;
      $out .= "<a href='$url'>\n";
      $out .= $prj_name." ($prj_owner)\n";
      $out .= "</a>\n";
    };
    $out .= "</ol>\n";
    $out .= &page_footer();

  } else {
    foreach my $i (@$res) {
      $out .= @$i[0]."\n";
    };
  }

  $r->print($out);
}


################################################################################
sub add_project
################################################################################
{
  my $what = shift;

  wsyslog("info", "add $what");

  my $query = "insert into project (id, name) values (null, ?)";
  wsyslog('info', "add project " . $query);
  &db_do2($query, $what);
}

################################################################################
sub remove_project
################################################################################
{
  my $project = shift;
  my $prj_id = &resolve_project($project);

  if (&project_image_count($prj_id)) {
    wsyslog("info", "del $project $prj_id not empty");
    $error_result = 412;
    return;
  }

  my $query = "delete from project where id = ?";

  wsyslog("info", "del $project $prj_id $query");

  my $res = $dbh->do($query, undef, $prj_id) or do {
    wsyslog("info", "500: remove_project($gp_id, $project): dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };

}

################################################################################
sub project_image_count
################################################################################
{
  my ($prj_id) = @_;
  my $query = "select count(*) from prjgp where prj_id=?";

  wsyslog("debug", "project_image_count id:$prj_id");

  my $sth = $dbh->prepare($query)  or do {
    wsyslog("info", "500: project_image_count($prj_id): prepare dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };
  my $rv = $sth->execute($prj_id) or do {
    wsyslog("info", "500: project_image_count($prj_id): execute dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };

  my @row = $sth->fetchrow_array();
  wsyslog("debug", "project_image_count" .  Dumper(\@row) . " " . $row[0]);
  return $row[0];
}

################################################################################
sub is_assigned
################################################################################
{
  my ($gp_id, $prj_id) = @_;
  my $query = "select * from prjgp where gp_id=? and prj_id=?";

  wsyslog("debug", "is_assigned $gp_id, $prj_id");

  my $sth = $dbh->prepare($query)  or do {
    wsyslog("info", "500: is_assigned($gp_id, $prj_id): prepare dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };
  my $rv = $sth->execute($gp_id, $prj_id) or do {
    wsyslog("info", "500: is_assigned($gp_id, $prj_id): execute dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };

  my @row = $sth->fetchrow_array();
  return (scalar @row > 0);
}

################################################################################
sub assign_to_project
################################################################################
{
  my ($gp_id, $project) = @_;
  my $prj_id = &resolve_project($project);
  my $query = "insert into prjgp values (null, ?, ?)";

  wsyslog("info", "trying assign_to_project($gp_id, $project)");

  if (!defined $prj_id) {
    wsyslog("info", "undefined ");
    $error_result = 412;
    return;
  }

#fixme make some function out of this
  $maintainer = &get_project_maintainer($project);

  if ($maintainer ne $user) {
    wsyslog("info", "action denied, user is not maintainer");
    $error_result = 403;
    return;
  }

  if ($user eq "anon.openstreetmap.social") {
    wsyslog("info", "action denied, must be logged in");
    $error_result = 401;
    return;
  }

  wsyslog("info", "assign $gp_id to $project id $prj_id ");

  if (!&is_assigned($gp_id, $prj_id)) {
    wsyslog("info", "doing ($gp_id, $project)");
    my $res = $dbh->do($query, undef, $gp_id, $prj_id) or do {
      wsyslog("info", "500: assign_to_project($gp_id, $project): dbi error " . $DBI::errstr);
      $error_result = 500;
      return;
    };
  } else {
    wsyslog("info", "is_assigned, not doing anything ");
  }
}

################################################################################
sub remove_from_project
################################################################################
{
  my ($gp_id, $project) = @_;
  my $prj_id = &resolve_project($project);

  wsyslog("info", "$user is trying to reomve $gp_id from $project ($prj_id)");

  if (!defined $prj_id) {
    wsyslog("info", "undefined ");
    $error_result = 412;
    return;
  }

  $maintainer = &get_project_maintainer($project);

  if ($maintainer ne $user) {
    wsyslog("info", "action denied, user is not maintainer");
    $error_result = 403;
    return;
  }

  if ($user eq "anon.openstreetmap.social") {
    wsyslog("info", "action denied, must be logged in");
    $error_result = 401;
    return;
  }

  my $query = "delete from prjgp where gp_id=? and prj_id=?";

  my $res = $dbh->do($query, undef, $gp_id, $prj_id) or do {
    wsyslog("info", "500: remove_from_project($gp_id, $project): dbi error " . $DBI::errstr);
    $error_result = 500;
    return;
  };
}

################################################################################
sub list_assigned
################################################################################
{
  my ($project) = @_;
  my $out = "";
  my $query = "select guidepost.id, guidepost.url from  guidepost,prjgp where prjgp.prj_id=? and guidepost.id=prjgp.gp_id;";

  $prj_id = &resolve_project($project);

  wsyslog("info", "list_assigned prj_id:" . $prj_id);

  my $res = $dbh->selectall_arrayref($query, undef, $prj_id) or do {
    wsyslog("info", "list_assigned db error" . $DBI::errstr);
    $out = "list_assigned: DB error";
    $error_result = 500;
    return 500;
  };

#get project maintainer

  if ($OUTPUT_FORMAT eq "html") {
    foreach my $row (@$res) {
      my ($id, $url) = @$row;
      $out .=  "$id $url\n";
    }
    $r->print($out);
  } elsif ($OUTPUT_FORMAT eq "json") {
    my %x;
    $x{imgs} = $res;
    $x{manager} = &get_project_maintainer($project);
    $out = encode_json(\%x);
    $r->print($out);
  } else {
    $r->print($out);
  }

}

################################################################################
sub get_session_username
################################################################################
{
  my $sessid = shift;

  wsyslog("info", "get_session_username $sessid");

  if ($sessid eq "") {
    return "";
  }

  my $query = "select username from session where sessid=?";
  my $sth = $dbh->prepare($query) or return "";
  my $rv = $sth->execute($sessid) or return "";
  my @row = $sth->fetchrow_array();
  return $row[0];
}

################################################################################
sub get_project_maintainer
################################################################################
{
  my $name = shift;
  my $query = "select maintainer from project where name=?";

  wsyslog("debug", "get__project_maintainer $query $name");

  my $sth = $dbh->prepare($query) or do {
    wsyslog("info", "get_project_maintainer dberror " . $DBI::errstr . " q: $query");
    return "";
  };;

  $sth->execute($name) or do {
    wsyslog("info", "get_project_maintainer dberror " . $DBI::errstr . " q: $query");
    return "";
  };

  my @row = $sth->fetchrow_array();
  return $row[0];
}

1;
