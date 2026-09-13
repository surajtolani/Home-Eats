-- DropForeignKey
ALTER TABLE "Group" DROP CONSTRAINT "Group_createdByUserId_fkey";

-- AlterTable
ALTER TABLE "Group" ALTER COLUMN "createdByUserId" DROP NOT NULL;

-- AddForeignKey
ALTER TABLE "Group" ADD CONSTRAINT "Group_createdByUserId_fkey" FOREIGN KEY ("createdByUserId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;
