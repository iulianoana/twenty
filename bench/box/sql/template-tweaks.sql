-- Run once on the template DB after workspace:seed:dev.
-- Needs psql variables: admin_email, member_email, admin_hash, member_hash, other_hash.
BEGIN;

UPDATE core.workspace SET "isTwoFactorAuthenticationEnforced" = false;
DELETE FROM core."twoFactorAuthenticationMethod";
UPDATE core."user" SET "isEmailVerified" = true;

-- The dev-seed password is public: lock every seeded user, then set the two bench logins.
UPDATE core."user" SET "passwordHash" = :'other_hash';
UPDATE core."user" SET "passwordHash" = :'admin_hash' WHERE email = :'admin_email';
UPDATE core."user" SET "passwordHash" = :'member_hash' WHERE email = :'member_email';

-- Each environment mints its own signing key on first sign-in.
DELETE FROM core."userSession";
DELETE FROM core."appToken" WHERE type = 'REFRESH_TOKEN';
DELETE FROM core."signingKey";

DO $$
DECLARE
  schema_name text;
BEGIN
  FOR schema_name IN
    SELECT table_schema FROM information_schema.tables
    WHERE table_name = 'workspaceMember' AND table_schema LIKE 'workspace\_%'
  LOOP
    -- CATALOGUE 4.5: Month-first dates for every member.
    EXECUTE format('UPDATE %I."workspaceMember" SET "dateFormat" = %L', schema_name, 'MONTH_FIRST');
    -- CATALOGUE 4.5: one empty Kanban stage (Screening).
    EXECUTE format('UPDATE %I.opportunity SET stage = %L WHERE stage = %L', schema_name, 'NEW', 'SCREENING');
    -- CATALOGUE 4.5: three open tasks on Google (its own seeded task plus Microsoft's and the third company's).
    EXECUTE format(
      'UPDATE %I."taskTarget" SET "targetCompanyId" = %L WHERE "taskId" IN (%L, %L)',
      schema_name, '20202020-a305-41e7-8c72-ba44072a4c58',
      '20202020-04b2-4e7c-9001-123456789def', '20202020-04b3-4e7c-9001-123456789def');
    EXECUTE format(
      'UPDATE %I.task SET status = %L, "deletedAt" = NULL WHERE id IN (%L, %L, %L)',
      schema_name, 'TODO',
      '20202020-04b1-4e7c-9001-123456789def', '20202020-04b2-4e7c-9001-123456789def',
      '20202020-04b3-4e7c-9001-123456789def');
  END LOOP;
END $$;

COMMIT;
