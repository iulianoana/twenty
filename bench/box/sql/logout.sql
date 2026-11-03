-- rotate-auth-secret: every session and refresh token issued before now is rejected; data is kept.
-- A recorded revokedReason disables the refresh-token reuse grace period.
BEGIN;
UPDATE core."userSession"
  SET "revokedAt" = now(), "revokedReason" = 'USER_REVOKED'
  WHERE "revokedAt" IS NULL;
UPDATE core."appToken"
  SET "revokedAt" = now(),
      context = COALESCE(context, '{}'::jsonb) || '{"revokedReason":"USER_REVOKED"}'::jsonb
  WHERE type = 'REFRESH_TOKEN' AND "revokedAt" IS NULL;
UPDATE core."signingKey"
  SET "isCurrent" = false, "revokedAt" = now(), "privateKey" = NULL
  WHERE "revokedAt" IS NULL;
COMMIT;
