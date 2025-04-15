# what is this?
Guidepost api, and things needed to run it.

Guidepost is Spatially Aware Web Image Database

Our spatially aware web image database allows users to explore and visualize images based on their geographical locations. Each image is tagged with precise location data, enabling it to be displayed on interactive maps. This feature facilitates easy navigation and discovery of images by zooming into specific areas, viewing clusters of images, and tracing visual documentation across different regions. Ideal for researchers, travelers, and enthusiasts, our database merges the visual and spatial realms, offering a unique and intuitive way to engage with geographical imagery.

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


