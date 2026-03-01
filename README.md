
---

# Cluster Staging ClickHouse – Documentation de Dépannage & Récupération (Zero Downtime)

Ce dépôt contient les outils et la documentation nécessaires pour résoudre les problèmes de réplication "Split-Brain" causés par des mismatches d'UUID dans un cluster ClickHouse, en utilisant une approche chirurgicale de manipulation des métadonnées (Metadata Ops) garantissant **0 downtime et 0 transfert lourd de données**.

## 1. Contexte & Environnement de Déploiement

Lors du fonctionnement de routine de notre cluster ClickHouse de staging, une grave panne de réplication a été observée suite à une création manuelle de tables sans la clause `ON CLUSTER`.

**Environnement :**

* **Infrastructure :** Machine Virtuelle à l’IP `192.168.1.126`.
* **Nœuds :** `ch01` (Vide, isolé), `ch02` (Contient les données, en mode `read_only`).
* **Statut initial :** 88 tables affectées, `ch02` contenait ~91M de lignes, `ch01` était bloqué à 0.

---

## 2. Vérification Diagnostique

La cause racine a été identifiée comme un **mismatch d’UUID**. Chaque nœud possédait sa propre version de la table et générait un chemin distinct dans ClickHouse Keeper (`/clickhouse/tables/{uuid}/...`). Les deux nœuds s'ignoraient mutuellement, provoquant un état `is_readonly = 1` pour protéger les données.

### 2.1 Identification du problème

```sql
-- Vérification de la divergence d'UUID sur le cluster
SELECT name, uuid FROM clusterAllReplicas(staging_cluster, system.tables) WHERE database LIKE 'reporting_shop%';

-- Vérification de l'état "Read-Only" et des erreurs Keeper
SELECT database, table, is_readonly, zookeeper_exception
FROM system.replicas WHERE is_readonly = 1;

```

---

## 3. Procédure de Récupération (Approche "Metadata Ops")

L'ancienne méthode consistait à déplacer les données (`RENAME`, `INSERT INTO ... SELECT`). La nouvelle méthode répare uniquement les pointeurs dans Keeper, ce qui évite la saturation des I/O disques et permet une résolution instantanée.

**Étapes de la résolution :**

1. **DROP SYNC (ch01) :** Suppression de la table fantôme et de son chemin Keeper orphelin sur le nœud désynchronisé.
2. **RESTORE REPLICA (ch02) :** Forçage de la reconstruction des métadonnées Keeper à partir des données locales du nœud sain (supprime l'état `read_only`).
3. **EXTRACTION (ch02) :** Récupération du schéma exact (`SHOW CREATE TABLE`) et de l'UUID source.
4. **CREATE WITH UUID (ch01) :** Recréation de la table sur le nœud vide en y injectant explicitement l'UUID de `ch02`.
5. **SYNCHRONISATION :** `ch01` rejoint le quorum Keeper légitime et télécharge les parts de données manquantes en arrière-plan (tâches `GET_PART`).

---

## 4. Option A : Script Bash (Local)

Idéal pour une exécution rapide directement sur l'hôte Docker. Ce script automatise la procédure "Metadata Ops" pour toutes les tables affectées.
Le script se trouve dans : `scripts/fix_cluster.sh`

```bash 
# Exécution
# You should create this on the server
chmod +x scripts/fix_cluster.sh
./scripts/fix_cluster.sh

```

---

## 5. Option B : Ansible (IaC)

Situé dans le dossier `ansible/`, cette méthode permet une gestion distante, idempotente et sécurisée via SSH. Le playbook a été mis à jour pour exécuter la réparation sans downtime.

### 5.1 Sécurité (Ansible Vault)

Le mot de passe de la base de données est chiffré. Pour générer une nouvelle chaîne chiffrée et l'insérer dans `vars.yml` :

```bash
cd ansible
ansible-vault encrypt_string 'stagingpass' --name 'ch_password'

```

### 5.2 Exécution du Playbook

Depuis le dossier `ansible/`, lancez la commande suivante :

```bash
cd ansible
ansible-playbook -i hosts.ini fix_cluster.yml --ask-vault-pass

```

---

## 6. Vérification du Succès & Preuves

Après exécution, les preuves suivantes confirment la santé du cluster :

### 6.1 Alignement des UUID (Preuve Structurelle)

Cette requête doit retourner **0 lignes**, prouvant que toutes les tables partagent désormais le même UUID de coordination à travers le cluster :

```sql
SELECT name, count(DISTINCT uuid) AS unique_uuids 
FROM clusterAllReplicas(staging_cluster, system.tables)
WHERE database LIKE 'reporting_shop%'
GROUP BY name HAVING unique_uuids > 1;

```

### 6.2 Synchronisation des Données (Preuve de Données)

Vérification du nombre total de lignes sur `ch01` (auparavant vide) :

```sql
SELECT database, sum(total_rows) AS total_rows
FROM system.tables WHERE database LIKE 'reporting_shop%'
GROUP BY database;

```

**Résultat attendu :** Les compteurs de `ch01` et `ch02` doivent être parfaitement identiques (~91.5M lignes).

### 6.3 Vérification de la file d'attente (Monitoring)

Pour s'assurer qu'il ne reste aucune tâche bloquée :

```sql
SELECT * FROM system.replication_queue WHERE last_exception != '';

```

### 6.4 Preuves Visuelles

Les captures d'écran suivantes démontrent la réussite de la récupération :

#### État Initial du Cluster

#### Vérification UUID - Résultat Vide (Succès)

#### Synchronisation des Données ch01

#### Synchronisation des Données ch02

---

## 7. Structure du Projet

```text
.
├── ansible
│   ├── fix_cluster.yml  # Playbook principal (Metadata Ops)
│   ├── hosts.ini        # Inventaire (IP: 192.168.1.125)
│   ├── secrets.yml      # Fichier Vault
│   └── vars.yml         # Variables de configuration
├── scripts
│   └── fix_cluster.sh   # Script de secours Bash
├── docs
│   ├── BUG_DESCRIPTION.md # Détails techniques du bug UUID
│   └── GUIDE.md           # Guide d'intervention pas-à-pas
└── assets               # Captures d'écran et schémas

```