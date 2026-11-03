-- Run on every fresh clone (preview creation and reset-db): the Google tasks are due
-- yesterday, today and tomorrow relative to the clone date.
DO $$
DECLARE
  schema_name text;
BEGIN
  FOR schema_name IN
    SELECT table_schema FROM information_schema.tables
    WHERE table_name = 'task' AND table_schema LIKE 'workspace\_%'
  LOOP
    EXECUTE format(
      'UPDATE %I.task SET "dueAt" = date_trunc(''day'', now()) + interval ''12 hours'' + CASE id '
      || 'WHEN %L THEN interval ''-1 day'' WHEN %L THEN interval ''0 day'' ELSE interval ''1 day'' END '
      || 'WHERE id IN (%L, %L, %L)',
      schema_name,
      '20202020-04b1-4e7c-9001-123456789def', '20202020-04b2-4e7c-9001-123456789def',
      '20202020-04b1-4e7c-9001-123456789def', '20202020-04b2-4e7c-9001-123456789def',
      '20202020-04b3-4e7c-9001-123456789def');
  END LOOP;
END $$;
