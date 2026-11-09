-- =====================================================================
-- TagTrail — the console's store
--
-- The console keeps each record as a JSON document and reads them back
-- synchronously from memory. The relational schema in 001 keeps the same
-- facts as rows, which is what makes the constraints, the append-only log
-- and the stale-write check possible.
--
-- Both are needed, and they are not in conflict:
--
--   * The collections that carry the statutory weight — assets, areas,
--     departments, classes, people — are translated by the API into the
--     real tables. They get every guarantee.
--
--   * The rest (sweeps in progress, tasks, photos, tag batches) land here
--     as documents for now, so the console works against one shared
--     database today rather than in three weeks. Each one moves out of
--     here into its own table as the translation is written.
--
-- This table is a staging post, not a destination. Anything still in it
-- when the migration is finished is something that was forgotten.
-- =====================================================================

BEGIN;
SET search_path TO tagtrail, public;

CREATE TABLE IF NOT EXISTS doc_store (
  site_id    uuid NOT NULL REFERENCES site(id) ON DELETE CASCADE,
  collection text NOT NULL,
  id         text NOT NULL,
  body       jsonb NOT NULL,
  -- Same optimistic concurrency as everywhere else: a device that writes
  -- from a stale read is refused rather than silently overwriting whoever
  -- got there first. That is the whole reason for moving off browser
  -- storage, so the staging table does not get to opt out of it.
  rev        integer NOT NULL DEFAULT 1,
  updated_by uuid REFERENCES person(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (site_id, collection, id)
);

CREATE INDEX IF NOT EXISTS doc_store_col_idx ON doc_store (site_id, collection);
-- The console filters documents by fields inside them constantly (an area's
-- assets, a round's sweeps). Without this every such read is a sequential
-- scan of the whole collection.
CREATE INDEX IF NOT EXISTS doc_store_body_idx ON doc_store USING gin (body jsonb_path_ops);

CREATE OR REPLACE FUNCTION doc_bump_rev() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.rev IS DISTINCT FROM OLD.rev AND NEW.rev <> 0 THEN
    RAISE EXCEPTION
      'stale write to %/% : you read rev %, the row is now rev %',
      OLD.collection, OLD.id, NEW.rev, OLD.rev
      USING ERRCODE = '40001';
  END IF;
  NEW.rev := OLD.rev + 1;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS doc_store_rev ON doc_store;
CREATE TRIGGER doc_store_rev BEFORE UPDATE ON doc_store
  FOR EACH ROW EXECUTE FUNCTION doc_bump_rev();

COMMIT;
