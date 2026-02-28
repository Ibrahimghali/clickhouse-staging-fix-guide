
---

# Guide d'Intervention : Réparation de la Réplication ClickHouse (Mismatch de Métadonnées)

Ce guide s'applique lorsque les nœuds d'un cluster ClickHouse possèdent les mêmes tables mais refusent de répliquer les données (souvent marqué par un état `is_readonly` ou des compteurs de lignes divergents).

## 1. Comprendre le Problème : Le "Split-Brain" de Métadonnées

ClickHouse utilise un **UUID** unique pour identifier une table dans le cluster Keeper (ou ZooKeeper).

* **La cause racine :** Si les tables ont été créées manuellement sur chaque nœud (sans la clause `ON CLUSTER`), chaque nœud a généré son propre UUID.
* **Conséquence :** Le nœud A et le nœud B pensent posséder des tables différentes, même si elles portent le même nom. La réplication est donc impossible.

---

## 2. Phase de Diagnostic (Vérification)

Avant toute action, identifiez quel nœud contient la "vérité" (les données).

### Étape A : Identifier le nœud sain

Connectez-vous à chaque nœud et comparez le nombre de lignes :

```sql
SELECT database, table, total_rows 
FROM system.tables 
WHERE database LIKE 'reporting_%';
```

*Note : Dans notre cas, `ch02` était le nœud plein et `ch01` le nœud vide.*

### Étape B : Confirmer le conflit d'UUID

Exécutez cette requête sur les deux nœuds. Si les UUID diffèrent pour la même table, ce guide est la solution :

```sql
SELECT name, uuid FROM system.tables WHERE name = 'nom_de_votre_table';
```

---

## 3. Procédure de Réparation "Safe Fix" (Zéro Perte de Données)

Cette logique repose sur le déplacement temporaire des données pour réaligner les UUID via le cluster.

### Logique en 5 étapes :

1. **Sécuriser :** Renommer la table pleine sur le nœud sain en `table_backup`.
2. **Nettoyer :** Supprimer la table vide/incorrecte sur les autres nœuds.
3. **Réaligner :** Recréer la table en utilisant `CREATE TABLE ... ON CLUSTER`. Cela force un UUID identique partout.
4. **Restaurer :** Réinjecter les données du backup dans la nouvelle table clusterisée.
5. **Finaliser :** Supprimer le backup après vérification.

---

## 4. Automatisation de la Réparation

### Option A : Script Bash (Exécution rapide sur le serveur)

Utilisez ce script si vous avez un accès SSH direct au serveur Docker.

```bash
# Variables à adapter
PASSWORD="votre_password"
CLUSTER_NAME="staging_cluster"

# 1. Récupère les tables en erreur (readonly)
TABLES=$(docker exec ch02 clickhouse-client -q "SELECT database, table FROM system.replicas WHERE is_readonly = 1 FORMAT CSV" | tr -d '"')

for row in $TABLES; do
    DB=$(echo $row | cut -d',' -f1); TBL=$(echo $row | cut -d',' -f2)
    
    # Exécution de la logique Safe Fix
    docker exec ch02 clickhouse-client -q "RENAME TABLE $DB.$TBL TO $DB.${TBL}_backup"
    docker exec ch01 clickhouse-client -q "DROP TABLE IF EXISTS $DB.$TBL"
    docker exec ch02 clickhouse-client -q "CREATE TABLE $DB.$TBL ON CLUSTER $CLUSTER_NAME AS $DB.${TBL}_backup"
    docker exec ch02 clickhouse-client -q "INSERT INTO $DB.$TBL SELECT * FROM $DB.${TBL}_backup"
    docker exec ch02 clickhouse-client -q "DROP TABLE $DB.${TBL}_backup"
done

```

### Option B : Ansible (Gestion Industrielle & Sécurisée)

Idéal pour une exécution à distance sans laisser de mots de passe en clair.

1. **Préparer le coffre-fort :**
`ansible-vault encrypt_string 'votre_pass' --name 'ch_password'`
2. **Lancer le Playbook :**
```bash
ansible-playbook -i hosts.ini fix_cluster.yml --ask-vault-pass

```


*Le playbook va automatiquement détecter les 88 tables en erreur et appliquer la rotation de backup.*

---

## 5. Checklist de Vérification Post-Réparation

Une fois l'automatisation terminée, validez la santé du cluster sur le nœud qui était vide (`ch01`) :

1. **Plus de tables Read-Only :**
```sql
SELECT count(*) FROM system.replicas WHERE is_readonly = 1; -- Doit retourner 0

```


2. **Synchronisation des lignes :**
Les totaux doivent être identiques entre les nœuds.
3. **Vérification de l'UUID :**
```sql
-- Exécuter sur ch01 et ch02 : l'UUID doit être identique maintenant
SELECT name, uuid FROM system.tables WHERE database = 'reporting_shop1_green';

```



---

## 6. Bonnes Pratiques pour l'Avenir

* **Ne jamais créer de tables localement :** Utilisez toujours la clause `ON CLUSTER`.
* **Surveillance :** Mettez en place une alerte sur la table `system.replicas` pour surveiller la colonne `is_readonly`.
* **Macros :** Vérifiez que votre fichier `macros.xml` est correctement configuré avec les variables `{shard}` et `{replica}` uniques par serveur.

---

**Besoin d'aide supplémentaire ?** Consultez les logs Docker avec `docker logs ch01` pour voir les échanges avec Keeper lors de l'étape de création de table.