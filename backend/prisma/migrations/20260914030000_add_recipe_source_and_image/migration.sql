-- AlterTable
-- Written by hand rather than via `prisma migrate dev` — see
-- `20260913234029_add_user_state_field/migration.sql`'s own comment for why
-- (no interactive TTY in this sandbox). Both columns nullable, added with
-- no `DEFAULT` and no `NOT NULL` — safe against every existing row, same
-- reasoning as that same reference migration.
ALTER TABLE "Recipe" ADD COLUMN     "sourceUrl" TEXT;
ALTER TABLE "Recipe" ADD COLUMN     "imageName" TEXT;
