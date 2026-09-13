-- Removes the group-scoped standing "staples" template list (`GroupStapleItem`,
-- introduced in 20260913203324_group_layout_staples_history alongside
-- "My Layout" aisles and grocery history) — deleted outright per direct user
-- feedback that the concept added nothing useful ("delete the concept of
-- staples"), not just hidden behind a flag. This has never been used by any
-- real account (it shipped and was reviewed in the same work session as this
-- removal), so there is no data-preservation concern here — this migration
-- simply drops the table, its indexes, and its foreign keys.
--
-- The pre-existing `GroupGrocerySection.STAPLES` enum value on
-- `GroupGroceryItem` (Phase 3, unrelated to this feature — a tag on one
-- specific line already on the live list, not a standing template) is
-- untouched: nothing here alters `GroupGroceryItem` or the
-- `GroupGrocerySection` enum at all.

-- DropForeignKey
ALTER TABLE "GroupStapleItem" DROP CONSTRAINT "GroupStapleItem_groupId_fkey";

-- DropForeignKey
ALTER TABLE "GroupStapleItem" DROP CONSTRAINT "GroupStapleItem_addedByUserId_fkey";

-- DropTable
DROP TABLE "GroupStapleItem";
