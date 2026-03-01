
---
# Rapport d'Incident : Désynchronisation des Métadonnées du Cluster ClickHouse Staging

**Date :** 28 Février 2026  
**Statut :** Résolu (Zéro Downtime, Zéro Perte de Données)  
**Système :** Cluster ClickHouse Staging (Répartition Multi-nœuds avec ClickHouse Keeper)  
**Impact :** Rupture de la réplication sur 88 tables, entraînant une inconsistance de données (`ch01` vide / `ch02` intègre mais bloqué en lecture seule).

## 1. Executive Summary

Une divergence critique de métadonnées a été identifiée sur le cluster de staging (`192.168.1.125`). Bien que le moteur `ReplicatedMergeTree` ait été utilisé, les tables ont été instanciées localement sans passer par le mécanisme de DDL distribué (`ON CLUSTER`). Cette erreur de déploiement a généré des UUIDs divergents pour des tables logiquement identiques, rendant toute réplication via ClickHouse Keeper impossible. L'incident a été résolu chirurgicalement via une manipulation directe des métadonnées, évitant ainsi un transfert de données lourd et garantissant une disponibilité continue.

## 2. Analyse Technique (Root Cause Analysis)

Le problème repose sur la gestion de l'**Atomic Database Engine** de ClickHouse et sa relation avec Keeper.

* **Divergence d'UUID :** Chaque nœud a généré son propre identifiant unique (UUID) lors de la création manuelle des tables. ClickHouse utilisant l'UUID pour mapper les données physiques dans le répertoire `/store/` et dans Keeper (`/clickhouse/tables/{uuid}/...`), les nœuds pointaient vers des espaces de coordination totalement isolés.
* **Perte de Quorum et Exception Keeper :** Le nœud contenant les données (`ch02`) a perdu son arborescence dans Keeper (`Coordination error: No node. KEEPER_EXCEPTION`). Par mécanisme d'auto-préservation, ClickHouse a immédiatement basculé ces tables en mode `is_readonly = 1`.
* **Split-Brain Partiel :** Le nœud `ch02` possédait ~91M de lignes inaccessibles en écriture, tandis que `ch01` restait à 0 ligne, bloqué sur un chemin Keeper vide et orphelin.

## 3. Stratégie de Remédiation ("Metadata Ops")

Au lieu d'opter pour une approche destructrice et coûteuse en I/O (déplacement de données via `INSERT INTO ... SELECT`), la solution a consisté en une **reconstruction chirurgicale des pointeurs Keeper** (Metadata Ops), garantissant 0 downtime :

1. **Nettoyage du nœud désynchronisé (`ch01`) :** Suppression de la table locale "fantôme" et purge synchrone de son chemin Keeper orphelin via un `DROP TABLE ... SYNC`.
2. **Guérison du nœud source (`ch02`) :** Exécution de la commande `SYSTEM RESTORE REPLICA`. Cette opération force ClickHouse à lire ses données locales sur disque pour reconstruire intégralement la structure des métadonnées manquantes dans Keeper, sortant ainsi le nœud de son état `read_only`.
3. **Extraction de la vérité (`ch02`) :** Récupération du schéma DDL exact et de l'UUID officiel nouvellement restauré.
4. **Jonction au Quorum (`ch01`) :** Recréation de la table en injectant explicitement l'UUID source (`CREATE TABLE ... UUID '...'`). Cela force `ch01` à s'abonner au chemin Keeper de `ch02`, déclenchant instantanément le rapatriement asynchrone des parts de données manquantes (tâches `GET_PART`).

## 4. Prévention et Automatisation

Pour garantir une résolution rapide, sans erreur humaine et pérenne :

* **Automatisation IaC :** La procédure de "Metadata Ops" a été entièrement portée sur **Ansible**. Le script itère dynamiquement sur les tables en erreur, extrait les UUIDs et synchronise les métadonnées en quelques secondes.
* **Sécurisation :** L'utilisation d'**Ansible Vault** permet une gestion sécurisée des credentials (chiffrement AES-256).
---
