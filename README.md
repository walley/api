# api
api, backend, scripts

You need to have mod_perl from http://perl.apache.org/ installed.


##apache configuration

<DirectoryMatch "^/.*/\.git/">
  Order deny,allow
  Deny from all
</DirectoryMatch>

Header set Access-Control-Allow-Origin "*"
PerlRequire /var/www/api/handler/startup.pl
PerlSetVar ReloadAll Off

<Location /table>
  SetHandler perl-script
  PerlResponseHandler Guidepost::Table
  PerlOptions +ParseHeaders
</Location>

<Location /commons>
  SetHandler perl-script
  PerlResponseHandler Guidepost::Commons
  PerlOptions +ParseHeaders
</Location>

##sqlite3 schema

CREATE TABLE changes (
  id integer primary key AUTOINCREMENT,
  gp_id integer,
  col varchar,
  value varchar,
  action varchar
);

CREATE TABLE guidepost (
  id integer primary key AUTOINCREMENT,
  lat numeric,
  lon numeric,
  url varchar,
  name varchar,
  attribution varchar,
  ref varchar,
  note varchar
);

create table tags (
  id integer primary key AUTOINCREMENT,
  gp_id integer,
  k varchar,
  v varchar
);

##dirs:
commons - bunch of scripts used to create commons db
handler - mod_perl handlers


##guidepost api:

see editor_help.html
