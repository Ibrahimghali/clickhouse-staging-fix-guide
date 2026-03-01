
---

# Guide d'Intervention : Réparation de la Réplication ClickHouse (Mismatch d'UUID)

Ce guide résout les cas de "Split-Brain" où les nœuds d'un cluster possèdent les mêmes tables mais refusent de répliquer (état `is_readonly = 1` ou compteurs de lignes divergents).

## 1. Comprendre le Problème

* **Cause racine :** Création manuelle de tables répliquées sur chaque nœud (sans `ON CLUSTER`). ClickHouse génère un **UUID différent** par nœud.
* **Conséquence :** Chaque nœud pointe vers un chemin de coordination Keeper distinct (`/clickhouse/tables/{uuid}/...`). Les nœuds s'ignorent, le quorum est rompu, et les tables basculent en lecture seule par sécurité.

---

## 2. Phase de Diagnostic

Identifiez le nœud sain (avec les données) et le nœud désynchronisé (vide).

**1. Identifier les tables bloquées :**

```sql
SELECT database, table, is_readonly, zookeeper_exception 
FROM system.replicas WHERE is_readonly = 1;

```

**2. Confirmer la divergence d'UUID :**

```sql
-- À exécuter sur les deux nœuds pour comparer
SELECT name, uuid FROM system.tables WHERE name = 'nom_de_votre_table';

```

---

## 3. Procédure de Réparation "Metadata Ops" (Zéro Downtime)

Cette méthode ne déplace **aucune donnée** et répare uniquement les pointeurs dans Keeper.

### Les 4 étapes clés :

1. **Nettoyer (Nœud Vide) :** Supprimer la table fantôme et son chemin Keeper orphelin.
2. **Guérir (Nœud Sain) :** Forcer la reconstruction des métadonnées Keeper depuis le disque local.
3. **Extraire (Nœud Sain) :** Récupérer le schéma exact et l'UUID officiel.
4. **Rejoindre (Nœud Vide) :** Recréer la table en injectant explicitement l'UUID pour forcer la jonction au quorum.

---

## 4. Automatisation de la Réparation

### Option A : Script Bash (Exécution locale)

Ce script itère sur les tables en `is_readonly = 1` et applique la réparation chirurgicale.

```bash
#!/bin/bash
PASSWORD="votre_password"

TABLES=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SELECT database, table FROM system.replicas WHERE is_readonly = 1 FORMAT CSV" | tr -d '"' | tr -d '\r')

for row in $TABLES; do
    DB=$(echo "$row" | cut -d',' -f1); TBL=$(echo "$row" | cut -d',' -f2)
    echo "Fixing $DB.$TBL..."

    # 1. Purge sur ch01
    docker exec ch01 clickhouse-client --password "$PASSWORD" -q "DROP TABLE IF EXISTS $DB.$TBL SYNC;"
    
    # 2. Reconstruction Keeper sur ch02
    docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SYSTEM RESTORE REPLICA $DB.$TBL;"
    
    # 3. Extraction UUID et Schéma de ch02
    UUID=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SELECT uuid FROM system.tables WHERE database='$DB' AND name='$TBL' FORMAT TabSeparatedRaw")
    SCHEMA=$(docker exec ch02 clickhouse-client --password "$PASSWORD" -q "SHOW CREATE TABLE $DB.$TBL FORMAT TabSeparatedRaw")
    
    # 4. Injection UUID et recréation sur ch01
    NEW_SCHEMA=$(echo "$SCHEMA" | sed -E "s/CREATE TABLE (\`?$DB\`?\.\`?$TBL\`?)/CREATE TABLE \1 UUID '$UUID'/")
    docker exec ch01 clickhouse-client --password "$PASSWORD" -q "$NEW_SCHEMA"
done

```

### Option B : Ansible (Recommandé pour la Production)

1. **Chiffrer le mot de passe :**

```bash
ansible-vault encrypt_string 'votre_pass' --name 'ch_password'

```

2. **Lancer le Playbook (qui exécute la logique Metadata Ops ci-dessus) :**

```bash
ansible-playbook -i hosts.ini fix_cluster.yml --ask-vault-pass

```

---

## 5. Checklist de Vérification Post-Réparation

Validez la santé du cluster sur les deux nœuds :

1. **Zéro table en erreur :**

```sql
SELECT count(*) FROM system.replicas WHERE is_readonly = 1; -- Doit être 0

```

2. **Alignement parfait des UUIDs :**

```sql
-- Doit retourner 0 lignes
SELECT name, count(DISTINCT uuid) AS unique_uuids 
FROM clusterAllReplicas(staging_cluster, system.tables)
WHERE database LIKE 'reporting_%'
GROUP BY name HAVING unique_uuids > 1;

```

3. **Synchronisation en cours ou terminée :**
Vérifiez que le nombre de lignes est identique sur `ch01` et `ch02`, ou surveillez la file d'attente de réplication sur `ch01` :

```sql
SELECT * FROM system.replication_queue WHERE type = 'GET_PART';

```

---

## 6. Bonnes Pratiques

* **Interdiction stricte :** Ne créez jamais de tables répliquées localement nœud par nœud.
* **Standard :** Utilisez systématiquement `CREATE TABLE ... ON CLUSTER nom_cluster`.
* **Macros :** Assurez-vous que `/clickhouse/tables/{uuid}/{shard}` et `{replica}` sont bien définis dans le `config.xml` de chaque nœud.