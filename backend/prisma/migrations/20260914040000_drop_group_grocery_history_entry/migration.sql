-- Removes the group-shared "past groceries" catalog (`GroupGroceryHistoryEntry`,
-- introduced in 20260913203324_group_layout_staples_history alongside "My
-- Layout" aisles and the group-scoped "staples" template list) — deleted
-- outright per direct user feedback that a group-shared history was
-- redundant with each member's own personal `HistoricalGroceryItem`
-- "Household Groceries" catalog, which now does this job alone. Same
-- reasoning and same "just drop the table" shape as
-- 20260913210000_drop_group_staple_item, which removed this table's sibling
-- feature the same way.
--
-- This drops the `GroupGroceryHistoryEntry` table, its indexes, and its
-- foreign key to `Group`. Nothing here touches `GroupGroceryItem` or any
-- other table — the PATCH .../grocery/:id side effect that used to write
-- into this table (on isChecked false -> true) was removed in the same
-- application change as this migration, not here.

-- DropForeignKey
ALTER TABLE "GroupGroceryHistoryEntry" DROP CONSTRAINT "GroupGroceryHistoryEntry_groupId_fkey";

-- DropTable
DROP TABLE "GroupGroceryHistoryEntry";
