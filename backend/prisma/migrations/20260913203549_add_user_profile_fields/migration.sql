-- AlterTable
-- Note: Prisma's auto-generated diff for this migration also wanted to
-- DROP COLUMN "passwordHash" (schema.prisma no longer declares it, after
-- the password-auth feature was built and then reverted — see commit
-- 609b8bb's message for why the column was deliberately left in the
-- database as a harmless, permanently-unused orphan rather than risking a
-- migration-history mismatch by deleting its ADD COLUMN migration). That
-- DROP was removed by hand from this file: whether that column actually
-- exists on any given deployment's live database is genuinely unknown from
-- here (it depends on exact Render auto-deploy timing during the
-- revert), and a DROP COLUMN for a column that turns out not to exist
-- would fail this migration outright. This migration is intentionally
-- additive-only — dropping that orphaned column, if it's ever worth doing,
-- should be its own separate, deliberate migration once someone can
-- actually confirm the live column's real state first.
ALTER TABLE "User" ADD COLUMN     "city" TEXT,
ADD COLUMN     "country" TEXT,
ADD COLUMN     "firstName" TEXT,
ADD COLUMN     "lastName" TEXT;
