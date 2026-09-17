-- CreateEnum
CREATE TYPE "MealRating" AS ENUM ('DISLIKED', 'NEUTRAL', 'LIKED');

-- CreateTable
CREATE TABLE "MealHistoryEntry" (
    "id" TEXT NOT NULL,
    "ownerId" TEXT NOT NULL,
    "date" TIMESTAMP(3) NOT NULL,
    "recipeId" TEXT,
    "restaurantId" TEXT,
    "rating" "MealRating",
    "notes" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "MealHistoryEntry_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "MealHistoryEntry_ownerId_idx" ON "MealHistoryEntry"("ownerId");

-- AddForeignKey
ALTER TABLE "MealHistoryEntry" ADD CONSTRAINT "MealHistoryEntry_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealHistoryEntry" ADD CONSTRAINT "MealHistoryEntry_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "MealHistoryEntry" ADD CONSTRAINT "MealHistoryEntry_restaurantId_fkey" FOREIGN KEY ("restaurantId") REFERENCES "Restaurant"("id") ON DELETE SET NULL ON UPDATE CASCADE;
