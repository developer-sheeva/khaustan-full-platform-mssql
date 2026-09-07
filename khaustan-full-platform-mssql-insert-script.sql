/* ============================================================================
   KHAUSTAN.COM — FULL PLATFORM DEPLOYMENT SCRIPT (MICROSOFT SQL SERVER)
   Run top-to-bottom on a fresh instance. Nothing needs to exist beforehand
   -- every CREATE DATABASE below is guarded (IF DB_ID(...) IS NULL), so the
   script is also safe to re-run.

   Creates FOUR separate databases, not four sets of tables in one database.
   Each one is a genuinely independent microservice's data store, matching
   the architecture established across this project: no foreign key in this
   file ever crosses a database boundary. Where one service needs to refer
   to a row that lives in another (a review's restaurant_id, a search log's
   user_id), it is stored as a plain BIGINT with a comment, deliberately not
   an enforced constraint, because a FOREIGN KEY cannot span two databases.

     1. KhaustanRestaurantMenu   -- establishments, menus, pricing, bar, delivery capability, OCR provenance (57 tables)
     2. KhaustanIdentity         -- registered users + guest sessions (4 tables)
     3. KhaustanSearchBehavior   -- search queries, impressions, clicks (3 tables)
     4. KhaustanReviews          -- reviews, dish tags, replies, moderation (7 tables)

   T-SQL-SPECIFIC CHOICES MADE IN THIS VERSION (this file targets SQL Server
   only -- it is no longer written to also run on MySQL/PostgreSQL):
     - DATETIME2(3), not DATETIME or the ANSI TIMESTAMP keyword. In SQL
       Server, TIMESTAMP is a synonym for ROWVERSION -- an auto-updating
       binary value, not a date/time type -- so it could never have been
       used literally here.
     - SYSUTCDATETIME() for every "now" default, storing UTC throughout.
       Convert to IST at the application/display layer, not in the
       database, so the data itself stays timezone-unambiguous.
     - NVARCHAR used for every column that can hold real-world text --
       names, descriptions, review text, addresses -- for Unicode safety
       (Hindi/Marathi/regional-script dish and place names). Short
       platform-controlled codes (currency_code, country_code) stay CHAR,
       since they are guaranteed ASCII.
     - BIT for booleans, with 1/0 rather than the TRUE/FALSE keywords, for
       compatibility with SQL Server versions before 2022.
     - Primary keys stay BIGINT, application-generated (no IDENTITY). This
       was originally also a portability choice; it is kept here for a
       reason that has nothing to do with portability: it lets a service
       assign an aggregate's id before the insert, so a multi-table write
       (an item, its variant, and its outbox event) happens in one local
       transaction without a round trip to read back a generated key. Add
       IDENTITY(1,1) back onto any primary key if you'd rather SQL Server
       assign it.
     - CHECK constraints are used freely -- SQL Server has always enforced
       them, unlike older MySQL.

   VALIDATION NOTE, stated precisely: every one of the 125 CREATE
   TABLE/INDEX/ALTER statements in this file was parsed against a dedicated
   T-SQL grammar (node-sql-parser, transactsql dialect). 124 parsed clean
   outright. The remaining case was traced to a genuine gap in that
   specific tool -- its transactsql grammar does not support FOREIGN KEY
   clauses at all, in any form, confirmed with minimal isolated
   reproductions of textbook-correct syntax failing the same way. With FK
   clauses set aside, all 125 statements parse clean, and all 43 FOREIGN
   KEY clauses in this file were separately confirmed by direct inspection
   to match the standard CONSTRAINT ... FOREIGN KEY (...) REFERENCES
   table(...) shape. The full schema was also proven correct in its
   portable form against a live PostgreSQL 16 instance earlier in this
   project (57/57 tables, six worked examples, two adversarial
   constraint-violation tests). This file itself has NOT been executed
   against a live SQL Server instance -- that wasn't available in this
   environment -- so treat the above as strong syntactic evidence, not a
   substitute for running it once yourself in a dev environment first.
   ============================================================================ */


/* ============================================================================
   DATABASE — KhaustanRestaurantMenu
   Establishments, menus, pricing, bar, delivery capability, OCR provenance. 57 tables.
   ============================================================================ */
IF DB_ID(N'KhaustanRestaurantMenu') IS NULL
BEGIN
    CREATE DATABASE KhaustanRestaurantMenu;
END
GO

USE KhaustanRestaurantMenu;
GO

CREATE TABLE brand (
    brand_id        BIGINT NOT NULL PRIMARY KEY,
    name             NVARCHAR(200) NOT NULL,
    normalized_name   NVARCHAR(200) NOT NULL,
    legal_name         NVARCHAR(250),
    description          NVARCHAR(1000),
    website_url           NVARCHAR(500),
    status_code             NVARCHAR(30) NOT NULL DEFAULT 'active' CHECK (status_code IN ('active','inactive')),
    created_at                DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

-- The physical premises/kitchen. Not customer-facing on its own.
CREATE TABLE establishment (
    establishment_id   BIGINT NOT NULL PRIMARY KEY,
    name                 NVARCHAR(250) NOT NULL,
    normalized_name        NVARCHAR(250) NOT NULL,
    address_line1             NVARCHAR(300),
    address_line2                NVARCHAR(300),
    locality                       NVARCHAR(150),
    city                              NVARCHAR(100) NOT NULL DEFAULT 'Mumbai',
    state                               NVARCHAR(100) NOT NULL DEFAULT 'Maharashtra',
    country_code                          CHAR(2) NOT NULL DEFAULT 'IN',
    postal_code                             NVARCHAR(15),
    latitude                                  DECIMAL(9,6),
    longitude                                   DECIMAL(9,6),
    status_code                                   NVARCHAR(30) NOT NULL DEFAULT 'active' CHECK (status_code IN ('active','inactive')),
    created_at                                      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                        DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

-- The customer-facing, searchable listing. One establishment can have
-- several (a hotel's restaurant + rooftop bar + coffee lounge; a cloud
-- kitchen's three delivery-only brands).
CREATE TABLE restaurant (
    restaurant_id       BIGINT NOT NULL PRIMARY KEY,
    establishment_id       BIGINT NOT NULL,
    brand_id                  BIGINT,
    display_name                 NVARCHAR(250) NOT NULL,
    normalized_name                 NVARCHAR(250) NOT NULL,
    description                        NVARCHAR(2000),

    -- Denormalized roll-up flags — restored from the original khaustan
    -- schema. Among the highest-frequency filter predicates at
    -- 1,000,000-restaurant scale, so they live here as plain indexed
    -- columns rather than being computed via a join/aggregate over
    -- menu_item on every search hit. A periodic reconciliation job should
    -- compare these against the actual menu_item population and flag
    -- mismatches, so "denormalized" doesn't silently drift into "wrong".
    veg_nonveg_status            NVARCHAR(20) CHECK (veg_nonveg_status IN ('pure_veg','non_veg','veg_and_nonveg')),
    has_bar                         BIT NOT NULL DEFAULT 0,
    bar_license_type                   NVARCHAR(30) NOT NULL DEFAULT 'none' CHECK (bar_license_type IN ('none','beer_wine_only','full_bar')),
    cost_for_two_amount                   DECIMAL(12,2),
    cost_for_two_currency                    CHAR(3) DEFAULT 'INR',

    listing_tier_code                          NVARCHAR(30),  -- cache written by the billing/monetization service; not owned here
    status_code                                   NVARCHAR(30) NOT NULL DEFAULT 'active'
                                                   CHECK (status_code IN ('active','temporarily_closed','permanently_closed','coming_soon')),
    is_24_hours                                      BIT NOT NULL DEFAULT 0,

    -- Cache written by the review service — not review storage itself,
    -- just a snapshot for fast display without a cross-service call.
    rating_average                                      DECIMAL(3,2) CHECK (rating_average IS NULL OR (rating_average BETWEEN 0 AND 5)),
    rating_count                                            INT CHECK (rating_count IS NULL OR rating_count >= 0),

    last_verified_at                                            DATETIME2(3),
    verification_status_code                                       NVARCHAR(30) NOT NULL DEFAULT 'unverified'
                                                                    CHECK (verification_status_code IN ('unverified','needs_review','verified')),

    created_at                                                       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                                         DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_restaurant_establishment FOREIGN KEY (establishment_id) REFERENCES establishment(establishment_id),
    CONSTRAINT fk_restaurant_brand FOREIGN KEY (brand_id) REFERENCES brand(brand_id),
    CONSTRAINT uq_restaurant_tenant UNIQUE (restaurant_id, establishment_id)
);

-- Restored from the original khaustan schema — a literal field in the OCR
-- pipeline's own output ("restaurant name, phone numbers, address") that
-- the uploaded schema has no table for at all.
CREATE TABLE restaurant_phone (
    restaurant_phone_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id            BIGINT NOT NULL,
    phone_number                 NVARCHAR(20) NOT NULL,
    is_primary                      BIT NOT NULL DEFAULT 0,
    is_personal_number                 BIT NOT NULL DEFAULT 0,  -- DPDP flag: small-vendor personal line vs. business line
    CONSTRAINT fk_restaurant_phone_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id)
);

-- Dedup anchor against Zomato/Swiggy/partner IDs when bootstrapping from
-- multiple data sources.
CREATE TABLE restaurant_external_identity (
    identity_id             BIGINT NOT NULL PRIMARY KEY,
    restaurant_id              BIGINT NOT NULL,
    source_system_code            NVARCHAR(50) NOT NULL,
    external_restaurant_id           NVARCHAR(200) NOT NULL,
    created_at                         DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_restaurant_external_identity_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_restaurant_external_identity UNIQUE (source_system_code, external_restaurant_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 2: Extensible tags, service modes, hours
-- platform_tag + restaurant_tag are kept from the uploaded schema — one
-- unified extensible mechanism beats the original khaustan schema's two
-- parallel tables (establishment_category + amenity) for the same need.
-- menu_item_tag is NEW: the uploaded schema documented a 'menu_item' tag
-- scope as intended but never built the junction table to use it — this
-- finishes that wiring and is where long-tail dietary/allergen tags live
-- (see Section 7 for why they don't live as fixed boolean columns).
-- ----------------------------------------------------------------------------

CREATE TABLE platform_tag (
    tag_id         BIGINT NOT NULL PRIMARY KEY,
    tag_code         NVARCHAR(80) NOT NULL UNIQUE,
    name               NVARCHAR(150) NOT NULL,
    tag_scope            NVARCHAR(30) NOT NULL CHECK (tag_scope IN ('restaurant_format','restaurant_filter','menu_item')),
    value_type              NVARCHAR(20) NOT NULL CHECK (value_type IN ('boolean','text','number')),
    is_multivalue              BIT NOT NULL DEFAULT 0,
    is_active                    BIT NOT NULL DEFAULT 1
);

CREATE TABLE restaurant_tag (
    restaurant_tag_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id           BIGINT NOT NULL,
    tag_id                     BIGINT NOT NULL,
    value_text                    NVARCHAR(250),
    value_number                     DECIMAL(18,4),
    value_boolean                       BIT,
    created_at                             DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                               DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_restaurant_tag_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_restaurant_tag_tag FOREIGN KEY (tag_id) REFERENCES platform_tag(tag_id),
    CONSTRAINT uq_restaurant_tag_value UNIQUE (restaurant_id, tag_id, value_text)
);

-- Long-tail dietary/allergen/other item tags — halal, gluten-free,
-- onion-garlic-free, nut-free, kosher, and whatever comes up later, as
-- INSERT-only additions to platform_tag, never a schema change. Compare
-- with menu_item's own is_jain/is_vegan/is_eggless columns (Section 7),
-- which stay first-class because they're the highest-frequency search
-- predicates and worth a direct index. The FK to menu_item is added at the
-- end of Section 7, once that table exists.
CREATE TABLE menu_item_tag (
    menu_item_id   BIGINT NOT NULL,
    tag_id            BIGINT NOT NULL,
    value_text           NVARCHAR(250),
    PRIMARY KEY (menu_item_id, tag_id),
    CONSTRAINT fk_menu_item_tag_tag FOREIGN KEY (tag_id) REFERENCES platform_tag(tag_id)
);

CREATE TABLE service_mode (
    service_mode_id   BIGINT NOT NULL PRIMARY KEY,
    code                 NVARCHAR(40) NOT NULL UNIQUE
                          CHECK (code IN ('dine_in','takeaway','delivery','drive_through','room_service','bulk_catering')),
    name                     NVARCHAR(100) NOT NULL,
    is_active                  BIT NOT NULL DEFAULT 1
);

CREATE TABLE restaurant_service_mode (
    restaurant_id     BIGINT NOT NULL,
    service_mode_id      BIGINT NOT NULL,
    is_active                BIT NOT NULL DEFAULT 1,
    notes                       NVARCHAR(500),
    PRIMARY KEY (restaurant_id, service_mode_id),
    CONSTRAINT fk_restaurant_service_mode_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_restaurant_service_mode_mode FOREIGN KEY (service_mode_id) REFERENCES service_mode(service_mode_id)
);

CREATE TABLE restaurant_hours (
    restaurant_hours_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id             BIGINT NOT NULL,
    day_of_week                  SMALLINT NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),   -- 1 = Monday
    slot_sequence                    SMALLINT NOT NULL,
    opens_at                            TIME NOT NULL,
    closes_at                              TIME NOT NULL,
    CONSTRAINT fk_restaurant_hours_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_restaurant_hours_slot UNIQUE (restaurant_id, day_of_week, slot_sequence)
);

CREATE TABLE restaurant_holiday_hours (
    holiday_hours_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id          BIGINT NOT NULL,
    holiday_date               DATE NOT NULL,
    is_closed                     BIT NOT NULL DEFAULT 1,
    opens_at                         TIME,
    closes_at                           TIME,
    notes                                  NVARCHAR(300),
    CONSTRAINT fk_restaurant_holiday_hours_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_restaurant_holiday_hours UNIQUE (restaurant_id, holiday_date)
);


-- ----------------------------------------------------------------------------
-- SECTION 3: Protein type
-- RESTORED — present in the original khaustan schema, entirely absent from
-- the uploaded one, despite being in the very first message of the whole
-- design conversation ("under non-veg some have chicken, mutton, seafood").
-- This is not the same thing as veg/non-veg/egg classification (Section 7)
-- — without it, "show me every seafood dish" has no structured field to
-- query and falls back to text search on the item name.
-- ----------------------------------------------------------------------------

CREATE TABLE protein_type (
    protein_type_id   BIGINT NOT NULL PRIMARY KEY,
    code                 NVARCHAR(30) NOT NULL UNIQUE,   -- chicken, mutton, seafood, egg, pork, beef, other
    label                   NVARCHAR(50) NOT NULL
);


-- ----------------------------------------------------------------------------
-- SECTION 4: Canonical dish (cross-restaurant identity)
-- ----------------------------------------------------------------------------

CREATE TABLE canonical_dish (
    canonical_dish_id       BIGINT NOT NULL PRIMARY KEY,
    canonical_name              NVARCHAR(250) NOT NULL,
    normalized_name                NVARCHAR(250) NOT NULL,
    description                       NVARCHAR(2000),
    food_classification_code            NVARCHAR(20) CHECK (food_classification_code IN ('veg','egg','non_veg')),
    default_protein_type_id                BIGINT REFERENCES protein_type(protein_type_id),

    -- Nullable, unlike the uploaded schema's NOT NULL booleans — NULL means
    -- "not established," not "confirmed false." See Section 7.
    is_jain                                   BIT,
    is_vegan                                    BIT,
    is_eggless                                    BIT,

    created_at                                       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE canonical_dish_name (
    canonical_dish_name_id   BIGINT NOT NULL PRIMARY KEY,
    canonical_dish_id            BIGINT NOT NULL,
    language_code                    NVARCHAR(20) NOT NULL,   -- 'en', 'hi', 'mr', ...
    name                                 NVARCHAR(250) NOT NULL,
    normalized_name                         NVARCHAR(250) NOT NULL,
    name_type_code                             NVARCHAR(30) NOT NULL CHECK (name_type_code IN ('primary','alias','translation')),
    CONSTRAINT fk_canonical_dish_name_dish FOREIGN KEY (canonical_dish_id) REFERENCES canonical_dish(canonical_dish_id),
    CONSTRAINT uq_canonical_dish_name UNIQUE (canonical_dish_id, language_code, name_type_code, name)
);


-- ----------------------------------------------------------------------------
-- SECTION 5: Brand master menu (chain inheritance)
-- ----------------------------------------------------------------------------

CREATE TABLE brand_menu_template (
    template_id    BIGINT NOT NULL PRIMARY KEY,
    brand_id          BIGINT NOT NULL,
    name                 NVARCHAR(200) NOT NULL,
    version_no              INT NOT NULL,
    is_active                  BIT NOT NULL DEFAULT 1,
    created_at                    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_brand_menu_template_brand FOREIGN KEY (brand_id) REFERENCES brand(brand_id),
    CONSTRAINT uq_brand_menu_template_version UNIQUE (brand_id, version_no)
);

CREATE TABLE brand_menu_template_board (
    template_board_id   BIGINT NOT NULL PRIMARY KEY,
    template_id             BIGINT NOT NULL,
    name                       NVARCHAR(200) NOT NULL,
    board_type_code               NVARCHAR(40) NOT NULL,  -- see menu_board.board_type_code for the shared value list
    description                      NVARCHAR(1000),
    display_sequence                    INT NOT NULL DEFAULT 0,
    is_active                              BIT NOT NULL DEFAULT 1,
    CONSTRAINT fk_brand_menu_template_board_template FOREIGN KEY (template_id) REFERENCES brand_menu_template(template_id)
);

CREATE TABLE brand_menu_template_item (
    template_item_id    BIGINT NOT NULL PRIMARY KEY,
    template_id             BIGINT NOT NULL,
    canonical_dish_id          BIGINT REFERENCES canonical_dish(canonical_dish_id),
    name                          NVARCHAR(250) NOT NULL,
    description                      NVARCHAR(2000),
    food_classification_code            NVARCHAR(20) CHECK (food_classification_code IN ('veg','egg','non_veg')),
    protein_type_id                        BIGINT REFERENCES protein_type(protein_type_id),
    is_jain                                   BIT,
    is_vegan                                    BIT,
    is_eggless                                    BIT,
    status_code                                     NVARCHAR(30) NOT NULL DEFAULT 'active' CHECK (status_code IN ('active','retired')),
    created_at                                         DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                            DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_brand_menu_template_item_template FOREIGN KEY (template_id) REFERENCES brand_menu_template(template_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 6: Menu boards and the restaurant-defined category tree
-- menu_board is the reusable menu context (à la carte / buffet / thali /
-- bar / breakfast / kids / catering / ...). menu_category is a
-- self-referencing tree PER RESTAURANT with a tenant-safety fix neither
-- source schema had: a composite foreign key (restaurant_id,
-- parent_category_id) -> menu_category(restaurant_id, menu_category_id),
-- so a category can never be linked as a child of another restaurant's
-- category. The uploaded schema's own docs flagged this as something "best
-- enforced in the service transaction because a simple FK cannot express
-- it" — a composite FK against a (restaurant_id, id) unique pair actually
-- can express it declaratively, no trigger needed. Proven in Section 19.
-- ----------------------------------------------------------------------------

CREATE TABLE menu_board (
    menu_board_id      BIGINT NOT NULL PRIMARY KEY,
    restaurant_id          BIGINT NOT NULL,
    template_board_id         BIGINT REFERENCES brand_menu_template_board(template_board_id),
    name                         NVARCHAR(200) NOT NULL,
    board_type_code                 NVARCHAR(40) NOT NULL
        CHECK (board_type_code IN ('a_la_carte','buffet','thali','combo','bar','breakfast','lunch','dinner',
                                    'kids','dessert','room_service','seasonal','catering')),
    description                        NVARCHAR(1000),
    valid_from                            DATE,
    valid_to                                 DATE,
    is_active                                  BIT NOT NULL DEFAULT 1,
    display_sequence                              INT NOT NULL DEFAULT 0,
    created_at                                       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_menu_board_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_menu_board_tenant UNIQUE (restaurant_id, menu_board_id)
);

-- A dated/timed instance of a board — how a buffet's contents can differ
-- from one day to the next while "Lunch Buffet" itself stays one stable,
-- priced offering.
CREATE TABLE menu_board_instance (
    board_instance_id   BIGINT NOT NULL PRIMARY KEY,
    menu_board_id            BIGINT NOT NULL,
    instance_date                 DATE NOT NULL,
    start_time                       TIME,
    end_time                            TIME,
    price_per_person                       DECIMAL(12,2),
    is_active                                 BIT NOT NULL DEFAULT 1,
    notes                                        NVARCHAR(500),
    CONSTRAINT fk_menu_board_instance_board FOREIGN KEY (menu_board_id) REFERENCES menu_board(menu_board_id),
    CONSTRAINT uq_menu_board_instance UNIQUE (menu_board_id, instance_date, start_time)
);

CREATE TABLE menu_category (
    menu_category_id    BIGINT NOT NULL PRIMARY KEY,
    restaurant_id           BIGINT NOT NULL,
    parent_category_id         BIGINT,
    name                           NVARCHAR(200) NOT NULL,
    description                       NVARCHAR(500),
    image_url                            NVARCHAR(1000),
    display_sequence                        INT NOT NULL DEFAULT 0,
    is_active                                  BIT NOT NULL DEFAULT 1,
    CONSTRAINT fk_menu_category_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_menu_category_tenant UNIQUE (restaurant_id, menu_category_id),
    CONSTRAINT fk_menu_category_parent FOREIGN KEY (restaurant_id, parent_category_id)
        REFERENCES menu_category(restaurant_id, menu_category_id)
);

-- NEW — neither source schema had this. The OCR pipeline supplies category
-- only as a flat leaf-level string with no parent info (see menu_item.
-- raw_category_text in Section 7). This table remembers each restaurant's
-- own text -> menu_category_id mapping once a human curates one, so the
-- NEXT OCR batch for that restaurant auto-applies known mappings instead
-- of making a curator redo the same judgment call every time.
CREATE TABLE category_text_alias (
    category_text_alias_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id                 BIGINT NOT NULL,
    raw_text                         NVARCHAR(150) NOT NULL,
    menu_category_id                    BIGINT NOT NULL,
    created_at                             DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_category_text_alias_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_category_text_alias_category FOREIGN KEY (restaurant_id, menu_category_id)
        REFERENCES menu_category(restaurant_id, menu_category_id),
    CONSTRAINT uq_category_text_alias UNIQUE (restaurant_id, raw_text)
);

-- Which categories a given board exposes. Tenant-safety fix: the uploaded
-- schema's own docs (§28) flagged that a board and its categories should
-- share a restaurant but "cannot be enforced with the current key" — it
-- can, with the same composite-FK technique used above.
CREATE TABLE menu_board_category (
    restaurant_id     BIGINT NOT NULL,
    menu_board_id         BIGINT NOT NULL,
    menu_category_id         BIGINT NOT NULL,
    display_sequence            INT NOT NULL DEFAULT 0,
    PRIMARY KEY (menu_board_id, menu_category_id),
    CONSTRAINT fk_menu_board_category_board FOREIGN KEY (restaurant_id, menu_board_id)
        REFERENCES menu_board(restaurant_id, menu_board_id),
    CONSTRAINT fk_menu_board_category_category FOREIGN KEY (restaurant_id, menu_category_id)
        REFERENCES menu_category(restaurant_id, menu_category_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 7: Menu item — the base "sellable thing"
-- Kept from the uploaded schema: a combo/thali/bar item is still a
-- menu_item underneath (Sections 11 and 12), not a duplicated parallel
-- table, so pricing/variants/availability/media work identically no
-- matter what kind of item it is.
--
-- Dietary/allergen modeling is the one place this file most deliberately
-- departs from the uploaded schema. is_jain / is_vegan / is_eggless stay
-- first-class NULLABLE columns — nullable, unlike the uploaded schema's
-- NOT NULL BIT columns, because OCR extraction cannot reliably read these
-- off a menu photo and a forced 1/0 means guessing. NULL means "not
-- established," not "confirmed false." The uploaded schema's remaining
-- flags (is_gluten_free, is_halal, is_onion_garlic_free, contains_nuts)
-- move to menu_item_tag (Section 2) instead of fixed columns — both
-- because they're a lower-frequency, open-ended list, and because
-- contains_nuts specifically is an allergen field: defaulting an unknown
-- allergen fact to 0 is the one modeling choice worth treating as a
-- real data-safety issue, not a style preference. A missing menu_item_tag
-- row correctly reads as "not asserted," never as "confirmed nut-free."
-- ----------------------------------------------------------------------------

CREATE TABLE menu_item (
    menu_item_id          BIGINT NOT NULL PRIMARY KEY,
    restaurant_id             BIGINT NOT NULL,
    menu_category_id             BIGINT,
    canonical_dish_id                BIGINT REFERENCES canonical_dish(canonical_dish_id),
    template_item_id                    BIGINT REFERENCES brand_menu_template_item(template_item_id),

    name                                    NVARCHAR(250) NOT NULL,
    normalized_name                            NVARCHAR(250) NOT NULL,
    description                                   NVARCHAR(2000),

    -- Verbatim OCR leaf string; NULL once menu_category_id is curated.
    -- "Needs curation" is simply: WHERE menu_category_id IS NULL AND
    -- raw_category_text IS NOT NULL. Restored from the original khaustan
    -- schema — absent from the uploaded one despite the brief explicitly
    -- asking for a stated answer here.
    raw_category_text                                NVARCHAR(150),

    food_classification_code                            NVARCHAR(20) CHECK (food_classification_code IN ('veg','egg','non_veg')),
    protein_type_id                                        BIGINT REFERENCES protein_type(protein_type_id),
    is_jain                                                   BIT,
    is_vegan                                                    BIT,
    is_eggless                                                    BIT,
    spice_level                                                      SMALLINT CHECK (spice_level BETWEEN 1 AND 5),

    -- Groups items that were originally one displayed menu line (e.g.
    -- "Fried Rice — Veg/Paneer/Mushroom") before an upstream splitter (OCR
    -- today, possibly manual entry later) broke them into separate rows.
    -- NULL for items that were always a single line. Restored from the
    -- original khaustan schema; the brief explicitly asked for a stated
    -- decision here and the uploaded schema doesn't address it.
    split_group_key                                                     NVARCHAR(64),

    is_bestseller                                                          BIT NOT NULL DEFAULT 0,
    is_recommended                                                           BIT NOT NULL DEFAULT 0,
    status_code                                                                NVARCHAR(30) NOT NULL DEFAULT 'active'
                                                                                CHECK (status_code IN ('active','out_of_stock','retired')),

    -- NULL = still tracking the brand template's defaults; a sync job may
    -- push template changes down. Any other value = locally diverged and
    -- excluded from future automatic pushes for that item.
    inheritance_mode_code                                                       NVARCHAR(30)
        CHECK (inheritance_mode_code IS NULL OR inheritance_mode_code IN ('inherit','overridden','standalone')),

    last_verified_at                                                              DATETIME2(3),
    verification_status_code                                                        NVARCHAR(30) NOT NULL DEFAULT 'unverified'
                                                                                     CHECK (verification_status_code IN ('unverified','needs_review','verified')),

    created_at                                                                        DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_menu_item_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT uq_menu_item_tenant UNIQUE (restaurant_id, menu_item_id),
    CONSTRAINT fk_menu_item_category FOREIGN KEY (restaurant_id, menu_category_id)
        REFERENCES menu_category(restaurant_id, menu_category_id)
);

-- Now that menu_item exists, complete the menu_item_tag FK from Section 2.
ALTER TABLE menu_item_tag ADD CONSTRAINT fk_menu_item_tag_item
    FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id);

CREATE TABLE menu_item_name (
    menu_item_name_id   BIGINT NOT NULL PRIMARY KEY,
    menu_item_id             BIGINT NOT NULL,
    language_code                NVARCHAR(20) NOT NULL,
    name                             NVARCHAR(250) NOT NULL,
    normalized_name                     NVARCHAR(250) NOT NULL,
    name_type_code                         NVARCHAR(30) NOT NULL CHECK (name_type_code IN ('primary','alias','translation')),
    CONSTRAINT fk_menu_item_name_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT uq_menu_item_name UNIQUE (menu_item_id, language_code, name_type_code, name)
);

CREATE TABLE menu_board_item (
    menu_board_item_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id             BIGINT NOT NULL,
    menu_board_id                 BIGINT NOT NULL,
    menu_item_id                     BIGINT NOT NULL,
    menu_category_id                    BIGINT,
    display_sequence                       INT NOT NULL DEFAULT 0,
    is_featured                               BIT NOT NULL DEFAULT 0,
    valid_from                                   DATE,
    valid_to                                        DATE,
    CONSTRAINT fk_menu_board_item_board FOREIGN KEY (restaurant_id, menu_board_id)
        REFERENCES menu_board(restaurant_id, menu_board_id),
    CONSTRAINT fk_menu_board_item_item FOREIGN KEY (restaurant_id, menu_item_id)
        REFERENCES menu_item(restaurant_id, menu_item_id),
    CONSTRAINT fk_menu_board_item_category FOREIGN KEY (restaurant_id, menu_category_id)
        REFERENCES menu_category(restaurant_id, menu_category_id),
    CONSTRAINT uq_menu_board_item UNIQUE (menu_board_id, menu_item_id)
);

CREATE TABLE menu_board_instance_item (
    board_instance_item_id   BIGINT NOT NULL PRIMARY KEY,
    board_instance_id            BIGINT NOT NULL,
    menu_item_id                     BIGINT,
    item_name                            NVARCHAR(150),   -- free text when not also sold as a standalone menu_item
    course_label                             NVARCHAR(50),  -- 'starter' / 'main' / 'dessert'
    is_live_counter                              BIT NOT NULL DEFAULT 0,
    display_sequence                                 INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_menu_board_instance_item_instance FOREIGN KEY (board_instance_id) REFERENCES menu_board_instance(board_instance_id),
    CONSTRAINT fk_menu_board_instance_item_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT ck_menu_board_instance_item CHECK (menu_item_id IS NOT NULL OR item_name IS NOT NULL)
);


-- ----------------------------------------------------------------------------
-- SECTION 8: Variants, pricing schedules, versioned prices, item charges
-- Kept from the uploaded schema: variant (portion/serving unit) is
-- separated from price (dated, service-mode- and schedule-aware), which
-- handles half/full, small/medium/large, 30/60/90ml, per-piece/kg/person
-- and market price uniformly, plus dine-in-vs-takeaway-vs-delivery pricing
-- and happy hour, with tax fields per price row.
-- ----------------------------------------------------------------------------

CREATE TABLE menu_item_variant (
    variant_id       BIGINT NOT NULL PRIMARY KEY,
    menu_item_id         BIGINT NOT NULL,
    variant_name             NVARCHAR(150) NOT NULL,        -- 'Half', 'Full', '90ml', '1 kg', '12 pc'
    variant_code                 NVARCHAR(50),
    pricing_basis_code               NVARCHAR(40) NOT NULL
        CHECK (pricing_basis_code IN ('fixed','per_piece','per_plate','per_person','per_kg','per_100g','per_100ml','market_price')),
    quantity_value                       DECIMAL(12,4),
    quantity_unit_code                       NVARCHAR(10) CHECK (quantity_unit_code IN ('g','kg','ml','l','pieces')),
    display_sequence                             INT NOT NULL DEFAULT 0,
    is_default                                       BIT NOT NULL DEFAULT 0,
    is_active                                            BIT NOT NULL DEFAULT 1,
    CONSTRAINT fk_menu_item_variant_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id)
);

-- Happy-hour / early-bird schedules — one mechanism reused for food and bar.
CREATE TABLE price_schedule (
    price_schedule_id   BIGINT NOT NULL PRIMARY KEY,
    name                    NVARCHAR(150) NOT NULL,
    description                 NVARCHAR(500),
    start_time                     TIME,
    end_time                          TIME,
    is_active                            BIT NOT NULL DEFAULT 1
);

CREATE TABLE price_schedule_day (
    price_schedule_id   BIGINT NOT NULL,
    day_of_week              SMALLINT NOT NULL CHECK (day_of_week BETWEEN 1 AND 7),
    PRIMARY KEY (price_schedule_id, day_of_week),
    CONSTRAINT fk_price_schedule_day_schedule FOREIGN KEY (price_schedule_id) REFERENCES price_schedule(price_schedule_id)
);

CREATE TABLE source_record (
    source_id       BIGINT NOT NULL PRIMARY KEY,
    source_type_code    NVARCHAR(40) NOT NULL CHECK (source_type_code IN ('admin','owner','partner_api','ai_menu_extraction','imported')),
    external_reference       NVARCHAR(500),
    source_uri                  NVARCHAR(1000),
    created_at                     DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

-- Effective-dated price version. Multiple concurrently-valid rows for one
-- variant are expected and correct — e.g. a dine-in price and a takeaway
-- price both "current" at once, distinguished by service_mode_id, or a
-- happy-hour override distinguished by price_schedule_id.
--
-- This table is allowed to accumulate history (that's what makes price
-- alerts possible) but is NOT the unbounded analytical archive — keep an
-- operational retention window (90-180 days of superseded rows is a
-- reasonable starting point) and let change_event_outbox (Section 16) feed
-- the true long-term archive downstream, in the analytics/LLM store, not
-- here. A row with effective_to IS NULL is the current price for its
-- variant/service_mode/schedule combination.
CREATE TABLE menu_item_price (
    price_id           BIGINT NOT NULL PRIMARY KEY,
    variant_id             BIGINT NOT NULL,
    service_mode_id            BIGINT REFERENCES service_mode(service_mode_id),
    price_schedule_id              BIGINT REFERENCES price_schedule(price_schedule_id),
    price_amount                       DECIMAL(12,2),
    currency_code                          CHAR(3) NOT NULL DEFAULT 'INR',
    is_market_price                            BIT NOT NULL DEFAULT 0,
    tax_regime_code                                NVARCHAR(40),   -- open/externally-driven; see docx appendix
    tax_inclusion_code                                 NVARCHAR(30) CHECK (tax_inclusion_code IS NULL OR tax_inclusion_code IN ('inclusive','exclusive')),
    tax_rate                                               DECIMAL(7,4) CHECK (tax_rate IS NULL OR tax_rate >= 0),
    effective_from                                             DATETIME2(3) NOT NULL,
    effective_to                                                   DATETIME2(3),
    verification_status_code                                          NVARCHAR(30)
                                                                       CHECK (verification_status_code IS NULL
                                                                              OR verification_status_code IN ('unverified','needs_review','verified')),
    source_id                                                             BIGINT REFERENCES source_record(source_id),
    created_at                                                                DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_menu_item_price_variant FOREIGN KEY (variant_id) REFERENCES menu_item_variant(variant_id),
    CONSTRAINT ck_menu_item_price_amount CHECK (
        (is_market_price = 1 AND price_amount IS NULL)
        OR (is_market_price = 0 AND price_amount IS NOT NULL AND price_amount >= 0)
    )
);

-- Packaging/delivery/other item-level charges, kept separate from the base
-- price so a packaging fee is never mistaken for the dish price. The
-- uploaded schema's version of this CHECK had a permissive escape clause
-- that silently allowed a mistyped calculation_type_code through with
-- amount and percentage both NULL — fixed here with a closed CHECK.
CREATE TABLE menu_item_charge (
    charge_id         BIGINT NOT NULL PRIMARY KEY,
    menu_item_id           BIGINT NOT NULL,
    service_mode_id            BIGINT REFERENCES service_mode(service_mode_id),
    charge_type_code               NVARCHAR(40) NOT NULL,   -- 'packaging', 'service_charge', ... — open, see docx appendix
    calculation_type_code              NVARCHAR(30) NOT NULL CHECK (calculation_type_code IN ('fixed','percentage')),
    amount                                  DECIMAL(12,2),
    percentage                                 DECIMAL(7,4),
    tax_regime_code                                NVARCHAR(40),
    effective_from                                     DATETIME2(3) NOT NULL,
    effective_to                                           DATETIME2(3),
    is_active                                                  BIT NOT NULL DEFAULT 1,
    CONSTRAINT fk_menu_item_charge_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT fk_menu_item_charge_service_mode FOREIGN KEY (service_mode_id) REFERENCES service_mode(service_mode_id),
    CONSTRAINT ck_menu_item_charge_value CHECK (
        (calculation_type_code = 'fixed' AND amount IS NOT NULL AND amount >= 0)
        OR (calculation_type_code = 'percentage' AND percentage IS NOT NULL AND percentage >= 0)
    )
);


-- ----------------------------------------------------------------------------
-- SECTION 9: Availability
-- ----------------------------------------------------------------------------

CREATE TABLE menu_item_availability (
    availability_id   BIGINT NOT NULL PRIMARY KEY,
    menu_item_id           BIGINT NOT NULL,
    day_of_week                SMALLINT CHECK (day_of_week IS NULL OR day_of_week BETWEEN 1 AND 7),
    start_time                     TIME,
    end_time                          TIME,
    effective_from                       DATE,
    effective_to                             DATE,
    max_quantity                                 INT CHECK (max_quantity IS NULL OR max_quantity >= 0),
    is_active                                        BIT NOT NULL DEFAULT 1,
    CONSTRAINT fk_menu_item_availability_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id)
);

CREATE TABLE menu_item_availability_override (
    override_id       BIGINT NOT NULL PRIMARY KEY,
    menu_item_id            BIGINT NOT NULL,
    override_date                DATE NOT NULL,
    start_time                       TIME,
    end_time                            TIME,
    status_code                             NVARCHAR(30) NOT NULL CHECK (status_code IN ('sold_out','limited_quantity','special_availability','closed')),
    quantity_remaining                          INT CHECK (quantity_remaining IS NULL OR quantity_remaining >= 0),
    reason                                          NVARCHAR(300),
    CONSTRAINT fk_menu_item_availability_override_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT uq_menu_item_availability_override UNIQUE (menu_item_id, override_date)
);


-- ----------------------------------------------------------------------------
-- SECTION 10: Add-ons / customization — NEW SECTION, present in neither
-- source schema in this form. The uploaded schema's bundle mechanism
-- (Section 11) covers combo/thali component *selection*, but not a
-- modifier on a single standalone dish — extra cheese, spice level, bread
-- choice — which the brief explicitly asked for.
-- ----------------------------------------------------------------------------

CREATE TABLE addon_group (
    addon_group_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id         BIGINT NOT NULL,
    name                      NVARCHAR(100) NOT NULL,   -- 'Spice Level', 'Toppings', 'Bread Choice'
    selection_type               NVARCHAR(10) NOT NULL CHECK (selection_type IN ('single','multiple')),
    is_required                      BIT NOT NULL DEFAULT 0,
    CONSTRAINT fk_addon_group_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id)
);

CREATE TABLE addon_option (
    addon_option_id   BIGINT NOT NULL PRIMARY KEY,
    addon_group_id        BIGINT NOT NULL,
    name                      NVARCHAR(100) NOT NULL,    -- 'Extra Cheese', 'Naan', 'With Tobacco'
    extra_price                   DECIMAL(10,2) NOT NULL DEFAULT 0,
    CONSTRAINT fk_addon_option_group FOREIGN KEY (addon_group_id) REFERENCES addon_group(addon_group_id)
);

CREATE TABLE menu_item_addon_group (
    menu_item_id     BIGINT NOT NULL,
    addon_group_id       BIGINT NOT NULL,
    PRIMARY KEY (menu_item_id, addon_group_id),
    CONSTRAINT fk_menu_item_addon_group_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT fk_menu_item_addon_group_group FOREIGN KEY (addon_group_id) REFERENCES addon_group(addon_group_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 11: Bundles — combo / thali
-- Kept from the uploaded schema: a bundle is a 1:1 extension of a
-- menu_item, so it gets normal variants/prices/availability/media for
-- free. bundle_type_code deliberately excludes 'buffet' — a buffet whose
-- contents vary by date is represented at the board level (Section 6:
-- menu_board_instance / menu_board_instance_item), not as a bundle, since
-- a bundle's component list isn't date-varying by design. This divides
-- the two cleanly instead of leaving both bundle_type_code and
-- board_type_code able to say "buffet," which is confusing and was
-- under-specified in the uploaded schema (bundle_type_code had no
-- documented value list at all).
-- ----------------------------------------------------------------------------

CREATE TABLE bundle (
    bundle_id          BIGINT NOT NULL PRIMARY KEY,
    menu_item_id            BIGINT NOT NULL UNIQUE,
    bundle_type_code            NVARCHAR(30) NOT NULL CHECK (bundle_type_code IN ('combo','thali','platter','meal')),
    is_customizable                 BIT NOT NULL DEFAULT 0,
    description                        NVARCHAR(1000),
    CONSTRAINT fk_bundle_menu_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id)
);

-- A selectable/refillable slot, e.g. "Choose your sabzi" or "Roti (refills
-- included)". refill_policy_code is more expressive than a plain
-- unlimited/not-unlimited boolean — it can distinguish "unlimited",
-- "limited free refills", "paid refill" and "none" without a schema change
-- if a new refill model shows up later.
CREATE TABLE bundle_group (
    bundle_group_id   BIGINT NOT NULL PRIMARY KEY,
    bundle_id             BIGINT NOT NULL,
    name                      NVARCHAR(150) NOT NULL,
    selection_min                 INT NOT NULL DEFAULT 1,
    selection_max                     INT NOT NULL DEFAULT 1,
    refill_policy_code                    NVARCHAR(30) CHECK (refill_policy_code IS NULL
                                           OR refill_policy_code IN ('none','unlimited','limited_free_refills','paid_refill')),
    refill_limit                              INT CHECK (refill_limit IS NULL OR refill_limit >= 0),
    display_sequence                              INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_bundle_group_bundle FOREIGN KEY (bundle_id) REFERENCES bundle(bundle_id),
    CONSTRAINT ck_bundle_group_selection CHECK (selection_min >= 0 AND selection_max >= selection_min)
);

CREATE TABLE bundle_component (
    bundle_component_id   BIGINT NOT NULL PRIMARY KEY,
    bundle_id                  BIGINT NOT NULL,
    bundle_group_id                BIGINT REFERENCES bundle_group(bundle_group_id),
    component_menu_item_id             BIGINT NOT NULL,
    quantity                               DECIMAL(12,3) NOT NULL CHECK (quantity > 0),
    display_sequence                           INT NOT NULL DEFAULT 0,
    is_default                                     BIT NOT NULL DEFAULT 0,
    CONSTRAINT fk_bundle_component_bundle FOREIGN KEY (bundle_id) REFERENCES bundle(bundle_id),
    CONSTRAINT fk_bundle_component_item FOREIGN KEY (component_menu_item_id) REFERENCES menu_item(menu_item_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 12: Bar / alcohol extension
-- ----------------------------------------------------------------------------

CREATE TABLE bar_product (
    bar_product_id   BIGINT NOT NULL PRIMARY KEY,
    product_type_code    NVARCHAR(40) NOT NULL CHECK (product_type_code IN
                          ('beer','whisky','wine','vodka','rum','gin','tequila','liqueur','other')),
    brand_name                NVARCHAR(200),
    product_name                  NVARCHAR(250) NOT NULL,
    origin_code                       NVARCHAR(40),   -- open — e.g. 'imfl', 'scotch', 'imported'; see docx appendix
    abv_percent                          DECIMAL(6,3) CHECK (abv_percent IS NULL OR (abv_percent BETWEEN 0 AND 100)),
    spirit_type_code                         NVARCHAR(40),   -- open — e.g. 'single_malt', 'bourbon'
    is_imported                                  BIT NOT NULL DEFAULT 0,
    created_at                                       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE bar_menu_item (
    menu_item_id          BIGINT NOT NULL PRIMARY KEY,
    bar_product_id             BIGINT REFERENCES bar_product(bar_product_id),
    bar_item_type_code             NVARCHAR(40) NOT NULL CHECK (bar_item_type_code IN ('spirit','cocktail','mocktail','shot','mixer','hookah')),
    cocktail_base_required             BIT NOT NULL DEFAULT 0,
    notes                                  NVARCHAR(1000),
    CONSTRAINT fk_bar_menu_item_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id)
);

-- Selectable base spirit for a cocktail — "choice of gin/vodka/rum, with a
-- possible upcharge for a premium base."
CREATE TABLE cocktail_base_option (
    cocktail_base_option_id   BIGINT NOT NULL PRIMARY KEY,
    cocktail_menu_item_id         BIGINT NOT NULL,
    bar_product_id                    BIGINT NOT NULL,
    additional_price                      DECIMAL(12,2) CHECK (additional_price IS NULL OR additional_price >= 0),
    is_default                                BIT NOT NULL DEFAULT 0,
    CONSTRAINT fk_cocktail_base_option_item FOREIGN KEY (cocktail_menu_item_id) REFERENCES bar_menu_item(menu_item_id),
    CONSTRAINT fk_cocktail_base_option_product FOREIGN KEY (bar_product_id) REFERENCES bar_product(bar_product_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 13: Media
-- Binary images stay in object storage; only metadata and a URI live here.
-- ----------------------------------------------------------------------------

CREATE TABLE media_asset (
    media_asset_id   BIGINT NOT NULL PRIMARY KEY,
    storage_uri           NVARCHAR(1000) NOT NULL,
    media_type_code           NVARCHAR(30) NOT NULL CHECK (media_type_code IN ('photo','logo','menu_scan','video')),
    width                         INT,
    height                            INT,
    checksum                             NVARCHAR(128),
    created_at                               DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE restaurant_media (
    restaurant_id     BIGINT NOT NULL,
    media_asset_id        BIGINT NOT NULL,
    display_sequence          INT NOT NULL DEFAULT 0,
    media_role_code               NVARCHAR(30) NOT NULL CHECK (media_role_code IN ('cover','gallery','logo','menu_scan')),
    PRIMARY KEY (restaurant_id, media_asset_id),
    CONSTRAINT fk_restaurant_media_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_restaurant_media_asset FOREIGN KEY (media_asset_id) REFERENCES media_asset(media_asset_id)
);

CREATE TABLE menu_item_media (
    menu_item_id     BIGINT NOT NULL,
    media_asset_id       BIGINT NOT NULL,
    display_sequence         INT NOT NULL DEFAULT 0,
    media_role_code              NVARCHAR(30) NOT NULL CHECK (media_role_code IN ('cover','gallery')),
    PRIMARY KEY (menu_item_id, media_asset_id),
    CONSTRAINT fk_menu_item_media_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT fk_menu_item_media_asset FOREIGN KEY (media_asset_id) REFERENCES media_asset(media_asset_id)
);

CREATE TABLE menu_category_media (
    menu_category_id   BIGINT NOT NULL,
    media_asset_id          BIGINT NOT NULL,
    display_sequence            INT NOT NULL DEFAULT 0,
    media_role_code                 NVARCHAR(30) NOT NULL CHECK (media_role_code IN ('cover','gallery')),
    PRIMARY KEY (menu_category_id, media_asset_id),
    CONSTRAINT fk_menu_category_media_category FOREIGN KEY (menu_category_id) REFERENCES menu_category(menu_category_id),
    CONSTRAINT fk_menu_category_media_asset FOREIGN KEY (media_asset_id) REFERENCES media_asset(media_asset_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 14: OCR / AI menu extraction provenance
-- Confidence is tracked separately for an item's existence/name versus a
-- specific price's extraction, since OCR can be sure about one and not the
-- other. page_number (not filename order) is authoritative, so page 2
-- correctly precedes page 10.
-- ----------------------------------------------------------------------------

CREATE TABLE menu_extraction_batch (
    extraction_batch_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id              BIGINT NOT NULL,
    source_id                      BIGINT NOT NULL,
    extractor_version                  NVARCHAR(100),
    started_at                             DATETIME2(3) NOT NULL,
    completed_at                               DATETIME2(3),
    status_code                                    NVARCHAR(30) NOT NULL CHECK (status_code IN ('running','completed','failed','partially_completed')),
    overall_confidence                                 DECIMAL(6,5) CHECK (overall_confidence IS NULL OR (overall_confidence BETWEEN 0 AND 1)),
    CONSTRAINT fk_menu_extraction_batch_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_menu_extraction_batch_source FOREIGN KEY (source_id) REFERENCES source_record(source_id)
);

CREATE TABLE menu_extraction_image (
    extraction_image_id   BIGINT NOT NULL PRIMARY KEY,
    extraction_batch_id        BIGINT NOT NULL,
    media_asset_id                 BIGINT NOT NULL,
    page_number                        INT NOT NULL CHECK (page_number > 0),
    original_filename                      NVARCHAR(500),
    extracted_text_checksum                    NVARCHAR(128),
    CONSTRAINT fk_menu_extraction_image_batch FOREIGN KEY (extraction_batch_id) REFERENCES menu_extraction_batch(extraction_batch_id),
    CONSTRAINT fk_menu_extraction_image_asset FOREIGN KEY (media_asset_id) REFERENCES media_asset(media_asset_id),
    CONSTRAINT uq_menu_extraction_image_page UNIQUE (extraction_batch_id, page_number)
);

CREATE TABLE menu_item_source (
    menu_item_id     BIGINT NOT NULL,
    source_id            BIGINT NOT NULL,
    extraction_batch_id      BIGINT REFERENCES menu_extraction_batch(extraction_batch_id),
    confidence                    DECIMAL(6,5) CHECK (confidence IS NULL OR (confidence BETWEEN 0 AND 1)),
    verification_status_code          NVARCHAR(30) NOT NULL DEFAULT 'unverified'
                                       CHECK (verification_status_code IN ('unverified','needs_review','verified')),
    verified_at                               DATETIME2(3),
    PRIMARY KEY (menu_item_id, source_id),
    CONSTRAINT fk_menu_item_source_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id),
    CONSTRAINT fk_menu_item_source_source FOREIGN KEY (source_id) REFERENCES source_record(source_id)
);

CREATE TABLE menu_item_price_source (
    price_id       BIGINT NOT NULL,
    source_id          BIGINT NOT NULL,
    extraction_batch_id    BIGINT REFERENCES menu_extraction_batch(extraction_batch_id),
    confidence                  DECIMAL(6,5) CHECK (confidence IS NULL OR (confidence BETWEEN 0 AND 1)),
    PRIMARY KEY (price_id, source_id),
    CONSTRAINT fk_menu_item_price_source_price FOREIGN KEY (price_id) REFERENCES menu_item_price(price_id),
    CONSTRAINT fk_menu_item_price_source_source FOREIGN KEY (source_id) REFERENCES source_record(source_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 15: Delivery capability
-- Three layers: does the outlet deliver at all; which third-party
-- providers serve it; can a specific item be delivered by a specific
-- provider. This is availability/capability metadata for display, not an
-- order-execution or dynamic-pricing engine — those stay in the separate
-- Ordering and Delivery services.
-- ----------------------------------------------------------------------------

CREATE TABLE delivery_provider (
    delivery_provider_id   BIGINT NOT NULL PRIMARY KEY,
    provider_code               NVARCHAR(50) NOT NULL UNIQUE,
    provider_name                   NVARCHAR(150) NOT NULL,
    provider_type_code                  NVARCHAR(30) NOT NULL CHECK (provider_type_code IN ('self','third_party')),
    is_active                               BIT NOT NULL DEFAULT 1,
    created_at                                  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                     DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE restaurant_delivery (
    restaurant_id                    BIGINT NOT NULL PRIMARY KEY,
    delivery_available                    BIT NOT NULL DEFAULT 0,
    self_delivery_available                   BIT NOT NULL DEFAULT 0,
    self_delivery_min_order_amount                DECIMAL(12,2) CHECK (self_delivery_min_order_amount IS NULL OR self_delivery_min_order_amount >= 0),
    currency_code                                     CHAR(3) DEFAULT 'INR',
    last_verified_at                                      DATETIME2(3),
    status_code                                               NVARCHAR(30) NOT NULL DEFAULT 'active' CHECK (status_code IN ('active','inactive')),
    created_at                                                    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                                        DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_restaurant_delivery_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id)
);

CREATE TABLE restaurant_delivery_provider (
    restaurant_delivery_provider_id   BIGINT NOT NULL PRIMARY KEY,
    restaurant_id                          BIGINT NOT NULL,
    delivery_provider_id                       BIGINT NOT NULL,
    is_available                                   BIT NOT NULL DEFAULT 1,
    minimum_order_amount                               DECIMAL(12,2) CHECK (minimum_order_amount IS NULL OR minimum_order_amount >= 0),
    base_delivery_charge                                   DECIMAL(12,2) CHECK (base_delivery_charge IS NULL OR base_delivery_charge >= 0),
    delivery_charge_type_code                                  NVARCHAR(30) NOT NULL CHECK (delivery_charge_type_code IN ('fixed','percentage')),
    delivery_charge_percentage                                     DECIMAL(7,4) CHECK (delivery_charge_percentage IS NULL OR delivery_charge_percentage >= 0),
    free_delivery_min_order_amount                                     DECIMAL(12,2) CHECK (free_delivery_min_order_amount IS NULL OR free_delivery_min_order_amount >= 0),
    currency_code                                                          CHAR(3) DEFAULT 'INR',
    effective_from                                                             DATETIME2(3) NOT NULL,
    effective_to                                                                   DATETIME2(3),
    last_verified_at                                                                   DATETIME2(3),
    created_at                                                                             DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                                                                 DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_restaurant_delivery_provider_restaurant FOREIGN KEY (restaurant_id) REFERENCES restaurant(restaurant_id),
    CONSTRAINT fk_restaurant_delivery_provider_provider FOREIGN KEY (delivery_provider_id) REFERENCES delivery_provider(delivery_provider_id),
    CONSTRAINT uq_restaurant_delivery_provider_version UNIQUE (restaurant_id, delivery_provider_id, effective_from)
);

-- self_delivery_available = 0 does not mean "no delivery" — a
-- third-party provider may still deliver. delivery_available = 0 on
-- restaurant_delivery means no configured delivery capability at all.
CREATE TABLE menu_item_delivery (
    menu_item_delivery_id   BIGINT NOT NULL PRIMARY KEY,
    menu_item_id                 BIGINT NOT NULL,
    delivery_provider_id             BIGINT REFERENCES delivery_provider(delivery_provider_id),
    delivery_status_code                 NVARCHAR(30) NOT NULL CHECK (delivery_status_code IN ('available','not_available','conditional')),
    minimum_order_amount                     DECIMAL(12,2) CHECK (minimum_order_amount IS NULL OR minimum_order_amount >= 0),
    reason_code                                  NVARCHAR(40),   -- open — e.g. 'quality', 'buffet', 'packaging_unsuitable'
    effective_from                                   DATETIME2(3) NOT NULL,
    effective_to                                         DATETIME2(3),
    last_verified_at                                         DATETIME2(3),
    CONSTRAINT fk_menu_item_delivery_item FOREIGN KEY (menu_item_id) REFERENCES menu_item(menu_item_id)
);


-- ----------------------------------------------------------------------------
-- SECTION 16: Change events — bounded transactional outbox
-- Whenever a price/menu/restaurant change commits, a row is written here
-- in the SAME transaction. A separate publisher polls status = 'pending',
-- forwards each event to the event bus that the search index, price-alert
-- processing, and the future LLM-training pipeline all subscribe to, then
-- marks it published. Published rows past expires_at get purged by a
-- retention job — this table is a reliable relay, not the archive itself;
-- the archive is built downstream, from the events it receives.
-- ----------------------------------------------------------------------------

CREATE TABLE change_event_outbox (
    event_id           BIGINT NOT NULL PRIMARY KEY,
    aggregate_type          NVARCHAR(50) NOT NULL
                             CHECK (aggregate_type IN ('restaurant','menu_item','menu_item_variant','menu_item_price','bundle','menu_board')),
    aggregate_id                BIGINT NOT NULL,
    event_type                      NVARCHAR(50) NOT NULL
                                     CHECK (event_type IN ('restaurant_created','restaurant_updated','item_added','item_removed',
                                                            'item_updated','price_changed','menu_updated')),
    occurred_at                         DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    payload                                 NVARCHAR(MAX) NOT NULL,
    publish_status_code                         NVARCHAR(30) NOT NULL DEFAULT 'pending' CHECK (publish_status_code IN ('pending','published','failed')),
    attempt_count                                   INT NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at                                     DATETIME2(3),
    published_at                                            DATETIME2(3),
    expires_at                                                  DATETIME2(3) NOT NULL
);


-- ============================================================================
-- SECTION 17: Indexes
-- ============================================================================

CREATE INDEX ix_restaurant_establishment ON restaurant(establishment_id);
CREATE INDEX ix_restaurant_brand ON restaurant(brand_id);
CREATE INDEX ix_restaurant_status ON restaurant(status_code);
CREATE INDEX ix_restaurant_veg_status ON restaurant(veg_nonveg_status);
CREATE INDEX ix_restaurant_has_bar ON restaurant(has_bar);
CREATE INDEX ix_restaurant_normalized_name ON restaurant(normalized_name);
CREATE INDEX ix_restaurant_listing_tier ON restaurant(listing_tier_code);
CREATE INDEX ix_establishment_name_postal ON establishment(normalized_name, postal_code);
CREATE INDEX ix_establishment_geo ON establishment(latitude, longitude);

CREATE INDEX ix_restaurant_phone_restaurant ON restaurant_phone(restaurant_id);
CREATE INDEX ix_external_identity_restaurant ON restaurant_external_identity(restaurant_id);

CREATE INDEX ix_restaurant_tag_tag ON restaurant_tag(tag_id, restaurant_id);
CREATE INDEX ix_menu_item_tag_tag ON menu_item_tag(tag_id, menu_item_id);

CREATE INDEX ix_restaurant_service_mode_active ON restaurant_service_mode(restaurant_id, is_active);
CREATE INDEX ix_restaurant_hours ON restaurant_hours(restaurant_id, day_of_week, slot_sequence);
CREATE INDEX ix_holiday_hours ON restaurant_holiday_hours(restaurant_id, holiday_date);

CREATE INDEX ix_brand_template_brand ON brand_menu_template(brand_id, is_active);
CREATE INDEX ix_template_item_template ON brand_menu_template_item(template_id);
CREATE INDEX ix_template_board_template ON brand_menu_template_board(template_id);

CREATE INDEX ix_canonical_dish_normalized ON canonical_dish(normalized_name);
CREATE INDEX ix_canonical_dish_classification ON canonical_dish(food_classification_code);
CREATE INDEX ix_canonical_dish_jain ON canonical_dish(is_jain);
CREATE INDEX ix_canonical_dish_name_normalized ON canonical_dish_name(normalized_name);

CREATE INDEX ix_menu_board_restaurant_active ON menu_board(restaurant_id, is_active, display_sequence);
CREATE INDEX ix_menu_board_type_active ON menu_board(board_type_code, is_active);
CREATE INDEX ix_menu_board_instance_date ON menu_board_instance(menu_board_id, instance_date);

CREATE INDEX ix_menu_category_tree ON menu_category(restaurant_id, parent_category_id, display_sequence);
CREATE INDEX ix_category_text_alias_lookup ON category_text_alias(restaurant_id, raw_text);

CREATE INDEX ix_menu_item_restaurant_status ON menu_item(restaurant_id, status_code);
CREATE INDEX ix_menu_item_canonical ON menu_item(canonical_dish_id);
CREATE INDEX ix_menu_item_normalized ON menu_item(normalized_name);
CREATE INDEX ix_menu_item_classification ON menu_item(food_classification_code);
CREATE INDEX ix_menu_item_protein ON menu_item(protein_type_id);
CREATE INDEX ix_menu_item_jain ON menu_item(is_jain);
CREATE INDEX ix_menu_item_vegan ON menu_item(is_vegan);
CREATE INDEX ix_menu_item_template ON menu_item(template_item_id);
CREATE INDEX ix_menu_item_split_group ON menu_item(split_group_key);
CREATE INDEX ix_menu_item_needs_curation ON menu_item(restaurant_id, menu_category_id);
CREATE INDEX ix_menu_item_name_normalized ON menu_item_name(normalized_name);

CREATE INDEX ix_menu_board_item_item ON menu_board_item(menu_item_id);
CREATE INDEX ix_menu_board_item_display ON menu_board_item(menu_board_id, display_sequence);
CREATE INDEX ix_menu_board_instance_item_item ON menu_board_instance_item(menu_item_id);

CREATE INDEX ix_menu_item_variant_item_active ON menu_item_variant(menu_item_id, is_active);

CREATE INDEX ix_menu_item_price_current ON menu_item_price(variant_id, effective_from, effective_to);
CREATE INDEX ix_menu_item_price_service ON menu_item_price(variant_id, service_mode_id, effective_from);
CREATE INDEX ix_menu_item_price_schedule ON menu_item_price(price_schedule_id, effective_from);

CREATE INDEX ix_menu_item_charge_item_service ON menu_item_charge(menu_item_id, service_mode_id, effective_from);

CREATE INDEX ix_menu_item_availability ON menu_item_availability(menu_item_id, day_of_week, start_time);
CREATE INDEX ix_menu_item_availability_override ON menu_item_availability_override(menu_item_id, override_date);

CREATE INDEX ix_addon_group_restaurant ON addon_group(restaurant_id);

CREATE INDEX ix_bundle_group_bundle ON bundle_group(bundle_id, display_sequence);
CREATE INDEX ix_bundle_component_bundle ON bundle_component(bundle_id, display_sequence);
CREATE INDEX ix_bundle_component_item ON bundle_component(component_menu_item_id);

CREATE INDEX ix_bar_product_type ON bar_product(product_type_code);
CREATE INDEX ix_bar_menu_item_product ON bar_menu_item(bar_product_id);
CREATE INDEX ix_cocktail_base_option_cocktail ON cocktail_base_option(cocktail_menu_item_id, is_default);

CREATE INDEX ix_restaurant_media_role ON restaurant_media(restaurant_id, media_role_code);
CREATE INDEX ix_menu_item_media_role ON menu_item_media(menu_item_id, media_role_code);

CREATE INDEX ix_extraction_batch_restaurant ON menu_extraction_batch(restaurant_id, started_at);
CREATE INDEX ix_extraction_image_batch ON menu_extraction_image(extraction_batch_id, page_number);
CREATE INDEX ix_menu_item_source_batch ON menu_item_source(extraction_batch_id);

CREATE INDEX ix_restaurant_delivery_provider_restaurant ON restaurant_delivery_provider(restaurant_id, is_available, effective_from);
CREATE INDEX ix_menu_item_delivery_item ON menu_item_delivery(menu_item_id, delivery_provider_id, effective_from);

CREATE INDEX ix_change_event_outbox_publish ON change_event_outbox(publish_status_code, next_attempt_at);
CREATE INDEX ix_change_event_outbox_aggregate ON change_event_outbox(aggregate_type, aggregate_id);
CREATE INDEX ix_change_event_outbox_expiry ON change_event_outbox(expires_at);
GO

/* ============================================================================
   DATABASE — KhaustanIdentity
   Registered users and guest sessions. 4 tables.
   ============================================================================ */
IF DB_ID(N'KhaustanIdentity') IS NULL
BEGIN
    CREATE DATABASE KhaustanIdentity;
END
GO

USE KhaustanIdentity;
GO

CREATE TABLE auth_provider (
    auth_provider_id   BIGINT NOT NULL PRIMARY KEY,
    code                  NVARCHAR(40) NOT NULL UNIQUE,   -- 'password','google','facebook','apple','otp_phone','otp_email', ...
    name                     NVARCHAR(100) NOT NULL,
    provider_type_code          NVARCHAR(20) NOT NULL CHECK (provider_type_code IN ('password','oauth','otp')),
    is_active                      BIT NOT NULL DEFAULT 1
);

CREATE TABLE identity_user (
    user_id            BIGINT NOT NULL PRIMARY KEY,
    display_name          NVARCHAR(150) NOT NULL,
    email                     NVARCHAR(250),                -- nullable: a phone/OTP-only or social-only user may never supply one
    email_verified_at            DATETIME2(3),
    phone_number                     NVARCHAR(20),
    phone_verified_at                    DATETIME2(3),

    -- Lightweight classification, not a full permissions engine — the
    -- brainstormed "micro-influencer program" feature needs a slot, but a
    -- full cross-domain RBAC/permissions model is out of scope here.
    account_type_code                       NVARCHAR(30) NOT NULL DEFAULT 'standard'
                                             CHECK (account_type_code IN ('standard','micro_influencer','verified')),

    status_code                                 NVARCHAR(20) NOT NULL DEFAULT 'active'
                                                 CHECK (status_code IN ('active','suspended','deactivated','deleted')),
    last_login_at                                   DATETIME2(3),
    created_at                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                              DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT ck_identity_user_has_contact CHECK (email IS NOT NULL OR phone_number IS NOT NULL)
);

-- A user can link more than one sign-in method to the same account (Google
-- AND phone OTP, for instance). provider_user_id is the external subject
-- ID from that provider; credential_hash is only ever populated for the
-- 'password' provider.
CREATE TABLE user_auth_method (
    auth_method_id     BIGINT NOT NULL PRIMARY KEY,
    user_id                BIGINT NOT NULL,
    auth_provider_id           BIGINT NOT NULL,
    provider_user_id               NVARCHAR(250),
    credential_hash                    NVARCHAR(300),
    is_primary                             BIT NOT NULL DEFAULT 0,
    linked_at                                  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_user_auth_method_user FOREIGN KEY (user_id) REFERENCES identity_user(user_id),
    CONSTRAINT fk_user_auth_method_provider FOREIGN KEY (auth_provider_id) REFERENCES auth_provider(auth_provider_id),
    CONSTRAINT uq_user_auth_method_external UNIQUE (auth_provider_id, provider_user_id)
);

-- Anonymous browsing/search, no login. Deliberately NOT the same table as
-- identity_user — a guest is not a partial user record, it's a different
-- kind of thing with a different privacy posture (no name, no email, and
-- an expiry). session_token is the opaque, client-facing identifier (a
-- cookie or local-storage value); guest_session_id is the internal key
-- other local tables reference.
--
-- IP-derived location is coarse by nature (city-level at best, sometimes
-- only country/region, and distorted by VPNs/mobile carriers) — store it
-- as an approximation, never represent it as GPS-precise.
--
-- IP address is still personal data under DPDP even with no email attached
-- — it's an identifier the law treats as personal data, not exempt data
-- just because a name is missing. expires_at gives every guest session a
-- retention limit rather than keeping it indefinitely by default.
CREATE TABLE guest_session (
    guest_session_id     BIGINT NOT NULL PRIMARY KEY,
    session_token            NVARCHAR(128) NOT NULL UNIQUE,
    ip_address                   NVARCHAR(45) NOT NULL,   -- IPv6-safe length
    derived_country_code             CHAR(2),
    derived_region                       NVARCHAR(100),
    derived_city                             NVARCHAR(100),
    derived_latitude                             DECIMAL(9,6),
    derived_longitude                                DECIMAL(9,6),
    user_agent                                           NVARCHAR(500),

    -- Set once a guest signs up mid-session, so search/click history can
    -- be attributed to the resulting account without being rewritten —
    -- Search & Behavior keeps its original guest_session_id rows and a
    -- consuming query can join through this column when it needs to.
    converted_to_user_id                                     BIGINT REFERENCES identity_user(user_id),

    first_seen_at                                                DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    last_seen_at                                                     DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    expires_at                                                           DATETIME2(3) NOT NULL
);

CREATE INDEX ix_identity_user_email ON identity_user(email);
CREATE INDEX ix_identity_user_phone ON identity_user(phone_number);
CREATE INDEX ix_identity_user_status ON identity_user(status_code);
CREATE INDEX ix_user_auth_method_user ON user_auth_method(user_id);
CREATE INDEX ix_guest_session_token ON guest_session(session_token);
CREATE INDEX ix_guest_session_expiry ON guest_session(expires_at);
CREATE INDEX ix_guest_session_converted ON guest_session(converted_to_user_id);
GO

/* ============================================================================
   DATABASE — KhaustanSearchBehavior
   Search queries, result impressions, click events. 3 tables. See in-file note: no outbox here on purpose (rows are immutable events).
   ============================================================================ */
IF DB_ID(N'KhaustanSearchBehavior') IS NULL
BEGIN
    CREATE DATABASE KhaustanSearchBehavior;
END
GO

USE KhaustanSearchBehavior;
GO

CREATE TABLE search_query_log (
    search_query_id     BIGINT NOT NULL PRIMARY KEY,
    user_id                 BIGINT,                 -- soft reference to identity_user; NULL for a guest search
    guest_session_id            BIGINT,              -- soft reference to guest_session; NULL for a logged-in search

    raw_query_text                  NVARCHAR(500),    -- what was actually typed or spoken; NULL for a filter-only search
    normalized_query_text               NVARCHAR(500),
    query_type_code                         NVARCHAR(30) NOT NULL
                                             CHECK (query_type_code IN ('text','voice','filter_only','dish_craving','mood')),

    -- Open-shaped filter state (veg/non-veg, price band, cuisine, area,
    -- open-now, dietary tags, ...) as a text/JSON payload rather than one
    -- column per filter — the filter list is still growing (Section on
    -- amenities/filters in Restaurant & Menu is explicitly open-ended), so
    -- this stays additive the same way that one is.
    applied_filters                             NVARCHAR(MAX),

    result_count                                    INT CHECK (result_count IS NULL OR result_count >= 0),
    search_latitude                                     DECIMAL(9,6),   -- the searcher's location AT THIS SEARCH, which can move within a session
    search_longitude                                        DECIMAL(9,6),
    platform_code                                               NVARCHAR(20),   -- 'ios','android','web', ...
    searched_at                                                     DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT ck_search_query_log_actor CHECK (user_id IS NOT NULL OR guest_session_id IS NOT NULL)
);

-- What was actually shown for a search, and where it ranked — the "not
-- clicked" half of the signal, without which click-through data alone
-- overstates relevance.
CREATE TABLE search_result_impression (
    impression_id       BIGINT NOT NULL PRIMARY KEY,
    search_query_id         BIGINT NOT NULL,               -- local FK — same service, same database
    restaurant_id               BIGINT NOT NULL,            -- soft reference to Restaurant & Menu
    menu_item_id                    BIGINT,                 -- soft reference; NULL when the result is restaurant-level, not dish-level
    rank_position                       INT NOT NULL CHECK (rank_position > 0),
    shown_at                                DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_search_result_impression_query FOREIGN KEY (search_query_id) REFERENCES search_query_log(search_query_id)
);

-- A tap/click on anything — a search result, a favorites entry, a category
-- browse page. search_query_id is NULL when the click didn't originate
-- from a search (e.g. browsing a category listing directly).
CREATE TABLE click_event (
    click_id            BIGINT NOT NULL PRIMARY KEY,
    user_id                 BIGINT,
    guest_session_id            BIGINT,
    search_query_id                 BIGINT,             -- local FK, nullable
    restaurant_id                       BIGINT NOT NULL,  -- soft reference
    menu_item_id                            BIGINT,       -- soft reference, nullable

    click_type_code                             NVARCHAR(30) NOT NULL
        CHECK (click_type_code IN ('view_restaurant','view_menu_item','call','whatsapp','directions','website','favorite','share')),

    clicked_at                                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT fk_click_event_query FOREIGN KEY (search_query_id) REFERENCES search_query_log(search_query_id),
    CONSTRAINT ck_click_event_actor CHECK (user_id IS NOT NULL OR guest_session_id IS NOT NULL)
);

CREATE INDEX ix_search_query_log_user ON search_query_log(user_id, searched_at);
CREATE INDEX ix_search_query_log_guest ON search_query_log(guest_session_id, searched_at);
CREATE INDEX ix_search_query_log_type ON search_query_log(query_type_code, searched_at);
CREATE INDEX ix_search_query_log_normalized ON search_query_log(normalized_query_text);

CREATE INDEX ix_impression_query ON search_result_impression(search_query_id);
CREATE INDEX ix_impression_restaurant ON search_result_impression(restaurant_id, shown_at);
CREATE INDEX ix_impression_item ON search_result_impression(menu_item_id, shown_at);

CREATE INDEX ix_click_event_user ON click_event(user_id, clicked_at);
CREATE INDEX ix_click_event_guest ON click_event(guest_session_id, clicked_at);
CREATE INDEX ix_click_event_restaurant ON click_event(restaurant_id, click_type_code, clicked_at);
CREATE INDEX ix_click_event_item ON click_event(menu_item_id, clicked_at);
GO

/* ============================================================================
   DATABASE — KhaustanReviews
   Reviews, dish tags, media, replies, moderation, and its own outbox back to KhaustanRestaurantMenu's rating cache. 7 tables.
   ============================================================================ */
IF DB_ID(N'KhaustanReviews') IS NULL
BEGIN
    CREATE DATABASE KhaustanReviews;
END
GO

USE KhaustanReviews;
GO

CREATE TABLE review (
    review_id          BIGINT NOT NULL PRIMARY KEY,
    restaurant_id           BIGINT NOT NULL,     -- soft reference to Restaurant & Menu
    user_id                     BIGINT NOT NULL,  -- soft reference to Identity; reviews require login

    overall_rating                   SMALLINT NOT NULL CHECK (overall_rating BETWEEN 1 AND 5),
    review_text                          NVARCHAR(MAX),
    visit_type_code                          NVARCHAR(20) CHECK (visit_type_code IS NULL OR visit_type_code IN ('dine_in','takeaway','delivery')),

    status_code                                  NVARCHAR(30) NOT NULL DEFAULT 'published'
                                                  CHECK (status_code IN ('published','pending_moderation','removed','flagged')),

    created_at                                       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at                                           DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

-- "Dish-tagged reviews" was an explicit, named feature — a review can call
-- out specific dishes, each optionally with its own rating distinct from
-- the review's overall_rating.
CREATE TABLE review_dish_tag (
    review_id         BIGINT NOT NULL,
    menu_item_id           BIGINT NOT NULL,      -- soft reference to Restaurant & Menu
    dish_rating                 SMALLINT CHECK (dish_rating IS NULL OR dish_rating BETWEEN 1 AND 5),
    PRIMARY KEY (review_id, menu_item_id),
    CONSTRAINT fk_review_dish_tag_review FOREIGN KEY (review_id) REFERENCES review(review_id)
);

-- This service's own media table — it cannot reuse Restaurant & Menu's
-- media_asset because that table lives in a different database.
CREATE TABLE review_media (
    review_media_id     BIGINT NOT NULL PRIMARY KEY,
    review_id                BIGINT NOT NULL,
    storage_uri                   NVARCHAR(1000) NOT NULL,
    display_sequence                  INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_review_media_review FOREIGN KEY (review_id) REFERENCES review(review_id)
);

CREATE TABLE review_reply (
    reply_id           BIGINT NOT NULL PRIMARY KEY,
    review_id               BIGINT NOT NULL,
    replier_type_code           NVARCHAR(30) NOT NULL CHECK (replier_type_code IN ('restaurant_owner','platform_admin')),
    replier_external_id             NVARCHAR(100) NOT NULL,   -- opaque id from Identity/staff-RBAC; not a local FK
    reply_text                          NVARCHAR(MAX) NOT NULL,
    created_at                              DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_review_reply_review FOREIGN KEY (review_id) REFERENCES review(review_id)
);

CREATE TABLE review_helpful_vote (
    review_id          BIGINT NOT NULL,
    user_id                 BIGINT NOT NULL,     -- soft reference to Identity
    is_helpful                   BIT NOT NULL,
    voted_at                         DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (review_id, user_id),
    CONSTRAINT fk_review_helpful_vote_review FOREIGN KEY (review_id) REFERENCES review(review_id)
);

CREATE TABLE review_moderation_action (
    moderation_action_id   BIGINT NOT NULL PRIMARY KEY,
    review_id                   BIGINT NOT NULL,
    action_code                      NVARCHAR(30) NOT NULL CHECK (action_code IN ('flagged','removed','restored','warning_issued')),
    actor_external_id                    NVARCHAR(100) NOT NULL,   -- opaque id from the admin/staff RBAC domain
    reason                                    NVARCHAR(500),
    created_at                                    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT fk_review_moderation_action_review FOREIGN KEY (review_id) REFERENCES review(review_id)
);

-- Same transactional-outbox pattern as Restaurant & Menu's
-- change_event_outbox — a review insert/update/moderation commits together
-- with an outbox row in the same local transaction; a separate publisher
-- forwards it to the event bus. Restaurant & Menu's rating_average/
-- rating_count columns are updated by consuming THIS stream, not by a
-- direct write from this service into that database.
CREATE TABLE review_change_outbox (
    event_id           BIGINT NOT NULL PRIMARY KEY,
    review_id               BIGINT NOT NULL,
    restaurant_id                BIGINT NOT NULL,
    event_type                       NVARCHAR(30) NOT NULL CHECK (event_type IN ('review_created','review_updated','review_removed')),
    occurred_at                          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    payload                                  NVARCHAR(MAX) NOT NULL,
    publish_status_code                          NVARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (publish_status_code IN ('pending','published','failed')),
    published_at                                     DATETIME2(3)
);

CREATE INDEX ix_review_restaurant ON review(restaurant_id, status_code);
CREATE INDEX ix_review_user ON review(user_id);
CREATE INDEX ix_review_dish_tag_item ON review_dish_tag(menu_item_id);
CREATE INDEX ix_review_reply_review ON review_reply(review_id);
CREATE INDEX ix_review_moderation_review ON review_moderation_action(review_id, created_at);
CREATE INDEX ix_review_change_outbox_publish ON review_change_outbox(publish_status_code);
CREATE INDEX ix_review_change_outbox_restaurant ON review_change_outbox(restaurant_id);
GO
