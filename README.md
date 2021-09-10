# what is this?
Guidepost api, and things needed to run it.
Guidepost is spatially aware image database. You can show images on maps and more.
You need to have mod_perl2 from http://perl.apache.org/ installed.
API specs and help: http://api.openstreetmap.social/editor-help.html.

# apache configuration

```

  Header set Access-Control-Allow-Origin "*"
  PerlRequire /var/www/api/handler/startup.pl
  PerlSetVar ReloadAll Off
  PerlSetVar dbpath "/var/www/somewhere/"
  PerlSetVar githubclientid "5e6294rt234523454e"
  PerlSetVar githubclientsecret "1324tr5324510df3d300f"
  PerlSetVar nextcloudclientid "ZvF90bzrKK"
  PerlSetVar nextcloudclientsecret "S7V6ttyewf3435"

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

  <Location /upload>
    SetHandler perl-script
    PerlResponseHandler Guidepost::Upload
    PerlOptions +ParseHeaders
  </Location>

```

# sqlite3 schema

* guidepost db

```sql
CREATE TABLE guidepost (                                       
  id integer primary key AUTOINCREMENT,
  lat numeric,                                                                  
  lon numeric,                                                                  
  url varchar,                                                                  
  name varchar,                                                                 
  attribution varchar, 
  ref varchar, 
  note varchar, 
  license varchar
);

CREATE TABLE changes (
id integer primary key AUTOINCREMENT,
gp_id integer,
col varchar,
value varchar, action varchar
);

CREATE TABLE tags ( 
id integer primary key AUTOINCREMENT, 
gp_id integer, 
k varchar, 
v varchar 
);

CREATE TABLE time (
  id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  gp_id integer,
  sqltime TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE INDEX lat ON guidepost (lat);
CREATE INDEX lon ON guidepost (lon);

```

* commons db

```sql
CREATE TABLE commons(
id integer primary key AUTOINCREMENT,
lat numeric,
lon numeric,
name varchar,
desc varchar
);
```

# dirs
* commons-scripts - bunch of scripts used to create commons db
* handler - mod_perl handlers
* webapps - web applications that use the api


