-------------------------------------------------------------------------------
-- Title      : JESD204b multi-lane receiver module
-------------------------------------------------------------------------------
-- File       : Jesd204bRx.vhd
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
-------------------------------------------------------------------------------
-- Copyright (c) 2014 SLAC National Accelerator Laboratory
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

entity Jesd204bRx is
   generic (
      TPD_G             : time                        := 1 ns;

      -- Test tx module instead of GTX
      TEST_G            : boolean                     := false;
      
      -- Internal SYSREF SELF_TEST_G= TRUE else 
      -- External SYSREF
      SELF_TEST_G        : boolean                    := false; 
      
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

      -- Data and character inputs from GT (transceivers)
      r_jesdGtRxArr  : in   jesdGtRxLaneTypeArray(L_G-1 downto 0);
      gt_reset_o     : out  slv(L_G-1 downto 0);    

      -- Synchronisation output combined from all receivers 
      nSync_o        : out   sl
   );
end Jesd204bRx;

architecture rtl of Jesd204bRx is
 
-- Register
   type RegType is record
      nSyncAnyD1 : sl;
   end record RegType;

   constant REG_INIT_C : RegType := (
      nSyncAnyD1  => '0'
   );

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

-- Internal signals

-- Local Multi Frame Clock 
signal s_lmfc   : sl;

-- Synchronisation output generation
signal s_nSyncVec       : slv(L_G-1 downto 0);
signal s_dataValidVec   : slv(L_G-1 downto 0);

signal s_nSyncAll   : sl;
signal s_nSyncAny   : sl;

-- Control and status from AxiLie
signal s_sysrefDlyRx  : slv(SYSRF_DLY_WIDTH_C-1 downto 0); 
signal s_enableRx     : slv(L_G-1 downto 0);
signal s_statusRxArr  : statuRegisterArray(L_G-1 downto 0);

-- Testing registers
signal s_dlyTxArr   : Slv4Array(L_G-1 downto 0);
signal s_alignTxArr : alignTxArray(L_G-1 downto 0);

-- Axi Lite interface synced to devClk
signal sAxiReadMasterDev : AxiLiteReadMasterType;
signal sAxiReadSlaveDev  : AxiLiteReadSlaveType;
signal sAxiWriteMasterDev: AxiLiteWriteMasterType;
signal sAxiWriteSlaveDev : AxiLiteWriteSlaveType;

-- Axi Stream
signal s_sampleDataArr : AxiTxDataTypeArray(L_G-1 downto 0);
signal s_axisPacketSizeReg : slv(23 downto 0);
signal s_axisTriggerReg    : slv(L_G-1 downto 0);

-- Sysref conditioning
signal  s_sysrefSync : sl;
signal  s_sysrefD    : sl;

-- Record containing GT signals
signal s_jesdGtRxArr : jesdGtRxLaneTypeArray(L_G-1 downto 0);


begin
   -- Check generics TODO add others
   assert (1 < L_G and L_G < 8)                      report "L_G must be between 1 and 8"   severity failure;

   -- AXI stream interface one module per lane
   generateAxiStreamLanes : for I in L_G-1 downto 0 generate
      AxiStreamLaneTx_INST: entity work.AxiStreamLaneTx
      generic map (
         TPD_G             => TPD_G,
         AXI_ERROR_RESP_G  => AXI_ERROR_RESP_G)
      port map (
         devClk_i       => devClk_i,
         devRst_i       => devRst_i,
         packetSize_i   => s_axisPacketSizeReg,
         trigger_i      => s_axisTriggerReg(I),
         txAxisMaster_o => txAxisMasterArr_o(I),
         txCtrl_i       => txCtrlArr_i(I),
         enable_i       => s_enableRx(I),
         sampleData_i   => s_sampleDataArr(I),
         dataReady_i    => s_dataValidVec(I)
      );
   end generate generateAxiStreamLanes;

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
   AxiLiteRegItf_INST: entity work.AxiLiteRegItf
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
      statusRxArr_i   => s_statusRxArr,
      sysrefDlyRx_o   => s_sysrefDlyRx,
      enableRx_o      => s_enableRx,
      dlyTxArr_o      => s_dlyTxArr,     
      alignTxArr_o    => s_alignTxArr,
      axisTrigger_o   => s_axisTriggerReg,
      axisPacketSize_o=> s_axisPacketSizeReg
   );
  
   -- LMFC period generator aligned to SYSREF input
   -------------------------------------------------------------------------
   LmfcGen_INST: entity work.LmfcGen
   generic map (
      TPD_G          => TPD_G,
      K_G            => K_G,
      F_G            => F_G)
   port map (
      clk      => devClk_i,
      rst      => devRst_i,
      nSync_i  => r.nSyncAnyD1,
      sysref_i => s_sysrefD,
      lmfc_o   => s_lmfc 
   );

   -- IF DEF TEST_G
   
   -- Generate TX test core if TEST_G=true is selected
   TEST_GEN: if TEST_G = true generate
   -----------------------------------------
      TX_LANES_GEN : for I in L_G-1 downto 0 generate    
         JesdTxTest_INST: entity work.JesdTxTest
            generic map (
               TPD_G          => TPD_G,
               SUB_CLASS_G    => SUB_CLASS_G)
            port map (
               devClk_i      => devClk_i,
               devRst_i      => devRst_i,
               enable_i      => s_enableRx(I),
               delay_i       => s_dlyTxArr(I),        
               align_i       => s_alignTxArr(I),
               lmfc_i        => s_lmfc,
               nSync_i       => r.nSyncAnyD1,
               r_jesdGtRx    => s_jesdGtRxArr(I),
               txDataValid_o => open);
      end generate TX_LANES_GEN;
      
      -- IF DEF SELF_TEST_G
      SELF_TEST_GEN: if SELF_TEST_G = true generate
         -- Generate the sysref internally
         -- Sysref period will be 8x K_G.
         SysrefGen_INST: entity work.LmfcGen
         generic map (
            TPD_G          => TPD_G,
            K_G            => 256,
            F_G            => 2)
         port map (
            clk      => devClk_i,
            rst      => devRst_i,
            nSync_i  => '0',
            sysref_i => '0',
            lmfc_o   => s_sysrefSync
         );
      end generate SELF_TEST_GEN;
      
      -- ELSE (not SELF_TEST_G)
      EXT_TEST_GEN: if SELF_TEST_G = false generate
         -- Sysref connected to the input (external sysref)
         -- Synchronise SYSREF input to devClk_i
         Synchronizer_INST: entity work.Synchronizer
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
      end generate EXT_TEST_GEN;
   ----------------------------------------       
   end generate TEST_GEN;
   
   -- ELSE   (not TEST_G)
   
   GT_OPER_GEN: if TEST_G = false generate
   -----------------------------------------
      -- Use input from GTX
      s_jesdGtRxArr <= r_jesdGtRxArr;
      
      -- Synchronise SYSREF input to devClk_i
      Synchronizer_INST: entity work.Synchronizer
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
   -----------------------------------------
   end generate GT_OPER_GEN;

   -- Delay SYSREF input (for 1 to 32 c-c)
   SysrefDly_INST: entity work.SysrefDly
   generic map (
      TPD_G       => TPD_G,
      DLY_WIDTH_G => SYSRF_DLY_WIDTH_C 
   )
   port map (
      clk      => devClk_i,
      rst      => devRst_i,
      dly_i    => s_sysrefDlyRx,
      sysref_i => s_sysrefSync,
      sysref_o => s_sysrefD
   );

   -- JESD Receiver modules (one module per Lane)
   generateRxLanes : for I in L_G-1 downto 0 generate    
      JesdRxLane_INST: entity work.JesdRxLane
      generic map (
         TPD_G          => TPD_G,
         F_G            => F_G,
         K_G            => K_G,
         SUB_CLASS_G    => SUB_CLASS_G)
      port map (
         devClk_i     => devClk_i,
         devRst_i     => devRst_i,
         sysRef_i     => s_sysrefD,
         enable_i     => s_enableRx(I),
         status_o     => s_statusRxArr(I),
         r_jesdGtRx   => s_jesdGtRxArr(I),
         lmfc_i       => s_lmfc,
         nSyncAnyD1_i => r.nSyncAnyD1,
         nSyncAny_i   => s_nSyncAny,
         nSync_o      => s_nSyncVec(I),
         dataValid_o  => s_dataValidVec(I),
         sampleData_o => s_sampleDataArr(I)
      );
   end generate;
   
   -- Combine nSync signals from all receivers
   s_nSyncAny <= uAnd(s_nSyncVec);
   
   -- DFF
   comb : process (r, devRst_i, s_nSyncAll, s_nSyncAny) is
      variable v : RegType;
   begin
      v.nSyncAnyD1 := s_nSyncAny;
      
      if (devRst_i = '1') then
         v := REG_INIT_C;
      end if;

      rin <= v;
   end process comb;

   seq : process (devClk_i) is
   begin
      if (rising_edge(devClk_i)) then
         r <= rin after TPD_G;
      end if;
   end process seq;

   -- Output assignment
   nSync_o     <= r.nSyncAnyD1;
   gt_reset_o  <= not s_enableRx;
   -----------------------------------------------------
end rtl;