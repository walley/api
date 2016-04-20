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
