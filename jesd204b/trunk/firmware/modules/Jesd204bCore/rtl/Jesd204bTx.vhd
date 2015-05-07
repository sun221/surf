-------------------------------------------------------------------------------
-- Title      : JESD204b multi-lane transmitter module
-------------------------------------------------------------------------------
-- File       : Jesd204bTx.vhd
-- Author     : Uros Legat  <ulegat@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory (Cosylab)
-- Created    : 2015-04-14
-- Last update: 2015-04-14
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description: Receiver JESD204b module.
--              Supports a subset of features from JESD204b standard.
--              Supports sub-class 1 deterministic latency.
--              Supports sub-class 0 non deterministic latency.
--              Features:
--              - Synchronisation of LMFC to SYSREF
--              - Multi-lane operation (L_G: 1-8)
--              Note: The transmitter does not support scrambling (assumes that the receiver does not expect scrambled data)
-------------------------------------------------------------------------------
-- Copyright (c) 2015 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiLitePkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;

use work.Jesd204bPkg.all;

entity Jesd204bTx is
   generic (
      TPD_G             : time                        := 1 ns;

      -- Test tx module instead of GTX
      TEST_G            : boolean                     := false;
           
   -- AXI Lite and stream generics
      AXI_ERROR_RESP_G  : slv(1 downto 0)             := AXI_RESP_SLVERR_C;
      
   -- JESD generics
   
      -- Number of bytes in a frame
      F_G : positive := 2;
      
      -- Number of frames in a multi frame
      K_G : positive := 32;
      
      --Number of lanes (1 to 8)
      L_G : positive := 2;
           
      --JESD204B class (0 and 1 supported)
      SUB_CLASS_G : natural := 1
   );

   port (
   -- AXI interface      
      -- Clocks and Resets
      axiClk         : in    sl;
      axiRst         : in    sl;
      
      -- AXI-Lite Register Interface
      axilReadMaster  : in    AxiLiteReadMasterType;
      axilReadSlave   : out   AxiLiteReadSlaveType;
      axilWriteMaster : in    AxiLiteWriteMasterType;
      axilWriteSlave  : out   AxiLiteWriteSlaveType;
      
      -- AXI Streaming Interface
      txAxisMasterArr_o  : out   AxiStreamMasterArray(L_G-1 downto 0);
      txCtrlArr_i        : in    AxiStreamCtrlArray(L_G-1 downto 0);   
      
   -- JESD
      -- Clocks and Resets   
      devClk_i       : in    sl;  
      devRst_i       : in    sl;
      
      -- SYSREF for subcalss 1 fixed latency
      sysRef_i       : in    sl;
      
      -- Synchronisation input combined from all receivers 
      nSync_i        : in    sl;
      
      -- GT is ready to transmit data after reset
      gtTxReady_i    : in    slv(L_G-1 downto 0);   
      
      -- Data and character inputs from GT (transceivers)
      r_jesdGtTxArr  : out   jesdGtTxLaneTypeArray(L_G-1 downto 0)
   );
end Jesd204bTx;

architecture rtl of Jesd204bTx is
 
   -- Internal signals

   -- Local Multi Frame Clock 
   signal s_lmfc   : sl;

   -- Control and status from AxiLie
   signal s_sysrefDlyTx  : slv(SYSRF_DLY_WIDTH_C-1 downto 0); 
   signal s_enableTx     : slv(L_G-1 downto 0);
   signal s_statusTxArr  : txStatuRegisterArray(L_G-1 downto 0);

   -- Axi Lite interface synced to devClk
   signal sAxiReadMasterDev : AxiLiteReadMasterType;
   signal sAxiReadSlaveDev  : AxiLiteReadSlaveType;
   signal sAxiWriteMasterDev: AxiLiteWriteMasterType;
   signal sAxiWriteSlaveDev : AxiLiteWriteSlaveType;

   -- Axi Stream
   signal s_sampleDataArr : AxiDataTypeArray(L_G-1 downto 0);
   signal s_axisPacketSizeReg : slv(23 downto 0);
   signal s_axisTriggerReg    : slv(L_G-1 downto 0);

   -- Sysref conditioning
   signal  s_sysrefSync : sl;
   signal  s_nSyncSync  : sl;
   signal  s_sysrefRe   : sl;


begin
   -- Check generics TODO add others
   assert (1 < L_G and L_G < 8)  report "L_G must be between 1 and 8"   severity failure;

   -----------------------------------------------------------
   -- AXI
   ---------------------------------------------------------   
   -- AXI stream interface one module per lane
   -- generateAxiStreamLanes : for I in L_G-1 downto 0 generate
      -- AxiStreamLaneTx_INST: entity work.AxiStreamLaneTx
      -- generic map (
         -- TPD_G             => TPD_G,
         -- AXI_ERROR_RESP_G  => AXI_ERROR_RESP_G)
      -- port map (
         -- devClk_i       => devClk_i,
         -- devRst_i       => devRst_i,
         -- packetSize_i   => s_axisPacketSizeReg,
         -- trigger_i      => s_axisTriggerReg(I),
         -- txAxisMaster_o => txAxisMasterArr_o(I),
         -- txCtrl_i       => txCtrlArr_i(I),
         -- enable_i       => s_enableRx(I),
         -- sampleData_i   => s_sampleDataArr(I),
         -- dataReady_i    => s_dataValidVec(I)
      -- );
   -- end generate generateAxiStreamLanes;
   
   generateTestStreamLanes : for I in L_G-1 downto 0 generate
      TestStreamTx_INST: entity work.TestStreamTx
      generic map (
         TPD_G => TPD_G,
         F_G   => F_G)
      port map (
         clk           => devClk_i,
         rst           => devRst_i,
         enable_i      => s_statusTxArr(I)(2),
         strobe_i      => s_lmfc,
         sample_data_o => s_sampleDataArr(I));
   end generate generateTestStreamLanes;
   

   -- Synchronise axiLite interface to devClk
   AxiLiteAsync_INST: entity work.AxiLiteAsync
   generic map (
      TPD_G           => TPD_G,
      NUM_ADDR_BITS_G => 32
   )
   port map (
      -- In
      sAxiClk         => axiClk,
      sAxiClkRst      => axiRst,
      sAxiReadMaster  => axilReadMaster,
      sAxiReadSlave   => axilReadSlave,
      sAxiWriteMaster => axilWriteMaster,
      sAxiWriteSlave  => axilWriteSlave,
      
      -- Out
      mAxiClk         => devClk_i,
      mAxiClkRst      => devRst_i,
      mAxiReadMaster  => sAxiReadMasterDev,
      mAxiReadSlave   => sAxiReadSlaveDev,
      mAxiWriteMaster => sAxiWriteMasterDev,
      mAxiWriteSlave  => sAxiWriteSlaveDev
   );

   -- axiLite register interface
   AxiLiteRegItf_INST: entity work.AxiLiteTxRegItf
   generic map (
      TPD_G            => TPD_G,
      AXI_ERROR_RESP_G => AXI_ERROR_RESP_G,
      L_G              => L_G)
   port map (
      devClk_i        => devClk_i,
      devRst_i        => devRst_i,
      axilReadMaster  => sAxiReadMasterDev,
      axilReadSlave   => sAxiReadSlaveDev,
      axilWriteMaster => sAxiWriteMasterDev,
      axilWriteSlave  => sAxiWriteSlaveDev,
      statusTxArr_i   => s_statusTxArr,
      sysrefDlyTx_o   => s_sysrefDlyTx,
      enableTx_o      => s_enableTx,
      axisTrigger_o   => s_axisTriggerReg,
      axisPacketSize_o=> s_axisPacketSizeReg
   );
 
   -----------------------------------------------------------
   -- SYSREF, SYNC, and LMFC
   -----------------------------------------------------------
   
   -- Synchronise SYSREF input to devClk_i
   Synchronizer_sysref_INST: entity work.Synchronizer
   generic map (
      TPD_G          => TPD_G,
      RST_POLARITY_G => '1',
      OUT_POLARITY_G => '1',
      RST_ASYNC_G    => false,
      STAGES_G       => 2,
      BYPASS_SYNC_G  => false,
      INIT_G         => "0")
   port map (
      clk     => devClk_i,
      rst     => devRst_i,
      dataIn  => sysref_i,
      dataOut => s_sysrefSync
   );
      
   -- Synchronise nSync input to devClk_i
   Synchronizer_nsync_INST: entity work.Synchronizer
   generic map (
      TPD_G          => TPD_G,
      RST_POLARITY_G => '1',
      OUT_POLARITY_G => '1',
      RST_ASYNC_G    => false,
      STAGES_G       => 2,
      BYPASS_SYNC_G  => false,
      INIT_G         => "0")
   port map (
      clk     => devClk_i,
      rst     => devRst_i,
      dataIn  => nSync_i,
      dataOut => s_nSyncSync
   );  
   
   -- LMFC period generator aligned to SYSREF input
   LmfcGen_INST: entity work.LmfcGen
   generic map (
      TPD_G          => TPD_G,
      K_G            => K_G,
      F_G            => F_G)
   port map (
      clk         => devClk_i,
      rst         => devRst_i,
      nSync_i     => s_nSyncSync,
      sysref_i    => s_sysrefSync,
      sysrefRe_o  => s_sysrefRe, -- Rising-edge of SYSREF OUT 
      lmfc_o      => s_lmfc 
   );
   
   -----------------------------------------------------------
   -- Receiver modules (L_G)
   ----------------------------------------------------------- 
   
   -- JESD Transmitter modules (one module per Lane)
   generateTxLanes : for I in L_G-1 downto 0 generate
      JesdTxLane_INST: entity work.JesdTxLane
      generic map (
         TPD_G       => TPD_G,
         F_G         => F_G,
         K_G         => K_G,
         SUB_CLASS_G => SUB_CLASS_G)
      port map (
         devClk_i     => devClk_i,
         devRst_i     => devRst_i,
         enable_i     => s_enableTx(I), -- From AXI lite
         lmfc_i       => s_lmfc,
         nSync_i      => s_nSyncSync,
         gtTxReady_i  => gtTxReady_i(I),
         sysRef_i     => s_sysrefRe,
         status_o     => s_statusTxArr(I), -- To AXI lite
         sampleData_i => s_sampleDataArr(I),
         r_jesdGtTx   => r_jesdGtTxArr(I));
   end generate generateTxLanes;
    
   -- Output assignment
   GT_RST_GEN : for I in L_G-1 downto 0 generate 
      r_jesdGtTxArr(I).gtReset  <= not s_enableTx(I);
   end generate GT_RST_GEN;
   
   -----------------------------------------------------
end rtl;
