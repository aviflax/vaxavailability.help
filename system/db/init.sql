START TRANSACTION ISOLATION LEVEL SERIALIZABLE;

------ Feeds ------

create schema feed;

create type feed.state_or_territory as enum(
  'AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'FL', 'GA', 'HI', 'ID', 'IL', 'IN', 'IA', 'KS',
  'KY', 'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO', 'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY',
  'NC', 'ND', 'OH', 'OK', 'OR', 'PA', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV',
  'WI', 'WY', 'DC', 'AS', 'GU', 'MP', 'PR', 'UM', 'VI');

create table feed.feeds (
  id                  varchar(64) primary key,
  state_or_territory  feed.state_or_territory not null,
  name                varchar(256) unique not null,
  data_url            varchar(4096) unique not null,
  notes               text null
);

create index on feed.feeds (state_or_territory);

create table feed.updates (
  id        serial primary key,
  feed_id   varchar(64) references feed.feeds not null,
  ts        timestamp with time zone not null default now(),
  data      jsonb not null,
  note      text null  -- for things like e.g. “I manually retrieved, modified, and inserted this update because blah blah blah.”
);


------ Providers ------

-- “provider” rather than “location” because e.g. what about “mobile” providers that e.g. do housecalls!
create schema provider;

create table provider.providers (
  id               varchar(128) primary key,
  feed_id          varchar(64) references feed.feeds not null,
  initial_name     varchar(256) unique not null,
  initial_address  varchar(256) null,  -- Not currently handling changes to these 😅
  note             text null
);

comment on column provider.providers.initial_name is
  'This is not meant to be used by the app; it’s really just for convenience when scanning/browsing'
  ' the data';

create index on provider.providers (feed_id);

create table provider.names (
  provider_id  varchar(128) references provider.providers not null,
  name         varchar(1000) not null,
  ts           timestamp with time zone not null default now(),
  note         text null,

  primary key (provider_id, name)
);

create index on provider.names (provider_id);
create index on provider.names (name);

create view provider.current_name as
select distinct on (provider_id) provider_id, name, ts, note
from provider.names
order by provider_id, ts DESC;

create or replace view provider.with_current_name as
select p.id, f.state_or_territory, n.name, p.initial_address, p.note
from provider.providers p
  left join feed.feeds f on p.feed_id = f.id
  left outer join provider.current_name n on p.id = n.provider_id;

create table provider.state_changes (
  provider_id             varchar(128) references provider.providers not null,
  feed_update_id          integer references feed.updates not null,
  ts                      timestamp with time zone not null default now(),
  appointments_available  bool not null,
  note                    text null,

  primary key (provider_id, feed_update_id)
);

create index on provider.state_changes (provider_id);
create index on provider.state_changes (feed_update_id);
create index on provider.state_changes (ts);
create index on provider.state_changes (appointments_available);

create view provider.current_state as
select distinct on (provider_id) provider_id, ts, appointments_available, note
from provider.state_changes
order by provider_id, ts desc;

create or replace view provider.with_current_state as
select p.id, p.feed_id, cn.name, p.note, cs.appointments_available, cs.ts as state_change_ts,
       cs.note as state_change_note
from provider.providers p
  left join provider.current_name cn on p.id = cn.provider_id
  left join provider.current_state cs on p.id = cs.provider_id
order by cs.ts;


------ Subscriptions ------

create schema subscription;

create table subscription.subscriptions (
  id         serial primary key,
  email      varchar(500) not null,
  
  -- If null, we’ll default to `en` in the app code. But I want to preserve that we don’t know the
  -- person’s actual preference.
  language   varchar(5) null CHECK (language is null or language ~* '^[a-zA-Z]{2}(-[a-zA-Z]{2})?$'),
  
  nonce      varchar(200) not null
);

create index on subscription.subscriptions (lower(email));

-- new: the verification email has not yet been sent
-- pending-verification: the verification email has been sent; the link in it has not yet been opened
-- active: the link in the verification email was opened; we will send notifications
-- canceled: the recipient has canceled the subscription; we will not send any emails at all
create type subscription.state as enum ('new', 'pending-verification', 'active', 'canceled');

create table subscription.state_changes (
  subscription_id  integer references subscription.subscriptions not null,
  ts               timestamp with time zone not null default now(),
  state            subscription.state not null,
  note             text null,

  primary key (subscription_id, ts)
);

create index on subscription.state_changes (subscription_id);
create index on subscription.state_changes (state);

create view subscription.current_state as
select distinct on (subscription_id) subscription_id, state, ts, note
from subscription.state_changes
order by subscription_id, ts desc;

create view subscription.with_current_state as
select s.*, cs.state, cs.ts as state_change_ts, cs.note as state_change_note
from subscription.subscriptions s
  left join subscription.current_state cs on s.id = cs.subscription_id
order by cs.ts;

create table subscription.subscriptions_providers (
  subscription_id  integer references subscription.subscriptions not null,
  provider_id      varchar(128) references provider.providers not null,
  primary key (subscription_id, provider_id)
);

create index on subscription.subscriptions_providers (subscription_id);
create index on subscription.subscriptions_providers (provider_id);


------ Events ------

-- create schema event;

-- create table event.type (
--   id    serial primary key,
--   name  varchar(256) unique not null
-- );

-- create type event.subject_type as enum ('feed', 'provider', 'subscription');

-- create table event.events (
--   id                serial primary key,
--   ts                timestamp with time zone not null default now(),
--   event_type_id     integer references event.type,
--   subject_type      event.subject_type not null,
--   feed_id           integer references feed.feeds null,
--   subscription_id   integer references subscription.subscriptions null,
--   note              text
-- );

-- -- We need one of these for any many-to-many relationship between events and anything else, right?
-- create table event.events_providers (
--   event_id     integer references event.events,
--   provider_id  integer references provider.providers not null,

--   primary key (event_id, provider_id)
-- );

-- -- TODO: should we have a similar index with the col order swapped?
-- create index on event.events (ts);
-- create index on event.events (event_type_id);
-- create index on event.events (subscription_id);

COMMIT TRANSACTION;
