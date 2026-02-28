# Rapport d'Incident : Désynchronisation des Métadonnées du Cluster ClickHouse Staging

**Date :** 28 Février 2026  
**Statut :** Résolu  
**Système :** Cluster ClickHouse Staging (Répartition Multi-nœuds)  
**Impact :** Rupture de la réplication sur 88 tables, entraînant une inconsistance de données (Nœud 01 vide / Nœud 02 intègre).

## 1. Executive Summary
Une divergence critique de métadonnées a été identifiée sur le cluster de staging (`192.168.1.125`). Bien que le moteur `ReplicatedMergeTree` ait été utilisé, les tables ont été instanciées localement sans passer par le mécanisme de DDL distribué (`ON CLUSTER`). Cette erreur de déploiement a généré des UUIDs divergents pour des tables logiquement identiques, rendant toute réplication via ClickHouse Keeper impossible.

## 2. Analyse Technique (Root Cause Analysis)
Le problème repose sur la gestion de l'**Atomic Database Engine** de ClickHouse. 

* **Divergence d'UUID :** Chaque nœud a généré son propre identifiant unique (UUID) lors de la création manuelle des tables. ClickHouse utilisant l'UUID pour mapper les données physiques dans le répertoire `/store/`, les nœuds pointaient vers des chemins de coordination Keeper différents.
* **État Read-Only :** Face à l'inconsistance entre le schéma local et les logs de réplication dans Keeper, les tables ont été basculées en mode `is_readonly`.
* **Split-Brain Partiel :** Le nœud `ch02` a continué d'ingérer ~91M de lignes, tandis que `ch01` restait à 0, incapable de rejoindre le quorum de réplication.

## 3. Stratégie de Remédiation
La solution a consisté en une **reconstruction atomique de la topologie du cluster** :
1.  Isolation des données saines sur le nœud intègre via un `RENAME` (opération de métadonnées O(1)).
2.  Purge des schémas divergents sur le nœud inconsistant.
3.  Ré-instanciation via DDL Distribué (`ON CLUSTER`) pour garantir un alignement strict des UUIDs.
4.  Ré-injection par insertion massive pour déclencher la synchronisation delta via le protocole natif de ClickHouse.

## 4. Prévention et Automatisation
Pour éviter toute récurrence et garantir l'immutabilité de la configuration, la procédure a été portée sur **Ansible**. L'utilisation d'**Ansible Vault** permet désormais une gestion sécurisée des credentials (chiffrement AES-256) pour les futures opérations de maintenance.