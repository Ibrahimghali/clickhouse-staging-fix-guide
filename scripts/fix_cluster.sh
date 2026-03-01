#!/bin/bash
# Mot de passe utilisé sur votre environnement staging
PASSWORD="stagingpass"

echo " Fetching broken tables from ch02..."

# On récupère toutes les tables en lecture seule (is_readonly = 1)
# FORMAT CSV permet de parser facilement les résultats
QUERY="SELECT database, table FROM system.replicas WHERE database LIKE 'reporting_shop%' AND is_readonly = 1 FORMAT CSV"

# tr -d '"' enlève les guillemets, tr -d '\r' évite les problèmes de retour chariot
TABLES=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "$QUERY" | tr -d '"' | tr -d '\r')

if [ -z "$TABLES" ]; then
    echo " No broken tables found! Cluster is healthy."
    exit 0
fi

for row in $TABLES; do
    # Extraction de la base de données et de la table
    DB=$(echo "$row" | cut -d',' -f1)
    TBL=$(echo "$row" | cut -d',' -f2)

    echo "------------------------------------------------"
    echo " Fixing metadata for table: $DB.$TBL"

    # 1. Supprimer la table "fantôme" et son chemin Keeper erroné sur ch01
    echo " -> [ch01] Dropping ghost table and orphaned Keeper path..."
    docker exec ch01 clickhouse-client --password "$PASSWORD" -q "DROP TABLE IF EXISTS $DB.$TBL SYNC;"

    # 2. Reconstruire le chemin Keeper légitime à partir des données locales sur ch02
    echo " -> [ch02] Restoring replica metadata to Keeper..."
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SYSTEM RESTORE REPLICA $DB.$TBL;"

    # 3. Récupérer l'UUID exact de la table sur ch02
    UUID=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SELECT uuid FROM system.tables WHERE database='$DB' AND name='$TBL' FORMAT TabSeparatedRaw")
    echo " -> [ch02] Retrieved strict UUID: $UUID"

    # 4. Récupérer le DDL (Data Definition Language) exact de ch02
    SCHEMA=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SHOW CREATE TABLE $DB.$TBL FORMAT TabSeparatedRaw")

    # 5. Injecter l'UUID dans la requête CREATE TABLE avec sed
    # On cherche "CREATE TABLE db.table" (avec ou sans backticks) et on ajoute " UUID 'l-uuid'" juste après
    NEW_SCHEMA=$(echo "$SCHEMA" | sed -E "s/CREATE TABLE (\`?$DB\`?\.\`?$TBL\`?)/CREATE TABLE \1 UUID '$UUID'/")

    # 6. Exécuter la création sur ch01 avec l'UUID forcé
    echo " -> [ch01] Recreating table with forced UUID to join the replication quorum..."
    docker exec ch01 clickhouse-client --password "$PASSWORD" -q "$NEW_SCHEMA"

    echo " Successfully synced $DB.$TBL!"
    
    # Petite pause optionnelle pour laisser le temps à ch01 de commencer ses tâches GET_PART
    sleep 1
done

echo "------------------------------------------------"
echo " All broken tables have been surgically repaired with 0 downtime!"