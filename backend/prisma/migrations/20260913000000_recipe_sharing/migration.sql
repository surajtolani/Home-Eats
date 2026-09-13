-- CreateEnum
CREATE TYPE "RecipeVisibility" AS ENUM ('PRIVATE', 'SHARED');

-- CreateTable
CREATE TABLE "Recipe" (
    "id" TEXT NOT NULL,
    "ownerId" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "summary" TEXT,
    "instructions" TEXT[],
    "servings" INTEGER,
    "prepMinutes" INTEGER,
    "cookMinutes" INTEGER,
    "visibility" "RecipeVisibility" NOT NULL DEFAULT 'PRIVATE',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Recipe_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RecipeIngredient" (
    "id" TEXT NOT NULL,
    "recipeId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "quantity" DOUBLE PRECISION,
    "unit" TEXT,
    "sortIndex" INTEGER NOT NULL,

    CONSTRAINT "RecipeIngredient_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RecipeShare" (
    "id" TEXT NOT NULL,
    "recipeId" TEXT NOT NULL,
    "sharedWithUserId" TEXT,
    "sharedWithGroupId" TEXT,
    "sharedByUserId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RecipeShare_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Recipe_ownerId_idx" ON "Recipe"("ownerId");

-- CreateIndex
CREATE INDEX "RecipeIngredient_recipeId_idx" ON "RecipeIngredient"("recipeId");

-- CreateIndex
CREATE INDEX "RecipeShare_sharedWithUserId_idx" ON "RecipeShare"("sharedWithUserId");

-- CreateIndex
CREATE INDEX "RecipeShare_sharedWithGroupId_idx" ON "RecipeShare"("sharedWithGroupId");

-- CreateIndex
CREATE UNIQUE INDEX "RecipeShare_recipeId_sharedWithUserId_key" ON "RecipeShare"("recipeId", "sharedWithUserId");

-- CreateIndex
CREATE UNIQUE INDEX "RecipeShare_recipeId_sharedWithGroupId_key" ON "RecipeShare"("recipeId", "sharedWithGroupId");

-- AddForeignKey
ALTER TABLE "Recipe" ADD CONSTRAINT "Recipe_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeIngredient" ADD CONSTRAINT "RecipeIngredient_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeShare" ADD CONSTRAINT "RecipeShare_recipeId_fkey" FOREIGN KEY ("recipeId") REFERENCES "Recipe"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeShare" ADD CONSTRAINT "RecipeShare_sharedWithUserId_fkey" FOREIGN KEY ("sharedWithUserId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeShare" ADD CONSTRAINT "RecipeShare_sharedWithGroupId_fkey" FOREIGN KEY ("sharedWithGroupId") REFERENCES "Group"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RecipeShare" ADD CONSTRAINT "RecipeShare_sharedByUserId_fkey" FOREIGN KEY ("sharedByUserId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

