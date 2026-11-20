# GLITCH TIDE — PHASE 1 + R1 + R2 + R3 + R4 + R5 INDEPENDENT REVIEW PACKAGE
Packaged: 2026-11-20 11:00 IST
Project: ~/workspace/your_files/glitch-tide-v1.1/ (HEAD 6ee6d21, uncommitted Phase 1 + R1 + R2 + R3 + R4 + R5 changes)
Basis: Qwen R4 audit verdict REJECT; R5 repairs the confirmed R4 findings (R5-1..R5-8) under a mandatory repair-verification loop with an acceptance checklist. N5 economy unchanged.

## git rev-parse HEAD
6ee6d217019af75f3f0c54357150aad470060aaa

## git status --short
 M scripts/harness-lune/shared/Economy.luau
 M scripts/harness-lune/shared/Remotes.luau
 M scripts/harness-lune/shared/Types.luau
 M src/client/Controllers/BaseController.luau
 M src/client/Controllers/HUDController.luau
 M src/client/Controllers/InteractionController.luau
 M src/client/Controllers/QuestController.luau
 M src/client/Controllers/ShopController.luau
 M src/server/Services/AbilityService.luau
 M src/server/Services/BaseService.luau
 M src/server/Services/CarryService.luau
 M src/server/Services/ConveyorService.luau
 M src/server/Services/DataService.luau
 M src/server/Services/EconomyService.luau
 M src/server/Services/ExpeditionService.luau
 M src/server/Services/FusionService.luau
 M src/server/Services/GameManager.luau
 M src/server/Services/LaboratoryService.luau
 M src/server/Services/MutationService.luau
 M src/server/Services/ProgressionService.luau
 M src/server/Services/QuestService.luau
 M src/server/Services/RaidService.luau
 M src/shared/Economy.luau
 M src/shared/Remotes.luau
 M src/shared/Types.luau
?? docs/N5_BANKED_INCOME_DESIGN_NOTE.md
?? docs/PERSISTENCE_DESIGN_NOTE.md
?? docs/PHASE1_REPAIRS_REPORT.md
?? docs/R2_REPAIRS_REPORT.md
?? docs/R3_REPAIRS_REPORT.md
?? docs/R4_ACCEPTANCE_CHECKLIST.md
?? docs/R4_REPAIRS_REPORT.md
?? docs/R5_ACCEPTANCE_CHECKLIST.md
?? docs/R5_REPAIRS_REPORT.md
?? scripts/phase1-tests/

## git diff --stat HEAD
 scripts/harness-lune/shared/Economy.luau          |   19 +-
 scripts/harness-lune/shared/Remotes.luau          |    9 +
 scripts/harness-lune/shared/Types.luau            |    6 +
 src/client/Controllers/BaseController.luau        |   86 +-
 src/client/Controllers/HUDController.luau         |   71 +
 src/client/Controllers/InteractionController.luau |   13 +-
 src/client/Controllers/QuestController.luau       |    2 +-
 src/client/Controllers/ShopController.luau        |   78 +-
 src/server/Services/AbilityService.luau           |   22 +-
 src/server/Services/BaseService.luau              |  396 ++-
 src/server/Services/CarryService.luau             |   41 +-
 src/server/Services/ConveyorService.luau          |   10 +
 src/server/Services/DataService.luau              | 1997 ++++++++++++++-
 src/server/Services/EconomyService.luau           |   10 +
 src/server/Services/ExpeditionService.luau        |  125 +-
 src/server/Services/FusionService.luau            |  130 +-
 src/server/Services/GameManager.luau              |   90 +-
 src/server/Services/LaboratoryService.luau        |   57 +-
 src/server/Services/MutationService.luau          |  153 +-
 src/server/Services/ProgressionService.luau       |   69 +-
 src/server/Services/QuestService.luau             |  100 +-
 src/server/Services/RaidService.luau              | 2796 ++++++++++++++++++++-
 src/shared/Economy.luau                           |   19 +-
 src/shared/Remotes.luau                           |    9 +
 src/shared/Types.luau                             |    6 +
 25 files changed, 5950 insertions(+), 364 deletions(-)

## Modified tracked files (25)
- scripts/harness-lune/shared/Economy.luau
- scripts/harness-lune/shared/Remotes.luau
- scripts/harness-lune/shared/Types.luau
- src/client/Controllers/BaseController.luau
- src/client/Controllers/HUDController.luau
- src/client/Controllers/InteractionController.luau
- src/client/Controllers/QuestController.luau
- src/client/Controllers/ShopController.luau
- src/server/Services/AbilityService.luau
- src/server/Services/BaseService.luau
- src/server/Services/CarryService.luau
- src/server/Services/ConveyorService.luau
- src/server/Services/DataService.luau
- src/server/Services/EconomyService.luau
- src/server/Services/ExpeditionService.luau
- src/server/Services/FusionService.luau
- src/server/Services/GameManager.luau
- src/server/Services/LaboratoryService.luau
- src/server/Services/MutationService.luau
- src/server/Services/ProgressionService.luau
- src/server/Services/QuestService.luau
- src/server/Services/RaidService.luau
- src/shared/Economy.luau
- src/shared/Remotes.luau
- src/shared/Types.luau

## Untracked files
- docs/N5_BANKED_INCOME_DESIGN_NOTE.md
- docs/PERSISTENCE_DESIGN_NOTE.md
- docs/PHASE1_REPAIRS_REPORT.md
- docs/R2_REPAIRS_REPORT.md
- docs/R3_REPAIRS_REPORT.md
- docs/R4_ACCEPTANCE_CHECKLIST.md
- docs/R4_REPAIRS_REPORT.md
- docs/R5_ACCEPTANCE_CHECKLIST.md
- docs/R5_REPAIRS_REPORT.md
- scripts/phase1-tests/expedition/01_expedition_in_transit.luau
- scripts/phase1-tests/expedition/mutant/01_mutant_control.luau
- scripts/phase1-tests/expedition/mutant/ExpeditionService.luau
- scripts/phase1-tests/expedition/mutant/make_mutant.sh
- scripts/phase1-tests/expedition/mutant/run_mutant.sh
- scripts/phase1-tests/expedition/refresh.sh
- scripts/phase1-tests/expedition/run.sh
- scripts/phase1-tests/expedition/services/ExpeditionService.luau
- scripts/phase1-tests/expedition/shared/AchievementDefs.luau
- scripts/phase1-tests/expedition/shared/CharacterModels.luau
- scripts/phase1-tests/expedition/shared/Characters.luau
- scripts/phase1-tests/expedition/shared/Companions.luau
- scripts/phase1-tests/expedition/shared/Config.luau
- scripts/phase1-tests/expedition/shared/Dimensions.luau
- scripts/phase1-tests/expedition/shared/Economy.luau
- scripts/phase1-tests/expedition/shared/ExpeditionDefs.luau
- scripts/phase1-tests/expedition/shared/LabDefs.luau
- scripts/phase1-tests/expedition/shared/Mutations.luau
- scripts/phase1-tests/expedition/shared/Powers.luau
- scripts/phase1-tests/expedition/shared/Remotes.luau
- scripts/phase1-tests/expedition/shared/Synergies.luau
- scripts/phase1-tests/expedition/shared/Types.luau
- scripts/phase1-tests/expedition/shared/Utils.luau
- scripts/phase1-tests/fusion-payload/01_fusion_payload.luau
- scripts/phase1-tests/fusion-payload/02_fusion_partials.luau
- scripts/phase1-tests/fusion-payload/refresh.sh
- scripts/phase1-tests/fusion-payload/run.sh
- scripts/phase1-tests/harness.luau
- scripts/phase1-tests/lifecycle/01_thief_leaves_mid_theft.luau
- scripts/phase1-tests/lifecycle/02_shutdown_in_transit.luau
- scripts/phase1-tests/lifecycle/03_rejoin_reconciles_stale.luau
- scripts/phase1-tests/lifecycle/04_victim_leaves_mid_theft.luau
- scripts/phase1-tests/lifecycle/05_double_save_race.luau
- scripts/phase1-tests/lifecycle/06_pending_sidecar.luau
- scripts/phase1-tests/lifecycle/07_return_persistence.luau
- scripts/phase1-tests/lifecycle/08_return_residuals.luau
- scripts/phase1-tests/lifecycle/lifecycle_data.luau
- scripts/phase1-tests/lifecycle/mutant/01_mutant_control.luau
- scripts/phase1-tests/lifecycle/mutant/RaidServiceLifecycle.luau
- scripts/phase1-tests/lifecycle/mutant/make_mutant.sh
- scripts/phase1-tests/lifecycle/mutant/run_mutant.sh
- scripts/phase1-tests/lifecycle/refresh.sh
- scripts/phase1-tests/lifecycle/run.sh
- scripts/phase1-tests/lifecycle/services/RaidService.luau
- scripts/phase1-tests/lifecycle/shared/AchievementDefs.luau
- scripts/phase1-tests/lifecycle/shared/CharacterModels.luau
- scripts/phase1-tests/lifecycle/shared/Characters.luau
- scripts/phase1-tests/lifecycle/shared/Companions.luau
- scripts/phase1-tests/lifecycle/shared/Config.luau
- scripts/phase1-tests/lifecycle/shared/Dimensions.luau
- scripts/phase1-tests/lifecycle/shared/Economy.luau
- scripts/phase1-tests/lifecycle/shared/ExpeditionDefs.luau
- scripts/phase1-tests/lifecycle/shared/LabDefs.luau
- scripts/phase1-tests/lifecycle/shared/Mutations.luau
- scripts/phase1-tests/lifecycle/shared/Powers.luau
- scripts/phase1-tests/lifecycle/shared/Remotes.luau
- scripts/phase1-tests/lifecycle/shared/Synergies.luau
- scripts/phase1-tests/lifecycle/shared/Types.luau
- scripts/phase1-tests/lifecycle/shared/Utils.luau
- scripts/phase1-tests/mutation-payload/01_mutation_payload.luau
- scripts/phase1-tests/mutation-payload/02_legacy_mutation.luau
- scripts/phase1-tests/mutation-payload/refresh.sh
- scripts/phase1-tests/mutation-payload/run.sh
- scripts/phase1-tests/persistence/01_escrow_read_failure.luau
- scripts/phase1-tests/persistence/02_pending_read_failure.luau
- scripts/phase1-tests/persistence/03_empty_sidecar_accepts.luau
- scripts/phase1-tests/persistence/04_failed_write_reports.luau
- scripts/phase1-tests/persistence/05_concurrent_escrow.luau
- scripts/phase1-tests/persistence/06_concurrent_pending.luau
- scripts/phase1-tests/persistence/07_dedupe_and_callback_purity.luau
- scripts/phase1-tests/persistence/08_merge_on_load_failure.luau
- scripts/phase1-tests/persistence/09_exactly_once_after_failed_delete.luau
- scripts/phase1-tests/persistence/10_save_failed_recovery.luau
- scripts/phase1-tests/persistence/11_two_transactions_same_instance.luau
- scripts/phase1-tests/persistence/12_healthy_delivery_ledger.luau
- scripts/phase1-tests/persistence/13_return_crash_online.luau
- scripts/phase1-tests/persistence/14_return_crash_offline_escrow.luau
- scripts/phase1-tests/persistence/15_return_save_failures.luau
- scripts/phase1-tests/persistence/16_return_recovery_idempotent.luau
- scripts/phase1-tests/persistence/datastore_stub.luau
- scripts/phase1-tests/persistence/mutant/01_mutant_control.luau
- scripts/phase1-tests/persistence/mutant/02_mutant_control.luau
- scripts/phase1-tests/persistence/mutant/03_mutant_control.luau
- scripts/phase1-tests/persistence/mutant/04_mutant_control.luau
- scripts/phase1-tests/persistence/mutant/DataServiceOld.luau
- scripts/phase1-tests/persistence/mutant/run_mutant.sh
- scripts/phase1-tests/persistence/persistence_env.luau
- scripts/phase1-tests/persistence/refresh.sh
- scripts/phase1-tests/persistence/run.sh
- scripts/phase1-tests/persistence/services/DataService.luau
- scripts/phase1-tests/persistence/shared/AchievementDefs.luau
- scripts/phase1-tests/persistence/shared/CharacterModels.luau
- scripts/phase1-tests/persistence/shared/Characters.luau
- scripts/phase1-tests/persistence/shared/Companions.luau
- scripts/phase1-tests/persistence/shared/Config.luau
- scripts/phase1-tests/persistence/shared/Dimensions.luau
- scripts/phase1-tests/persistence/shared/Economy.luau
- scripts/phase1-tests/persistence/shared/ExpeditionDefs.luau
- scripts/phase1-tests/persistence/shared/LabDefs.luau
- scripts/phase1-tests/persistence/shared/Mutations.luau
- scripts/phase1-tests/persistence/shared/Powers.luau
- scripts/phase1-tests/persistence/shared/Remotes.luau
- scripts/phase1-tests/persistence/shared/Synergies.luau
- scripts/phase1-tests/persistence/shared/Types.luau
- scripts/phase1-tests/persistence/shared/Utils.luau
- scripts/phase1-tests/quest/main.luau
- scripts/phase1-tests/quest/run.sh
- scripts/phase1-tests/quest/stubs/Characters.luau
- scripts/phase1-tests/quest/stubs/Economy.luau
- scripts/phase1-tests/quest/stubs/Remotes.luau
- scripts/phase1-tests/quest/stubs/state.luau
- scripts/phase1-tests/r4-transactions/01_r4_1_stale_escrow_duplication.luau
- scripts/phase1-tests/r4-transactions/02_r4_2_park_retry.luau
- scripts/phase1-tests/r4-transactions/03_r4_3_rollback_clamp.luau
- scripts/phase1-tests/r4-transactions/04_r4_4_voided_delivery_farming.luau
- scripts/phase1-tests/r4-transactions/05_r4_6_txid_guid.luau
- scripts/phase1-tests/r4-transactions/06_r4_7_session_lease.luau
- scripts/phase1-tests/r4-transactions/07_r4_8_save_shutdown.luau
- scripts/phase1-tests/r4-transactions/08_r4_8_load_failed_warning.luau
- scripts/phase1-tests/r4-transactions/09_r4_10_legacy_recovery.luau
- scripts/phase1-tests/r4-transactions/10_r4_3_spending_routes.luau
- scripts/phase1-tests/r4-transactions/mutant/DataServiceR3.luau
- scripts/phase1-tests/r4-transactions/mutant/RaidServiceR3.luau
- scripts/phase1-tests/r4-transactions/mutant/m01_r4_1_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m02_r4_2_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m03_r4_3_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m04_r4_4_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m05_r4_6_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m06_r4_7_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/m07_r4_8_old_logic.luau
- scripts/phase1-tests/r4-transactions/mutant/make_mutant.sh
- scripts/phase1-tests/r4-transactions/mutant/run_mutant.sh
- scripts/phase1-tests/r4-transactions/r4_env.luau
- scripts/phase1-tests/r4-transactions/refresh.sh
- scripts/phase1-tests/r4-transactions/run.sh
- scripts/phase1-tests/r4-transactions/services/AbilityService.luau
- scripts/phase1-tests/r4-transactions/services/BaseService.luau
- scripts/phase1-tests/r4-transactions/services/ConveyorService.luau
- scripts/phase1-tests/r4-transactions/services/DataService.luau
- scripts/phase1-tests/r4-transactions/services/DataServiceB.luau
- scripts/phase1-tests/r4-transactions/services/EconomyService.luau
- scripts/phase1-tests/r4-transactions/services/LaboratoryService.luau
- scripts/phase1-tests/r4-transactions/services/MapBuilderStub.luau
- scripts/phase1-tests/r4-transactions/services/RaidService.luau
- scripts/phase1-tests/r4-transactions/services/RaidServiceB.luau
- scripts/phase1-tests/r4-transactions/shared/AchievementDefs.luau
- scripts/phase1-tests/r4-transactions/shared/CharacterModels.luau
- scripts/phase1-tests/r4-transactions/shared/Characters.luau
- scripts/phase1-tests/r4-transactions/shared/Companions.luau
- scripts/phase1-tests/r4-transactions/shared/Config.luau
- scripts/phase1-tests/r4-transactions/shared/Dimensions.luau
- scripts/phase1-tests/r4-transactions/shared/Economy.luau
- scripts/phase1-tests/r4-transactions/shared/ExpeditionDefs.luau
- scripts/phase1-tests/r4-transactions/shared/LabDefs.luau
- scripts/phase1-tests/r4-transactions/shared/Mutations.luau
- scripts/phase1-tests/r4-transactions/shared/Powers.luau
- scripts/phase1-tests/r4-transactions/shared/Remotes.luau
- scripts/phase1-tests/r4-transactions/shared/Synergies.luau
- scripts/phase1-tests/r4-transactions/shared/Types.luau
- scripts/phase1-tests/r4-transactions/shared/Utils.luau
- scripts/phase1-tests/r5-transactions/01_r5_1_profile_destruction.luau
- scripts/phase1-tests/r5-transactions/02_r5_5_fail_open_escrow.luau
- scripts/phase1-tests/r5-transactions/03_r5_3_durable_reward_voiding.luau
- scripts/phase1-tests/r5-transactions/04_r5_4_session_lease_races.luau
- scripts/phase1-tests/r5-transactions/05_r5_2_unhealthy_session_ownership.luau
- scripts/phase1-tests/r5-transactions/06_rebirth_prestige.luau
- scripts/phase1-tests/r5-transactions/07_r5_7_bounded_shutdown_hooks.luau
- scripts/phase1-tests/r5-transactions/mutant/BaseServiceR5Pre2.luau
- scripts/phase1-tests/r5-transactions/mutant/DataServiceR4.luau
- scripts/phase1-tests/r5-transactions/mutant/DataServiceR5Pre7.luau
- scripts/phase1-tests/r5-transactions/mutant/MapBuilderStub.luau
- scripts/phase1-tests/r5-transactions/mutant/ProgressionServiceOld.luau
- scripts/phase1-tests/r5-transactions/mutant/RaidServiceR4.luau
- scripts/phase1-tests/r5-transactions/mutant/RaidServiceR5Pre2.luau
- scripts/phase1-tests/r5-transactions/mutant/m01_r5_1_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/m01_rebirth_prestige_old.luau
- scripts/phase1-tests/r5-transactions/mutant/m02_r5_5_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/m03_r5_3_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/m04_r5_4_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/m05_r5_2_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/m07_r5_7_old_logic.luau
- scripts/phase1-tests/r5-transactions/mutant/make_mutant.sh
- scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_1_5.sh
- scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_2_7.sh
- scripts/phase1-tests/r5-transactions/mutant/make_mutant_r5_3_4.sh
- scripts/phase1-tests/r5-transactions/mutant/run_mutant.sh
- scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_1_5.sh
- scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_2_7.sh
- scripts/phase1-tests/r5-transactions/mutant/run_mutant_r5_3_4.sh
- scripts/phase1-tests/r5-transactions/r5_env.luau
- scripts/phase1-tests/r5-transactions/refresh.sh
- scripts/phase1-tests/r5-transactions/refresh_06.sh
- scripts/phase1-tests/r5-transactions/run.sh
- scripts/phase1-tests/r5-transactions/run_06.sh
- scripts/phase1-tests/r5-transactions/services/DataService.luau
- scripts/phase1-tests/r5-transactions/services/DataServiceB.luau
- scripts/phase1-tests/r5-transactions/services/ProgressionService.luau
- scripts/phase1-tests/r5-transactions/shared/AchievementDefs.luau
- scripts/phase1-tests/r5-transactions/shared/CharacterModels.luau
- scripts/phase1-tests/r5-transactions/shared/Characters.luau
- scripts/phase1-tests/r5-transactions/shared/Companions.luau
- scripts/phase1-tests/r5-transactions/shared/Config.luau
- scripts/phase1-tests/r5-transactions/shared/Dimensions.luau
- scripts/phase1-tests/r5-transactions/shared/Economy.luau
- scripts/phase1-tests/r5-transactions/shared/ExpeditionDefs.luau
- scripts/phase1-tests/r5-transactions/shared/LabDefs.luau
- scripts/phase1-tests/r5-transactions/shared/Mutations.luau
- scripts/phase1-tests/r5-transactions/shared/Powers.luau
- scripts/phase1-tests/r5-transactions/shared/Remotes.luau
- scripts/phase1-tests/r5-transactions/shared/Synergies.luau
- scripts/phase1-tests/r5-transactions/shared/Types.luau
- scripts/phase1-tests/r5-transactions/shared/Utils.luau
- scripts/phase1-tests/store/01_store.luau
- scripts/phase1-tests/store/02_delivery.luau
- scripts/phase1-tests/store/refresh.sh
- scripts/phase1-tests/store/run.sh
- scripts/phase1-tests/store/services/BaseService.luau
- scripts/phase1-tests/store/services/MapBuilderStub.luau
- scripts/phase1-tests/store/shared/AchievementDefs.luau
- scripts/phase1-tests/store/shared/CharacterModels.luau
- scripts/phase1-tests/store/shared/Characters.luau
- scripts/phase1-tests/store/shared/Companions.luau
- scripts/phase1-tests/store/shared/Config.luau
- scripts/phase1-tests/store/shared/Dimensions.luau
- scripts/phase1-tests/store/shared/Economy.luau
- scripts/phase1-tests/store/shared/ExpeditionDefs.luau
- scripts/phase1-tests/store/shared/LabDefs.luau
- scripts/phase1-tests/store/shared/Mutations.luau
- scripts/phase1-tests/store/shared/Powers.luau
- scripts/phase1-tests/store/shared/Remotes.luau
- scripts/phase1-tests/store/shared/Synergies.luau
- scripts/phase1-tests/store/shared/Types.luau
- scripts/phase1-tests/store/shared/Utils.luau
- scripts/phase1-tests/theft/01_fuse_in_transit.luau
- scripts/phase1-tests/theft/02_guards_in_transit.luau
- scripts/phase1-tests/theft/03_return_exactly_once.luau
- scripts/phase1-tests/theft/04_delivery_exactly_once.luau
- scripts/phase1-tests/theft/05_expedition_guards.luau
- scripts/phase1-tests/theft/06a_return_preserves_fields_base.luau
- scripts/phase1-tests/theft/06b_return_preserves_fields_local.luau
- scripts/phase1-tests/theft/07_conservation.luau
- scripts/phase1-tests/theft/08_companion_and_mirror.luau
- scripts/phase1-tests/theft/09_watchdog_reconcile.luau
- scripts/phase1-tests/theft/10_stale_mutation.luau
- scripts/phase1-tests/theft/11_pending_reward.luau
- scripts/phase1-tests/theft/12_config_driven_share.luau
- scripts/phase1-tests/theft/13_share_rounding_conservation.luau
- scripts/phase1-tests/theft/mutant/01_mutant_control.luau
- scripts/phase1-tests/theft/mutant/02_mutant_control.luau
- scripts/phase1-tests/theft/mutant/03_mutant_control.luau
- scripts/phase1-tests/theft/mutant/04_mutant_control.luau
- scripts/phase1-tests/theft/mutant/05_mutant_control.luau
- scripts/phase1-tests/theft/mutant/06_mutant_control.luau
- scripts/phase1-tests/theft/mutant/07_mutant_control.luau
- scripts/phase1-tests/theft/mutant/RaidServiceE2.luau
- scripts/phase1-tests/theft/mutant/RaidServiceM5.luau
- scripts/phase1-tests/theft/mutant/RaidServiceM8.luau
- scripts/phase1-tests/theft/mutant/RaidServiceP4.luau
- scripts/phase1-tests/theft/mutant/RaidServiceR13.luau
- scripts/phase1-tests/theft/mutant/RaidServiceWatchdog.luau
- scripts/phase1-tests/theft/mutant/economy/services/RaidService.luau
- scripts/phase1-tests/theft/mutant/economy/shared/AchievementDefs.luau
- scripts/phase1-tests/theft/mutant/economy/shared/CharacterModels.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Characters.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Companions.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Config.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Dimensions.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Economy.luau
- scripts/phase1-tests/theft/mutant/economy/shared/ExpeditionDefs.luau
- scripts/phase1-tests/theft/mutant/economy/shared/LabDefs.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Mutations.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Powers.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Remotes.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Synergies.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Types.luau
- scripts/phase1-tests/theft/mutant/economy/shared/Utils.luau
- scripts/phase1-tests/theft/mutant/make_mutant.sh
- scripts/phase1-tests/theft/mutant/run_mutant.sh
- scripts/phase1-tests/theft/refresh.sh
- scripts/phase1-tests/theft/run_all.sh
- scripts/phase1-tests/theft/services/CarryService.luau
- scripts/phase1-tests/theft/services/FusionService.luau
- scripts/phase1-tests/theft/services/LaboratoryService.luau
- scripts/phase1-tests/theft/services/MutationService.luau
- scripts/phase1-tests/theft/services/RaidService.luau
- scripts/phase1-tests/theft/shared/AchievementDefs.luau
- scripts/phase1-tests/theft/shared/CharacterModels.luau
- scripts/phase1-tests/theft/shared/Characters.luau
- scripts/phase1-tests/theft/shared/Companions.luau
- scripts/phase1-tests/theft/shared/Config.luau
- scripts/phase1-tests/theft/shared/Dimensions.luau
- scripts/phase1-tests/theft/shared/Economy.luau
- scripts/phase1-tests/theft/shared/ExpeditionDefs.luau
- scripts/phase1-tests/theft/shared/LabDefs.luau
- scripts/phase1-tests/theft/shared/Mutations.luau
- scripts/phase1-tests/theft/shared/Powers.luau
- scripts/phase1-tests/theft/shared/Remotes.luau
- scripts/phase1-tests/theft/shared/Synergies.luau
- scripts/phase1-tests/theft/shared/Types.luau
- scripts/phase1-tests/theft/shared/Utils.luau
- scripts/phase1-tests/wiring/01_production_companion_wiring.luau
- scripts/phase1-tests/wiring/refresh.sh
- scripts/phase1-tests/wiring/run.sh
- scripts/phase1-tests/wiring/services/BaseService.luau
- scripts/phase1-tests/wiring/services/CarryService.luau
- scripts/phase1-tests/wiring/services/CompanionService.luau
- scripts/phase1-tests/wiring/services/ConveyorService.luau
- scripts/phase1-tests/wiring/services/GameManager.luau
- scripts/phase1-tests/wiring/services/MapBuilderStub.luau
- scripts/phase1-tests/wiring/shared/AchievementDefs.luau
- scripts/phase1-tests/wiring/shared/CharacterModels.luau
- scripts/phase1-tests/wiring/shared/Characters.luau
- scripts/phase1-tests/wiring/shared/Companions.luau
- scripts/phase1-tests/wiring/shared/Config.luau
- scripts/phase1-tests/wiring/shared/Dimensions.luau
- scripts/phase1-tests/wiring/shared/Economy.luau
- scripts/phase1-tests/wiring/shared/ExpeditionDefs.luau
- scripts/phase1-tests/wiring/shared/LabDefs.luau
- scripts/phase1-tests/wiring/shared/Mutations.luau
- scripts/phase1-tests/wiring/shared/Powers.luau
- scripts/phase1-tests/wiring/shared/Remotes.luau
- scripts/phase1-tests/wiring/shared/Synergies.luau
- scripts/phase1-tests/wiring/shared/Types.luau
- scripts/phase1-tests/wiring/shared/Utils.luau

## Notes
- GlitchTide.rbxl is the existing committed place file, included exactly as-is (NOT rebuilt).
- .git directory included in full (history + metadata). No credentials, keys, or tokens are in this tree.
- Nothing was committed, pushed, branched, or published to produce this archive.
- R5 report: docs/R5_REPAIRS_REPORT.md; acceptance checklist: docs/R5_ACCEPTANCE_CHECKLIST.md; persistence design note: docs/PERSISTENCE_DESIGN_NOTE.md; N5 note: docs/N5_BANKED_INCOME_DESIGN_NOTE.md.
- R4 audit file AUDIT_REPORT_R4.md never arrived on disk; R5 worked from the pasted findings + the R4 report + code verification.
