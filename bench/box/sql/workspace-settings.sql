-- Workspace settings every environment needs; applied to the template and to every existing database.
-- The public invite link must stay on: the sign-up shim (box/signup-shim.mjs) joins new users through it.
UPDATE core.workspace SET "isPublicInviteLinkEnabled" = true;
