PASS|Restore point saved via VerticaRestorePointsQuery (SaveRestorePoint)
SKIP|Logical backup (EXPORT TO PARQUET) skipped: the ParquetExport package is not part of the '-minimal' Vertica image (use the full image to enable it)
PASS|Object-level restore: dropped table recovered with 100 rows
PASS|Database deployment destroyed: no pods, no local volumes — only communal storage remains
PASS|Database revived from communal storage on brand-new pods/volumes
PASS|Point-in-time restore: bk_orders = 10,000 (the 5,000 post-backup rows are gone)
PASS|Fact table intact after DR: lab.sales = 5000000
