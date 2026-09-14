-- AlterTable
-- Written by hand rather than via `prisma migrate dev` — see
-- `20260913234029_add_user_state_field/migration.sql`'s own comment for why
-- (no interactive TTY in this sandbox). A `NOT NULL DEFAULT 1` is safe here,
-- unlike the nullable profile fields that migration added: every existing
-- `GroupGroceryItem` row genuinely means "one of these" today (there was no
-- way to express any other count before this column existed), so backfilling
-- every pre-existing row to 1 is the correct value, not just a placeholder.
ALTER TABLE "GroupGroceryItem" ADD COLUMN     "quantityCount" INTEGER NOT NULL DEFAULT 1;
