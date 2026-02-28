#!/bin/bash
PASSWORD="thepasswordhere"

echo "Fetching broken tables from ch02..."

# Get the list of broken tables (is_readonly = 1), ignore backups and system tables
QUERY="SELECT database, table FROM system.replicas WHERE database LIKE 'reporting_shop%' AND is_readonly = 1 AND table NOT LIKE '%_backup' FORMAT CSV"

# tr -d '"' removes the quotes from CSV, tr -d '\r' prevents Windows line ending issues
TABLES=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "$QUERY" | tr -d '"' | tr -d '\r')

for row in $TABLES; do
    DB=$(echo $row | cut -d',' -f1)
    TBL=$(echo $row | cut -d',' -f2)

    echo "------------------------------------------------"
    echo "Fixing table: $DB.$TBL"

    # 1. Rename the data-holding table on ch02 to safety
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "RENAME TABLE $DB.$TBL TO $DB.${TBL}_backup;"

    # 2. Drop the empty, broken ghost table on ch01
    docker exec ch01 clickhouse-client --password "$PASSWORD" -q "DROP TABLE IF EXISTS $DB.$TBL;"

    # 3. Recreate the table perfectly across the cluster using the exact schema from the backup
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "CREATE TABLE $DB.$TBL ON CLUSTER staging_cluster AS $DB.${TBL}_backup;"

    # 4. Insert the data back into the healthy cluster table
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "INSERT INTO $DB.$TBL SELECT * FROM $DB.${TBL}_backup;"

    # 5. Clean up the backup to save disk space
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "DROP TABLE $DB.${TBL}_backup;"

    echo "Successfully synced $DB.$TBL!"
done

echo "------------------------------------------------"
echo "All broken tables have been fixed and replicated!"
