# api
api, backend, scripts

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
