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
  openlog('guidepostapi', 'cons,pid', 'user');
   return Apache2::Const::OK;
}

1;
