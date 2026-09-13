-- CreateEnum
CREATE TYPE "GroupRole" AS ENUM ('MANAGER', 'PARTICIPANT');

-- CreateEnum
CREATE TYPE "MealSlot" AS ENUM ('BREAKFAST', 'LUNCH', 'DINNER', 'OTHER');

-- CreateEnum
CREATE TYPE "GroceryCategory" AS ENUM ('PRODUCE', 'DAIRY_AND_EGGS', 'MEAT_AND_SEAFOOD', 'BAKERY', 'PANTRY', 'FROZEN', 'BEVERAGES', 'SNACKS', 'HOUSEHOLD', 'OTHER');

-- CreateEnum
CREATE TYPE "GroupGrocerySection" AS ENUM ('SUGGESTED', 'THIS_WEEK', 'STAPLES');

-- AlterTable
ALTER TABLE "GroupMembership" ADD COLUMN     "role" "GroupRole" NOT NULL DEFAULT 'PARTICIPANT';

-- DataMigration: promote each group's creator to MANAGER on their own
-- existing membership row. Every other pre-existing membership is left at
-- the column default applied above (PARTICIPANT) — see the GroupMembership
-- doc comment in schema.prisma. A group whose `createdByUserId` is NULL
-- (its creator's User row was already deleted — see the nullable/SetNull
-- migration this one follows) is deliberately skipped here: there's no
-- longer any way to know who should be promoted, so every membership on
-- that group just stays PARTICIPANT rather than guessing.
UPDATE "GroupMembership" gm
SET "role" = 'MANAGER'
FROM "Group" g
WHERE gm."groupId" = g."id"
  AND g."createdByUserId" IS NOT NULL
  AND gm."userId" = g."createdByUserId";

-- CreateTable
CREATE TABLE "PlannedMeal" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "date" TIMESTAMP(3) NOT NULL,
    "slot" "MealSlot" NOT NULL,
    "recipeId" TEXT,
    "restaurantName" TEXT,
    "isOrderIn" BOOLEAN NOT NULL DEFAULT false,
    "decidedByUserId" TEXT NOT NULL,
    "decidedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "PlannedMeal_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MealSuggestion" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "date" TIMESTAMP(3) NOT NULL,
    "slot" "MealSlot" NOT NULL,
    "recipeId" TEXT,
    "restaurantName" TEXT,
    "isOrderIn" BOOLEAN NOT NULL DEFAULT false,
    "proposedByUserId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MealSuggestion_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "MealSuggestionVote" (
    "id" TEXT NOT NULL,
    "suggestionId" TEXT NOT NULL,
    "userId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "MealSuggestionVote_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "GroupGroceryItem" (
    "id" TEXT NOT NULL,
    "groupId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "category" "GroceryCategory" NOT NULL,
    "section" "GroupGrocerySection" NOT NULL,
    "quantityText" TEXT NOT NULL DEFAULT '',
    "isChecked" BOOLEAN NOT NULL DEFAULT false,
    "orderIndex" DOUBLE PRECISION NOT NULL DEFAULT 0,
    "addedByUserId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "GroupGroceryItem_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "PlannedMeal_groupId_idx" ON "PlannedMeal"("groupId");

-- CreateIndex
CREATE INDEX "PlannedMeal_groupId_date_idx" ON "PlannedMeal"("groupId", "date");

-- CreateIndex
CREATE INDEX "PlannedMeal_recipeId_idx" ON "PlannedMeal"("recipeId");

-- CreateIndex
CREATE INDEX "MealSuggestion_groupId_idx" ON "MealSuggestion"("groupId");

-- CreateIndex
CREATE INDEX "MealSuggestion_groupId_date_idx" ON "MealSuggestion"("groupId", "date");

-- CreateIndex
CREATE INDEX "MealSuggestion_recipeId_idx" ON "MealSuggestion"("recipeId");

-- CreateIndex
CREATE INDEX "MealSuggestionVote_suggestionId_idx" ON "MealSuggestionVote"("suggestionId");

-- CreateIndex
CREATE INDEX "MealSuggestionVote_userId_idx" ON "MealSuggestionVote"("userId");

-- CreateIndex
CREATE UNIQUE INDEX "MealSuggestionVote_suggestionId_userId_key" ON "MealSuggestionVote"("suggestionId", "userId");

-- CreateIndex
CREATE INDEX "GroupGroceryItem_groupId_idx" ON "GroupGroceryItem"("groupId");

-- CreateIndex
CREATE INDEX "GroupGroceryItem_groupId_section_idx" ON "GroupGroceryItem"("groupId", "section");

-- AddForeignKey
ALTER TABLE "PlannedMeal" ADD CONSTRAINT "PlannedMeal_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "PlannedMeal" ADD CONSTRAINT "PlannedMeal_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "PlannedMeal" ADD CONSTRAINT "PlannedMeal_decidedByUserId_fkey" FOREIGN KEY ("decidedByUserId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealSuggestion" ADD CONSTRAINT "MealSuggestion_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealSuggestion" ADD CONSTRAINT "MealSuggestion_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealSuggestion" ADD CONSTRAINT "MealSuggestion_proposedByUserId_fkey" FOREIGN KEY ("proposedByUserId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealSuggestionVote" ADD CONSTRAINT "MealSuggestionVote_suggestionId_fkey" FOREIGN KEY ("suggestionId") REFERENCES "MealSuggestion"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealSuggestionVote" ADD CONSTRAINT "MealSuggestionVote_userId_fkey" FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "GroupGroceryItem" ADD CONSTRAINT "GroupGroceryItem_groupId_fkey" FOREIGN KEY ("groupId") REFERENCES "Group"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "GroupGroceryItem" ADD CONSTRAINT "GroupGroceryItem_addedByUserId_fkey" FOREIGN KEY ("addedByUserId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
