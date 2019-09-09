-------------------------------------------------------------------------------
-- File       : PgpEthCoreTb.vhd
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: Simulation Testbed for testing the PgpEthCore
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;
use work.SsiPkg.all;
use work.PgpEthPkg.all;

entity PgpEthCoreTb is

end PgpEthCoreTb;

architecture testbed of PgpEthCoreTb is

   constant TPD_G : time := 1 ns;

   constant PRBS_SEED_SIZE_C : positive := 512;
   -- constant PRBS_SEED_SIZE_C : positive := 32;

   -- constant NUM_VC_C : positive := 1;
   constant NUM_VC_C : positive := 4;

   constant TX_MAX_PAYLOAD_SIZE_C : positive := 1024;

   constant CHOKE_AXIS_CONFIG_C : AxiStreamConfigType := ssiAxiStreamConfig(8);
   -- constant CHOKE_AXIS_CONFIG_C : AxiStreamConfigType := ssiAxiStreamConfig(64);

   constant PKT_LEN_C : slv(31 downto 0) := x"000000FF";

   signal txusrclk2 : sl := '0';

   signal clk : sl := '0';
   signal rst : sl := '1';

   signal phyTxMaster : AxiStreamMasterType;
   signal phyTxSlave  : AxiStreamSlaveType;

   signal txMaster : AxiStreamMasterType;
   signal txSlave  : AxiStreamSlaveType;

   signal phyMaster   : AxiStreamMasterType;
   signal rxMaster    : AxiStreamMasterType;
   signal phyRxMaster : AxiStreamMasterType;

   signal pgpTxMasters : AxiStreamMasterArray(NUM_VC_C-1 downto 0);
   signal pgpTxSlaves  : AxiStreamSlaveArray(NUM_VC_C-1 downto 0);

   signal pgpRxMasters : AxiStreamMasterArray(NUM_VC_C-1 downto 0);
   signal pgpRxCtrl    : AxiStreamCtrlArray(NUM_VC_C-1 downto 0);

   signal rxMasters : AxiStreamMasterArray(NUM_VC_C-1 downto 0);
   signal rxSlaves  : AxiStreamSlaveArray(NUM_VC_C-1 downto 0);

   signal updateDet : slv(NUM_VC_C-1 downto 0);
   signal errorDet  : slv(NUM_VC_C-1 downto 0);

   signal passed : sl := '0';
   signal failed : sl := '0';

begin

   U_Clk_0 : entity work.ClkRst
      generic map (
         CLK_PERIOD_G      => 5.111 ns,  -- 195.85 MHz (slow user clock to help with making timing)
         RST_START_DELAY_G => 0 ns,  -- Wait this long into simulation before asserting reset
         RST_HOLD_TIME_G   => 1 us)     -- Hold reset for this long)
      port map (
         clkP => clk,
         rst  => rst);

   U_Clk_1 : entity work.ClkRst
      generic map (
         CLK_PERIOD_G      => 3.103 ns,  -- 100GbE IP core's 322.58 MHz txusrclk2 clock 
         RST_START_DELAY_G => 0 ns,  -- Wait this long into simulation before asserting reset
         RST_HOLD_TIME_G   => 1 us)     -- Hold reset for this long)
      port map (
         clkP => txusrclk2);

   U_Core : entity work.PgpEthCore
      generic map (
         TPD_G                 => TPD_G,
         NUM_VC_G              => NUM_VC_C,
         TX_MAX_PAYLOAD_SIZE_G => TX_MAX_PAYLOAD_SIZE_C)
      port map (
         -- Clock and Reset
         pgpClk       => clk,
         pgpRst       => rst,
         -- Tx User interface
         pgpTxMasters => pgpTxMasters,
         pgpTxSlaves  => pgpTxSlaves,
         -- Rx User interface
         pgpRxMasters => pgpRxMasters,
         pgpRxCtrl    => pgpRxCtrl,
         -- Tx PHY Interface
         phyTxRdy     => '1',
         phyTxMaster  => phyTxMaster,
         phyTxSlave   => phyTxSlave,
         -- Rx PHY Interface
         phyRxRdy     => '1',
         phyRxMaster  => phyRxMaster);

   U_TX_FIFO : entity work.AxiStreamFifoV2
      generic map (
         -- General Configurations
         TPD_G               => TPD_G,
         SLAVE_READY_EN_G    => true,
         VALID_THOLD_G       => 0,  -- HOLD until full packet without gaps can be sent
         INT_PIPE_STAGES_G   => 0,
         PIPE_STAGES_G       => 0,
         -- FIFO configurations
         BRAM_EN_G           => true,
         GEN_SYNC_FIFO_G     => false,
         FIFO_ADDR_WIDTH_G   => log2(TX_MAX_PAYLOAD_SIZE_C/64)+1,
         -- AXI Stream Port Configurations
         SLAVE_AXI_CONFIG_G  => PGP_ETH_AXIS_CONFIG_C,
         MASTER_AXI_CONFIG_G => PGP_ETH_AXIS_CONFIG_C)
      port map (
         -- Slave Port
         sAxisClk    => clk,
         sAxisRst    => rst,
         sAxisMaster => phyTxMaster,
         sAxisSlave  => phyTxSlave,
         -- Master Port
         mAxisClk    => txusrclk2,
         mAxisRst    => rst,
         mAxisMaster => phyMaster,
         mAxisSlave  => AXI_STREAM_SLAVE_FORCE_C);

   U_RX_FIFO : entity work.AxiStreamFifoV2
      generic map (
         -- General Configurations
         TPD_G               => TPD_G,
         SLAVE_READY_EN_G    => false,
         INT_PIPE_STAGES_G   => 0,
         PIPE_STAGES_G       => 0,
         -- FIFO configurations
         BRAM_EN_G           => true,
         GEN_SYNC_FIFO_G     => false,
         FIFO_ADDR_WIDTH_G   => 9,
         -- AXI Stream Port Configurations
         SLAVE_AXI_CONFIG_G  => PGP_ETH_AXIS_CONFIG_C,
         MASTER_AXI_CONFIG_G => PGP_ETH_AXIS_CONFIG_C)
      port map (
         -- Slave Port
         sAxisClk    => txusrclk2,
         sAxisRst    => rst,
         sAxisMaster => phyMaster,
         -- Master Port
         mAxisClk    => clk,
         mAxisRst    => rst,
         mAxisMaster => rxMaster,
         mAxisSlave  => AXI_STREAM_SLAVE_FORCE_C);

   PHY_AXIS : process (rxMaster) is
      variable master : AxiStreamMasterType;
   begin
      -- Init
      master := rxMaster;

      -- Remove meta data from PHY layer
      master.tDest := x"00";
      master.tUser := (others => '0');

      -- Outputs
      phyRxMaster <= master;
   end process;

   GEN_VEC :
   for i in 0 to NUM_VC_C-1 generate

      U_SsiPrbsTx : entity work.SsiPrbsTx
         generic map (
            TPD_G                      => TPD_G,
            VALID_THOLD_G              => (TX_MAX_PAYLOAD_SIZE_C/64),
            VALID_BURST_MODE_G         => true,
            AXI_EN_G                   => '0',
            GEN_SYNC_FIFO_G            => true,
            PRBS_SEED_SIZE_G           => PRBS_SEED_SIZE_C,
            MASTER_AXI_STREAM_CONFIG_G => PGP_ETH_AXIS_CONFIG_C)
         port map (
            mAxisClk     => clk,
            mAxisRst     => rst,
            mAxisMaster  => pgpTxMasters(i),
            mAxisSlave   => pgpTxSlaves(i),
            locClk       => clk,
            locRst       => rst,
            trig         => '1',
            packetLength => PKT_LEN_C);

      U_BottleNeck : entity work.AxiStreamFifoV2
         generic map (
            TPD_G               => TPD_G,
            SLAVE_READY_EN_G    => false,                -- Using pause
            GEN_SYNC_FIFO_G     => true,
            BRAM_EN_G           => true,
            FIFO_FIXED_THRESH_G => true,
            FIFO_ADDR_WIDTH_G   => 9,
            FIFO_PAUSE_THRESH_G => 2**7,
            SLAVE_AXI_CONFIG_G  => PGP_ETH_AXIS_CONFIG_C,
            MASTER_AXI_CONFIG_G => CHOKE_AXIS_CONFIG_C)  -- Bottleneck the bandwidth
         port map (
            -- Slave Interface
            sAxisClk    => clk,
            sAxisRst    => rst,
            sAxisMaster => pgpRxMasters(i),
            sAxisCtrl   => pgpRxCtrl(i),
            -- Master Interface
            mAxisClk    => clk,
            mAxisRst    => rst,
            mAxisMaster => rxMasters(i),
            mAxisSlave  => rxSlaves(i));

      U_SsiPrbsRx : entity work.SsiPrbsRx
         generic map (
            TPD_G                     => TPD_G,
            GEN_SYNC_FIFO_G           => true,
            SLAVE_READY_EN_G          => true,
            PRBS_SEED_SIZE_G          => PRBS_SEED_SIZE_C,
            SLAVE_AXI_STREAM_CONFIG_G => CHOKE_AXIS_CONFIG_C)  -- Matches U_BottleNeck outbound data stream
         port map (
            sAxisClk       => clk,
            sAxisRst       => rst,
            sAxisMaster    => rxMasters(i),
            sAxisSlave     => rxSlaves(i),
            updatedResults => updateDet(i),
            errorDet       => errorDet(i),
            axiClk         => clk,
            axiRst         => rst);

   end generate GEN_VEC;

   process(clk)
   begin
      if rising_edge(clk) then
         failed <= uOr(errorDet) after TPD_G;
      end if;
   end process;

   process(failed, passed)
   begin
      if passed = '1' then
         assert false
            report "Simulation Passed!" severity failure;
      elsif failed = '1' then
         assert false
            report "Simulation Failed!" severity failure;
      end if;
   end process;

end testbed;
