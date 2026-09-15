-- AlterEnum
-- Postgres requires ALTER TYPE ... ADD VALUE to run outside a transaction
-- block; Prisma's migration runner executes each migration.sql file
-- statement-by-statement (not wrapped in one big transaction), so this is
-- safe as a standalone statement here.
ALTER TYPE "RecipeVisibility" ADD VALUE 'PUBLIC';

-- AlterTable
ALTER TABLE "Recipe" ADD COLUMN "publishedAnonymously" BOOLEAN NOT NULL DEFAULT false;
