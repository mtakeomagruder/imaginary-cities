------------------------------------------------------------------------------------------------------------------------------------
-- Schema to store image metadata
------------------------------------------------------------------------------------------------------------------------------------

-- drop database icities;
-- drop user icities_etl;
-- drop user icities;

create role icities;
create user icities_etl password 'icities_etl';

create database icities owner icities;
\c icities

set session authorization icities;

create schema image;

grant usage on schema image to icities_etl;

create table image.image
(
    id bigint not null,
    name text not null,
    url text not null,
    sha1 text not null,
    constraint image_pk primary key (id),
    constraint image_name_unq unique (name),
    constraint image_url_unq unique (name),
    constraint image_sha1_unq unique (sha1)
);

grant select, insert on image.image to icities_etl;

create table image.image_data
(
    image_id bigint not null,
    day date not null,
    view bigint not null,
    keyword text not null,
    constraint image_data_pk primary key (image_id, day),
    constraint image_data_imageid_fk foreign key (image_id) references image.image (id)
);

grant select, insert on image.image_data to icities_etl;
