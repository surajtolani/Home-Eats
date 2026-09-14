-- CreateTable
-- Written by hand rather than via `prisma migrate dev` — see
-- `20260913234029_add_user_state_field/migration.sql`'s own comment for why
-- (no interactive TTY in this sandbox). A pure `CREATE TABLE` for a
-- brand-new model has no pre-existing rows to worry about, unlike the
-- ALTER TABLE migrations elsewhere in this directory.
CREATE TABLE "Restaurant" (
    "id" TEXT NOT NULL,
    "ownerId" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "cuisine" TEXT,
    "priceRange" TEXT,
    "rating" INTEGER,
    "notes" TEXT,
    "websiteUrl" TEXT,
    "address" TEXT,
    "isFavorite" BOOLEAN NOT NULL DEFAULT false,
    "googlePhotoNames" TEXT[] DEFAULT ARRAY[]::TEXT[],
    "googlePlaceId" TEXT,
    "latitude" DOUBLE PRECISION,
    "longitude" DOUBLE PRECISION,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Restaurant_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "Restaurant_ownerId_idx" ON "Restaurant"("ownerId");

-- AddForeignKey
ALTER TABLE "Restaurant" ADD CONSTRAINT "Restaurant_ownerId_fkey" FOREIGN KEY ("ownerId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
