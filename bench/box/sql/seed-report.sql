-- Non-secret summary of the seeded template, printed by provision.
SELECT 'users ' || string_agg(email, ',' ORDER BY email) FROM core."user"
  WHERE email IN ('jane.austen@apple.dev', 'jony.ive@apple.dev');
SELECT 'workspaces ' || count(*) FROM core.workspace;
DO $$
DECLARE
  schema_name text;
  line text;
BEGIN
  FOR schema_name IN
    SELECT w_schema FROM (
      SELECT table_schema AS w_schema FROM information_schema.tables
      WHERE table_name = 'opportunity' AND table_schema LIKE 'workspace\_%') s
  LOOP
    EXECUTE format('SELECT string_agg(stage || ''='' || n, '' '') FROM (SELECT stage, count(*) n FROM %I.opportunity WHERE "deletedAt" IS NULL GROUP BY stage ORDER BY stage) x', schema_name) INTO line;
    RAISE NOTICE '% opportunities by stage: %', schema_name, line;
    EXECUTE format('SELECT count(*)::text FROM %I.task t JOIN %I."taskTarget" tt ON tt."taskId" = t.id WHERE tt."targetCompanyId" = %L AND t.status <> %L AND t."deletedAt" IS NULL', schema_name, schema_name, '20202020-a305-41e7-8c72-ba44072a4c58', 'DONE') INTO line;
    RAISE NOTICE '% open tasks on Google: %', schema_name, line;
    EXECUTE format('SELECT string_agg(DISTINCT "dateFormat"::text, '','') FROM %I."workspaceMember"', schema_name) INTO line;
    RAISE NOTICE '% member date formats: %', schema_name, line;
  END LOOP;
END $$;
