-- CreateEnum
CREATE TYPE "VoteDirection" AS ENUM ('UP', 'DOWN');

-- AlterTable
-- Every `MealSuggestionVote` row created before this migration was, by
-- construction, an upvote — the API had no other kind of vote to offer at
-- the time (see that model's doc comment in schema.prisma). Adding this
-- column WITH a DEFAULT, rather than adding it nullable and backfilling in a
-- separate UPDATE, is what actually backfills every pre-existing row here:
-- Postgres applies a column's DEFAULT to existing rows as part of the same
-- ALTER TABLE that adds it, so this single statement both adds the column
-- and leaves no pre-existing row with a null direction — matching the
-- "backfill existing rows to UP" requirement in one step, same end result as
-- the `role`-backfill migration (20260913020000) took a separate UPDATE to
-- achieve for a case where the correct backfill value differed per row; here
-- every row backfills to the exact same value, so the column default alone
-- is sufficient and no follow-up UPDATE is needed.
ALTER TABLE "MealSuggestionVote" ADD COLUMN     "direction" "VoteDirection" NOT NULL DEFAULT 'UP';
