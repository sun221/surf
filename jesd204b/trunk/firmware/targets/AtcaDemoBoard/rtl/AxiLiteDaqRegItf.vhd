-------------------------------------------------------------------------------
-- Title      : Axi-lite interface for DAQ register access  
-------------------------------------------------------------------------------
-- File       : AxiLiteDaqRegItf.vhd
-- Author     : Uros Legat  <ulegat@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory (Cosylab)
-- Created    : 2015-04-15
-- Last update: 2015-04-15
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:  Register decoding for DAQ
-------------------------------------------------------------------------------
-- Copyright (c) 2013 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiLitePkg.all;
use work.Jesd204bPkg.all;

entity AxiLiteDaqRegItf is
   generic (
   -- General Configurations
      TPD_G                      : time                       := 1 ns;

      AXI_ERROR_RESP_G           : slv(1 downto 0)            := AXI_RESP_SLVERR_C;  

      -- Number of Axi lanes (0 to 1)
      L_AXI_G : positive := 2 
   );    
   port (
     -- AXI Clk
     axiClk_i : in sl;
     axiRst_i : in sl;

    -- Axi-Lite Register Interface (locClk domain)
      axilReadMaster  : in  AxiLiteReadMasterType  := AXI_LITE_READ_MASTER_INIT_C;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType := AXI_LITE_WRITE_MASTER_INIT_C;
      axilWriteSlave  : out AxiLiteWriteSlaveType;
      
    -- JESD devClk
      devClk_i          : in  sl;
      devRst_i          : in  sl;    
      
   -- JESD registers
      -- Busy
      busy_i          : in  sl;            
   
      -- Control
      trigSw_o          : out  sl;
      axisPacketSize_o  : out  slv(23 downto 0);
      rateDiv_o         : out  slv(15 downto 0);
      muxSel_o          : out  Slv4Array(L_AXI_G-1 downto 0)
   );   
end AxiLiteDaqRegItf;

architecture rtl of AxiLiteDaqRegItf is

   type RegType is record
      -- JESD Control (RW)
      commonCtrl     : slv(0 downto 0);
      axisPacketSize : slv(23 downto 0);
      rateDiv        : slv(15 downto 0);
      muxSel         : Slv4Array(L_AXI_G-1 downto 0);
      
      -- AXI lite
      axilReadSlave  : AxiLiteReadSlaveType;
      axilWriteSlave : AxiLiteWriteSlaveType;
   end record;
   
   constant REG_INIT_C : RegType := (
      commonCtrl       => "0",
      axisPacketSize   => x"00_01_00",
      rateDiv          => x"0000",
      muxSel           => (x"2", x"1"),
 
      axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C,
      axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C);

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;
   
   -- Integer address
   signal s_RdAddr: natural := 0;
   signal s_WrAddr: natural := 0;
   
   signal s_busy : sl; 
   
begin
   
   -- Convert address to integer (lower two bits of address are always '0')
   s_RdAddr <= slvToInt( axilReadMaster.araddr(9 downto 2) );
   s_WrAddr <= slvToInt( axilWriteMaster.awaddr(9 downto 2) ); 
   
   comb : process (axilReadMaster, axilWriteMaster, r, axiRst_i, s_RdAddr, s_WrAddr, s_busy) is
      variable v             : RegType;
      variable axilStatus    : AxiLiteStatusType;
      variable axilWriteResp : slv(1 downto 0);
      variable axilReadResp  : slv(1 downto 0);
   begin
      -- Latch the current value
      v := r;
      
      -- Auto clear (trigger register) TODO check in simulation
      v.commonCtrl := "0";
      ----------------------------------------------------------------------------------------------
      -- Axi-Lite interface
      ----------------------------------------------------------------------------------------------
      axiSlaveWaitTxn(axilWriteMaster, axilReadMaster, v.axilWriteSlave, v.axilReadSlave, axilStatus);

      if (axilStatus.writeEnable = '1') then
         axilWriteResp := ite(axilWriteMaster.awaddr(1 downto 0) = "00", AXI_RESP_OK_C, AXI_ERROR_RESP_G);
         case (s_WrAddr) is
            when 16#00# => -- ADDR (0)
               v.commonCtrl      := axilWriteMaster.wdata(0 downto 0); 
            when 16#02# => -- ADDR (8)
               v.rateDiv  := axilWriteMaster.wdata(15 downto 0);                
            when 16#03# => -- ADDR (12)
               v.axisPacketSize  := axilWriteMaster.wdata(23 downto 0);
            when 16#10# to 16#1F# =>               
               for I in (L_AXI_G-1) downto 0 loop
                  if (axilWriteMaster.awaddr(5 downto 2) = I) then
                     v.muxSel(I)  := axilWriteMaster.wdata(3 downto 0);
                  end if;
               end loop;
            when others =>
               axilWriteResp     := AXI_ERROR_RESP_G;
         end case;
         axiSlaveWriteResponse(v.axilWriteSlave);
      end if;

      if (axilStatus.readEnable = '1') then
         axilReadResp          := ite(axilReadMaster.araddr(1 downto 0) = "00", AXI_RESP_OK_C, AXI_ERROR_RESP_G);
         v.axilReadSlave.rdata := (others => '0');
         case (s_RdAddr) is
            when 16#00# =>  -- ADDR (0)
               v.axilReadSlave.rdata(0 downto 0)                 := r.commonCtrl;
            when 16#01# =>  -- ADDR (4)
               v.axilReadSlave.rdata(0)                          := s_busy;
            when 16#02# =>  -- ADDR (8)
               v.axilReadSlave.rdata(15 downto 0)                := r.rateDiv;               
            when 16#03# =>  -- ADDR (12)
               v.axilReadSlave.rdata(23 downto 0)                := r.axisPacketSize;
            when 16#10# to 16#1F# => 
               for I in (L_AXI_G-1) downto 0 loop
                  if (axilReadMaster.araddr(5 downto 2) = I) then
                     v.axilReadSlave.rdata(3 downto 0)     := r.muxSel(I);
                  end if;
               end loop;
            when others =>
               axilReadResp    := AXI_ERROR_RESP_G;
         end case;
         axiSlaveReadResponse(v.axilReadSlave);
      end if;

      -- Reset
      if (axiRst_i = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

      -- Outputs
      axilReadSlave  <= r.axilReadSlave;
      axilWriteSlave <= r.axilWriteSlave;
      
   end process comb;

   seq : process (axiClk_i) is
   begin
      if rising_edge(axiClk_i) then
         r <= rin after TPD_G;
      end if;
   end process seq;
   
   -- Input assignment and synchronisation
   Sync_IN0 : entity work.Synchronizer
   generic map (
      TPD_G => TPD_G
   )
   port map (
      clk     => axiClk_i,
      rst     => axiRst_i,
      dataIn  => busy_i,
      dataOut => s_busy
   );
   
   -- Output assignment and synchronisation
   Sync_OUT1 : entity work.Synchronizer
   generic map (
      TPD_G => TPD_G
   )
   port map (
      clk     => devClk_i,
      rst     => devRst_i,
      dataIn  => r.commonCtrl(0),
      dataOut => trigSw_o
   );
   
   SyncFifo_OUT2 : entity work.SynchronizerFifo
   generic map (
      TPD_G        => TPD_G,
      DATA_WIDTH_G => 24
   )
   port map (
      wr_clk => axiClk_i,
      din    => r.axisPacketSize,
      rd_clk => devClk_i,
      dout   => axisPacketSize_o
   );
   
   SyncFifo_OUT3 : entity work.SynchronizerFifo
   generic map (
      TPD_G        => TPD_G,
      DATA_WIDTH_G => 16
   )
   port map (
      wr_clk => axiClk_i,
      din    => r.rateDiv,
      rd_clk => devClk_i,
      dout   => rateDiv_o
   );
   
   GEN_1 : for I in L_AXI_G-1 downto 0 generate
       SyncFifo_OUT0 : entity work.SynchronizerFifo
      generic map (
        TPD_G        => TPD_G,
        DATA_WIDTH_G => 4
        )
      port map (
        wr_clk => axiClk_i,
        din    => r.muxSel(I),
        rd_clk => devClk_i,
        dout   => muxSel_o(I) 
        );
   end generate GEN_1;   
---------------------------------------------------------------------
end rtl;