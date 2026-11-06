extend_mw_layers
sh rm -rf ../database/udcounter_mw
sh mkdir -p ../database
create_mw_lib -technology /home/tools/pdk/SAED14nm_EDK_03_2025/SAED14nm_EDK_TECH_DATA/tf/saed14nm_1p9m_icc.tf \
  -mw_reference_library {/home/tools/pdk/SAED14nm_EDK_03_2025/SAED14nm_EDK_STD_RVT/milkyway/saed14rvt.mw} \
  ../database/udcounter_mw
open_mw_lib ../database/udcounter_mw

set hdlin_enable_rtldrc_info true
set enable_recovery_removal_arcs false

