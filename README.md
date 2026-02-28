
---


# Cluster Staging ClickHouse – Documentation de Dépannage & Récupération

Ce dépôt contient les outils et la documentation nécessaires pour résoudre les problèmes de réplication "Split-Brain" causés par des mismatches d'UUID dans un cluster ClickHouse.

## 1. Contexte & Environnement de Déploiement

Lors du fonctionnement de routine de notre cluster ClickHouse de staging, une grave panne de réplication a été observée suite à une création manuelle de tables sans la clause `ON CLUSTER`.

**Environnement :**
* **Infrastructure :** Machine Virtuelle à l’IP `192.168.1.125`.
* **Nœuds :** `ch01` (Vide), `ch02` (Contient les données).
* **Statut initial :** 88 tables affectées, `ch02` contenait ~91M de lignes, `ch01` était vide.

---

## 2. Vérification Diagnostique

La cause racine a été identifiée comme un **mismatch d’UUID**. Chaque nœud possédait sa propre version de la table, empêchant Keeper de synchroniser les journaux de réplication.

### 2.1 Identification du problème
```sql
-- Vérification de la divergence
SELECT name, uuid FROM system.tables WHERE database LIKE 'reporting_shop%';

-- Vérification de l'état "Read-Only"
SELECT database, table, is_readonly, replica_is_active
FROM system.replicas WHERE is_readonly = 1;

```

---

## 3. Procédure de Récupération (La « Réparation Sûre »)

Pour restaurer la réplication sans perte de données, nous appliquons une rotation de table :

1. **RENAME** la table saine (`ch02`) en `_backup`.
2. **DROP** la table incorrecte sur `ch01`.
3. **CREATE** la table **ON CLUSTER** (force l'alignement des UUID).
4. **INSERT** les données depuis la `_backup` vers la nouvelle table.
5. **DROP** la table `_backup`.

---

## 4. Option A : Script Bash (Local)

Idéal pour une exécution rapide directement sur l'hôte Docker.
Le script se trouve dans : `scripts/fix_cluster.sh`

```bash
# Exécution
chmod +x scripts/fix_cluster.sh
./scripts/fix_cluster.sh

```

---

## 5. Option B : Ansible Entreprise (IaC)

Situé dans le dossier `ansible/`, cette méthode permet une gestion distante sécurisée via SSH.

### 5.1 Sécurité (Ansible Vault)

Le mot de passe de la base de données est chiffré. Pour générer une nouvelle chaîne chiffrée et insére en vars.yml:

```bash
ansible-vault encrypt_string 'votre_mot_de_passe' --name 'ch_password'

```

### 5.2 Exécution du Playbook

Depuis le dossier `ansible/`, lancez la commande suivante :

```bash
ansible-playbook -i hosts.ini fix_cluster.yml --ask-vault-pass

```

---

## 6. Vérification du Succès & Preuves

Après exécution, les preuves suivantes confirment la santé du cluster :

### 6.1 Alignement des UUID (Preuve Structurelle)

Cette requête doit retourner **0 lignes**, prouvant que tous les UUID sont identiques sur le cluster :

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

**Résultat attendu :** ~91.5M lignes synchronisées.

---

## 7. Structure du Projet

```text
.
├── ansible
│   ├── fix_cluster.yml  # Playbook principal
│   ├── hosts.ini        # Inventaire (IP: 192.168.1.125)
│   ├── secrets.yml      # Fichier Vault
│   └── vars.yml         # Variables de configuration
├── scripts
│   └── fix_cluster.sh   # Script de secours Bash
├── docs
│   ├── BUG_DESCRIPTION.md # Détails techniques du bug
│   └── GUIDE.md           # Guide d'intervention pas-à-pas
└── assets               # Captures d'écran et schémas

```

```

