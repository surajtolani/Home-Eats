-- CreateEnum
CREATE TYPE "RecipeReportReason" AS ENUM ('INAPPROPRIATE', 'SPAM_OR_MISLEADING', 'OTHER');

-- CreateTable
CREATE TABLE "RecipeReport" (
    "id" TEXT NOT NULL,
    "recipeId" TEXT NOT NULL,
    "reporterId" TEXT NOT NULL,
    "reason" "RecipeReportReason" NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RecipeReport_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "RecipeReport_recipeId_idx" ON "RecipeReport"("recipeId");

-- CreateIndex
CREATE UNIQUE INDEX "RecipeReport_recipeId_reporterId_key" ON "RecipeReport"("recipeId", "reporterId");

-- AddForeignKey
ALTER TABLE "RecipeReport" ADD CONSTRAINT "RecipeReport_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeReport" ADD CONSTRAINT "RecipeReport_reporterId_fkey" FOREIGN KEY ("reporterId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
