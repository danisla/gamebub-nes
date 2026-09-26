// Game Bub wrapper for the NES_MiSTer core.
//
// Replaces the MiSTer-specific top level (NES.sv) with a small interface that
// the Chisel HandheldNes core drives:
//
//   * ROM loading: 32-bit words of an iNES file are fed (a byte at a time)
//     to the MiSTer GameLoader, which parses the header and places PRG/CHR.
//     Its writes are paired into 16-bit SDRAM writes, to keep up with the
//     host's transfer speed.
//   * Save RAM: a staging buffer the host can access at full speed (32-bit
//     words), copied to/from the battery-backed cartridge RAM (SDRAM channel
//     2) or the mapper EEPROM on command, for loading/saving .sav files.
//   * Video: one strobe per visible pixel (256x240), with the raw 6-bit
//     palette index and 3 emphasis bits. Palette lookup happens later, in
//     the Game Bub video filter.
//   * Audio: signed 16-bit mono.
//
// Clocks: `clock` is the NES master clock (~21.477 MHz) and `clockSdram` is
// exactly 4x that and phase aligned, same as MiSTer. `clockSdramOut` is the
// same frequency as clockSdram, phase shifted, and is forwarded to the SDRAM.
//
// This file is derived from NES_MiSTer NES.sv, and like it is licensed under
// the GNU General Public License v3 (see LICENSE).

module NesGamebub (
    input  logic        clock,
    input  logic        reset,
    input  logic        clockSdram,
    input  logic        clockSdramOut,

    // Core control
    /// Hold the NES in reset.
    input  logic        coreReset,
    /// Pause the NES (at the next vblank).
    input  logic        corePause,

    // ROM loading
    /// High while a ROM file is being streamed in.
    input  logic        loadActive,
    /// A word (4 bytes, little endian) is available on loadData.
    input  logic        loadValid,
    input  logic [31:0] loadData,
    /// The word on loadData is consumed when loadValid && loadReady.
    output logic        loadReady,
    /// High until all loaded data has been written to the SDRAM.
    output logic        loadBusy,
    /// High once a ROM has been successfully loaded.
    output logic        romLoaded,
    /// High if the last ROM load failed (bad header).
    output logic        loadError,

    // Save RAM staging buffer access (32-bit words, byte addressed)
    input  logic        saveEnable,
    input  logic        saveWrite,
    input  logic [17:0] saveAddress,
    input  logic [31:0] saveDataWrite,
    output logic [31:0] saveDataRead,
    output logic        saveDone,
    /// Size of the save file in bytes (0 if the game has no save).
    output logic [17:0] saveSize,
    /// Copy the cartridge RAM into the staging buffer.
    input  logic        saveLoad,
    /// Copy the staging buffer into the cartridge RAM.
    input  logic        saveStore,
    /// High while copying.
    output logic        saveBusy,

    // Input: {right, left, down, up, start, select, b, a}, active high.
    input  logic [7:0]  buttons,

    // Video
    output logic        pixelValid,
    output logic [5:0]  pixelColor,
    output logic [2:0]  pixelEmphasis,
    output logic        hblank,
    output logic        vblank,

    // Audio
    output logic [15:0] audio,

    // SDRAM pins
    output logic        sdramClock,
    output logic        sdramCke,
    output logic        sdramCs,
    output logic        sdramRas,
    output logic        sdramCas,
    output logic        sdramWe,
    output logic [1:0]  sdramDqm,
    output logic [1:0]  sdramBank,
    output logic [12:0] sdramAddress,
    input  logic [15:0] sdramDataIn,
    output logic [15:0] sdramDataOut,
    output logic        sdramDataDir
);

    //////////////////////////////////////////////////////////////////////
    // ROM loader
    //////////////////////////////////////////////////////////////////////
    wire [24:0] loader_addr;
    wire [7:0]  loader_write_data;
    wire        loader_write;
    wire [63:0] loader_flags;
    wire [9:0]  prg_mask, chr_mask;
    wire        loader_busy, loader_done, loader_fail;
    reg  [63:0] mapper_flags = '0;

    // The file is still being downloaded until all accepted words are fed.
    wire downloading;

    // Start the loader fresh at the start of each download.
    reg load_active_d = 0;
    always @(posedge clock) load_active_d <= loadActive;
    wire loader_reset = reset || (loadActive && !load_active_d);

    // SDRAM write request (to channel 0, while loading). Either a byte, or a
    // 16-bit word at an even address.
    reg        wreq_valid = 0;
    reg        wreq_word;
    reg [24:0] wreq_addr;
    reg [15:0] wreq_data;
    reg        wreq_wr = 0;
    reg        wreq_started = 0;
    wire       wreq_busy;

    // A loader byte written to an even address, waiting for the next byte to
    // make a 16-bit write.
    reg        pair_valid = 0;
    reg [24:0] pair_addr;
    reg  [7:0] pair_data;

    // Incoming word buffer, so that the next word can be accepted while the
    // current one is being fed to the loader.
    reg [31:0] next_word;
    reg        next_valid = 0;
    assign loadReady = loadActive && !next_valid;
    wire load_word = loadValid && loadReady;
    assign downloading = loadActive || next_valid || (feed_count != 0);

    // Current word, fed to the loader one byte every other cycle (so the
    // loader has a cycle for state transitions between bytes).
    reg [31:0] feed_word;
    reg  [2:0] feed_count = 0;  // Bytes left in feed_word
    reg        feed_phase = 0;

    // A byte can be fed when its loader write can be handled this cycle: it
    // either starts a pair (even address), or completes the pending pair /
    // is written alone, which needs a free write request slot.
    wire pair_breaks = pair_valid && (loader_addr != pair_addr + 1'd1);
    wire starts_pair = !pair_valid && !loader_addr[0];
    wire feed_ok = !pair_breaks && (!wreq_valid || starts_pair);
    wire feed_byte = (feed_count != 0) && !feed_phase && feed_ok;

    always @(posedge clock) begin
        if (load_word) begin
            next_word <= loadData;
            next_valid <= 1;
        end

        if (feed_byte) begin
            feed_word <= feed_word >> 8;
            feed_count <= feed_count - 1'd1;
            feed_phase <= 1;
        end else begin
            feed_phase <= 0;
            if (feed_count == 0 && next_valid) begin
                feed_word <= next_word;
                feed_count <= 3'd4;
                next_valid <= 0;
            end
        end

        if (pair_breaks && !wreq_valid) begin
            // Flush the pending byte on its own.
            wreq_valid <= 1;
            wreq_word <= 0;
            wreq_addr <= pair_addr;
            wreq_data <= {pair_data, pair_data};
            pair_valid <= 0;
        end else if (loader_write) begin
            if (pair_valid) begin
                wreq_valid <= 1;
                wreq_word <= 1;
                wreq_addr <= pair_addr;
                wreq_data <= {loader_write_data, pair_data};
                pair_valid <= 0;
            end else if (!loader_addr[0]) begin
                pair_valid <= 1;
                pair_addr <= loader_addr;
                pair_data <= loader_write_data;
            end else begin
                wreq_valid <= 1;
                wreq_word <= 0;
                wreq_addr <= loader_addr;
                wreq_data <= {loader_write_data, loader_write_data};
            end
        end else if (pair_valid && !downloading && !wreq_valid) begin
            // End of the file: flush the last byte.
            wreq_valid <= 1;
            wreq_word <= 0;
            wreq_addr <= pair_addr;
            wreq_data <= {pair_data, pair_data};
            pair_valid <= 0;
        end

        // Channel 0 requests are edge triggered in the SDRAM clock domain.
        // Hold the request until the controller picks it up (busy), then wait
        // for it to finish. Busy is held for more than one NES clock.
        if (wreq_valid) begin
            if (!wreq_started && !wreq_wr) begin
                wreq_wr <= 1;
            end else if (wreq_wr && wreq_busy) begin
                wreq_wr <= 0;
                wreq_started <= 1;
            end else if (wreq_started && !wreq_busy) begin
                wreq_started <= 0;
                wreq_valid <= 0;
            end
        end

        if (loader_reset) begin
            feed_count <= 0;
            next_valid <= 0;
            pair_valid <= 0;
        end
        if (reset) begin
            wreq_valid <= 0;
            wreq_wr <= 0;
            wreq_started <= 0;
        end
    end

    GameLoader loader (
        .clk          (clock),
        .clearval     (1'b0),
        .cleardata    (8'h00),
        .reset        (loader_reset),
        .downloading  (downloading),
        .filetype     (8'b0000_0010), // .nes only
        .is_bios      (1'b0),
        .indata       (feed_word[7:0]),
        .indata_clk   (feed_byte),
        .mem_addr     (loader_addr),
        .mem_data     (loader_write_data),
        .mem_write    (loader_write),
        .mapper_flags (loader_flags),
        .prg_mask     (prg_mask),
        .chr_mask     (chr_mask),
        .busy         (loader_busy),
        .done         (loader_done),
        .error        (loader_fail),
        .rom_loaded   ()
    );

    reg rom_ok = 0;
    always @(posedge clock) begin
        if (loader_reset) begin
            rom_ok <= 0;
        end else if (loader_done && !loading) begin
            mapper_flags <= loader_flags;
            rom_ok <= !loader_fail;
        end
    end
    assign romLoaded = rom_ok;
    assign loadError = loader_fail;

    //////////////////////////////////////////////////////////////////////
    // Reset
    //////////////////////////////////////////////////////////////////////
    // Loading continues until every write has been issued to the SDRAM.
    wire loading = loadActive || loader_busy || next_valid || (feed_count != 0) || pair_valid || wreq_valid;
    assign loadBusy = loading;

    // Keep the NES in reset for a while after a download finishes.
    reg [7:0] download_reset_cnt = 0;
    always @(posedge clock) begin
        if (loading) download_reset_cnt <= 8'hFF;
        else if (download_reset_cnt != 0) download_reset_cnt <= download_reset_cnt - 1'd1;
    end

    wire core_paused;
    wire reset_nes = reset || coreReset || loading || !rom_ok || (download_reset_cnt != 0);

    //////////////////////////////////////////////////////////////////////
    // Controller
    //////////////////////////////////////////////////////////////////////
    wire [2:0] joypad_out;
    wire [1:0] joypad_clock;
    reg [23:0] joypad_bits;
    reg  [1:0] last_joypad_clock;

    always @(posedge clock) begin
        if (reset_nes) begin
            joypad_bits <= 0;
            last_joypad_clock <= 0;
        end else begin
            if (joypad_out[0]) begin
                // After the 8 buttons, an official controller returns 1s.
                joypad_bits <= {16'hFFFF, buttons};
            end
            if (!joypad_clock[0] && last_joypad_clock[0]) begin
                joypad_bits <= {1'b0, joypad_bits[23:1]};
            end
            last_joypad_clock <= joypad_clock;
        end
    end

    //////////////////////////////////////////////////////////////////////
    // NES
    //////////////////////////////////////////////////////////////////////
    wire [24:0] cpu_addr;
    wire [21:0] ppu_addr;
    wire        cpu_read, cpu_write, ppu_read, ppu_write;
    wire  [7:0] cpu_dout, cpu_din, ppu_dout, ppu_din;
    wire        nes_refresh;

    wire [17:0] bram_addr;
    wire  [7:0] bram_din;
    wire  [7:0] bram_dout;
    wire        bram_write;
    wire        bram_en;

    wire  [8:0] cycle;
    wire  [8:0] scanline;
    wire [15:0] sample;
    wire  [5:0] color;
    wire  [2:0] emphasis;

    wire  [7:0] save_dout;

    NES nes (
        .clk             (clock),
        .reset_nes       (reset_nes),
        .ppu_rst_behavior(1'b0),
        .cold_reset      (loading),
        .pausecore       (corePause),
        .corepaused      (core_paused),
        .debug_dots      (1'b0),
        .sys_type        (2'b00), // NTSC
        .vs_dip_switches (8'h00),
        .nes_div         (nes_ce),
        .mapper_flags    (loadActive ? 64'd0 : mapper_flags),
        .gg              (1'b0),
        .gg_code         (129'd0),
        .gg_reset        (1'b0),
        .gg_avail        (),
        // Audio
        .sample          (sample),
        .audio_channels  (5'b11111),
        .int_audio       (1'b1),
        .ext_audio       (1'b1),
        .apu_ce          (),
        // Video
        .ex_sprites      (1'b0),
        .color           (color),
        .hsync           (),
        .hblank          (),
        .vsync           (),
        .vblank          (),
        .composite_a     (),
        .composite_b     (),
        .emphasis        (emphasis),
        .cycle           (cycle),
        .scanline        (scanline),
        .mask            (2'b00),
        .dejitter_timing (1'b0),
        // User Input
        .joypad_out      (joypad_out),
        .joypad_clock    (joypad_clock),
        .joypad1_data    ({4'b0000, joypad_bits[0]}),
        .joypad2_data    (5'b00000),
        // FDS (unsupported)
        .diskside        (),
        .fds_busy        (1'b0),
        .fds_eject       (1'b0),
        .fds_auto_eject  (1'b0),
        .max_diskside    (2'd0),
        .fds_fast        (1'b0),
        // Memory transactions
        .cpumem_addr     (cpu_addr),
        .cpumem_read     (cpu_read),
        .cpumem_write    (cpu_write),
        .cpumem_dout     (cpu_dout),
        .cpumem_din      (cpu_din),
        .ppumem_addr     (ppu_addr),
        .ppumem_read     (ppu_read),
        .ppumem_write    (ppu_write),
        .ppumem_dout     (ppu_dout),
        .ppumem_din      (ppu_din),
        .refresh         (nes_refresh),
        .prg_mask        (prg_mask),
        .chr_mask        (chr_mask),
        .bram_addr       (bram_addr),
        .bram_din        (bram_din),
        .bram_dout       (bram_dout),
        .bram_write      (bram_write),
        .bram_override   (bram_en),
        .save_written    (),
        .mapper_has_flashsaves (),
        // Savestates (unsupported)
        .mapper_has_savestate    (),
        .increaseSSHeaderCount   (1'b0),
        .save_state              (1'b0),
        .load_state              (1'b0),
        .savestate_number        (2'd0),
        .sleep_savestate         (),
        .state_loaded            (),
        .Savestate_SDRAMAddr     (),
        .Savestate_SDRAMRdEn     (),
        .Savestate_SDRAMWrEn     (),
        .Savestate_SDRAMWriteData(),
        .Savestate_SDRAMReadData (save_dout),
        .SaveStateExt_Din        (),
        .SaveStateExt_Adr        (),
        .SaveStateExt_wren       (),
        .SaveStateExt_rst        (),
        .SaveStateExt_Dout       (64'd0),
        .SaveStateExt_load       (),
        .SAVE_out_Din            (),
        .SAVE_out_Dout           (64'd0),
        .SAVE_out_Adr            (),
        .SAVE_out_rnw            (),
        .SAVE_out_ena            (),
        .SAVE_out_be             (),
        .SAVE_out_done           (1'b0)
    );

    //////////////////////////////////////////////////////////////////////
    // Save RAM access
    //////////////////////////////////////////////////////////////////////
    // Battery-backed cartridge RAM lives in SDRAM at 0x3C0000 (CARTRAM),
    // unless the mapper uses an EEPROM, which is held in block RAM.
    wire [3:0] prg_nvram = mapper_flags[34:31];
    wire       has_battery = mapper_flags[25];
    always_comb begin
        if (!rom_ok) saveSize = 0;
        else if (bram_en) saveSize = 18'd2048;
        else if (!has_battery) saveSize = 0;
        else if (prg_nvram == 4'd7) saveSize = 18'd8192;
        else saveSize = 18'd32768;
    end

    // The host accesses the save through a staging buffer in block RAM, at
    // full SPI speed. The buffer is copied from the cartridge RAM on
    // saveLoad, and back to it on saveStore (saveBusy is high meanwhile).
    typedef enum logic [2:0] {
        COPY_IDLE, COPY_NEXT, COPY_LOAD_EEPROM, COPY_STORE_DATA, COPY_WAIT_BUSY, COPY_WAIT_DONE
    } copy_state_t;
    copy_state_t copy_state = COPY_IDLE;
    reg        copy_store;
    reg [15:0] copy_addr;
    reg        save_rd = 0, save_wr = 0;
    reg  [7:0] save_din;
    wire       save_busy;
    wire [31:0] buf_q_word;
    wire  [7:0] buf_q = buf_q_word[copy_addr[1:0] * 8 +: 8];
    wire  [7:0] eeprom_q;

    assign saveBusy = (copy_state != COPY_IDLE);

    // Host port: one cycle read latency.
    always @(posedge clock) saveDone <= saveEnable;

    wire copy_buf_write = (copy_state == COPY_LOAD_EEPROM) ||
        (copy_state == COPY_WAIT_DONE && !save_busy && !copy_store);
    wire [7:0] copy_buf_data = (copy_state == COPY_LOAD_EEPROM) ? eeprom_q : save_dout;
    // Four byte lanes, 8K x 8 each: the host accesses whole words, the copy
    // engine single bytes.
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane++) begin : save_buffer
            dpram #(.widthad_a(13)) ram (
                .clock_a   (clock),
                .address_a (saveAddress[14:2]),
                .data_a    (saveDataWrite[lane * 8 +: 8]),
                .wren_a    (saveEnable && saveWrite),
                .byteena_a (1'b1),
                .q_a       (saveDataRead[lane * 8 +: 8]),

                .clock_b   (clock),
                .address_b (copy_addr[14:2]),
                .data_b    (copy_buf_data),
                .wren_b    (copy_buf_write && copy_addr[1:0] == lane),
                .byteena_b (1'b1),
                .q_b       (buf_q_word[lane * 8 +: 8])
            );
        end
    endgenerate

    dpram #(.widthad_a(11)) eeprom (
        .clock_a   (clockSdram),
        .address_a (bram_addr[10:0]),
        .data_a    (bram_dout),
        .wren_a    (bram_write),
        .byteena_a (1'b1),
        .q_a       (bram_din),

        .clock_b   (clock),
        .address_b (copy_addr[10:0]),
        .data_b    (buf_q),
        .wren_b    (copy_state == COPY_STORE_DATA && bram_en),
        .byteena_b (1'b1),
        .q_b       (eeprom_q)
    );

    // Channel 2 requests are edge triggered in the SDRAM clock domain. Hold
    // the request until the controller picks it up (busy), then wait for it to
    // finish. Busy is held for more than one NES clock, so it can't be missed.
    always @(posedge clock) begin
        case (copy_state)
            COPY_IDLE: if (saveLoad || saveStore) begin
                copy_store <= saveStore;
                copy_addr <= 0;
                copy_state <= COPY_NEXT;
            end
            // The buffer and EEPROM are read at copy_addr here, valid next cycle.
            COPY_NEXT: begin
                if (copy_addr >= saveSize[15:0]) begin
                    copy_state <= COPY_IDLE;
                end else if (copy_store) begin
                    copy_state <= COPY_STORE_DATA;
                end else if (bram_en) begin
                    copy_state <= COPY_LOAD_EEPROM;
                end else begin
                    save_rd <= 1;
                    copy_state <= COPY_WAIT_BUSY;
                end
            end
            COPY_LOAD_EEPROM: begin
                // Buffer written with eeprom_q this cycle.
                copy_addr <= copy_addr + 1'd1;
                copy_state <= COPY_NEXT;
            end
            COPY_STORE_DATA: begin
                if (bram_en) begin
                    // EEPROM written with buf_q this cycle.
                    copy_addr <= copy_addr + 1'd1;
                    copy_state <= COPY_NEXT;
                end else begin
                    save_din <= buf_q;
                    save_wr <= 1;
                    copy_state <= COPY_WAIT_BUSY;
                end
            end
            COPY_WAIT_BUSY: if (save_busy) begin
                save_rd <= 0;
                save_wr <= 0;
                copy_state <= COPY_WAIT_DONE;
            end
            COPY_WAIT_DONE: if (!save_busy) begin
                // For loads, the buffer is written with save_dout this cycle.
                copy_addr <= copy_addr + 1'd1;
                copy_state <= COPY_NEXT;
            end
            default: copy_state <= COPY_IDLE;
        endcase
        if (reset) begin
            save_rd <= 0;
            save_wr <= 0;
            copy_state <= COPY_IDLE;
        end
    end

    //////////////////////////////////////////////////////////////////////
    // SDRAM
    //////////////////////////////////////////////////////////////////////
    wire sdram_nCS, sdram_nRAS, sdram_nCAS, sdram_nWE, sdram_DQML, sdram_DQMH;

    nes_sdram sdram_ctrl (
        .SDRAM_DQ_IN  (sdramDataIn),
        .SDRAM_DQ_OUT (sdramDataOut),
        .SDRAM_DQ_OE  (sdramDataDir),
        .SDRAM_A      (sdramAddress),
        .SDRAM_DQML   (sdram_DQML),
        .SDRAM_DQMH   (sdram_DQMH),
        .SDRAM_BA     (sdramBank),
        .SDRAM_nCS    (sdram_nCS),
        .SDRAM_nWE    (sdram_nWE),
        .SDRAM_nRAS   (sdram_nRAS),
        .SDRAM_nCAS   (sdram_nCAS),
        .SDRAM_CLK    (sdramClock),
        .SDRAM_CKE    (sdramCke),

        .init         (reset),
        .clk          (clockSdram),
        .clk_out      (clockSdramOut),

        .ch0_addr     (loading ? wreq_addr : {3'b0, ppu_addr}),
        .ch0_wr       (loading ? wreq_wr : ppu_write),
        .ch0_word     (loading && wreq_word),
        .ch0_din      (loading ? wreq_data[7:0] : ppu_dout),
        .ch0_din16    (wreq_data),
        .ch0_rd       (~loading & ppu_read),
        .ch0_dout     (ppu_din),
        .ch0_busy     (wreq_busy),

        .ch1_addr     (cpu_addr),
        .ch1_wr       (cpu_write),
        .ch1_din      (cpu_dout),
        .ch1_rd       (cpu_read),
        .ch1_dout     (cpu_din),
        .ch1_busy     (),

        .ch2_addr     ({7'b0001111, 3'b000, copy_addr[14:0]}),
        .ch2_wr       (save_wr),
        .ch2_din      (save_din),
        .ch2_rd       (save_rd),
        .ch2_dout     (save_dout),
        .ch2_busy     (save_busy),

        // The NES only refreshes while paused, relying on repeated reads
        // otherwise. Also refresh while it's held in reset.
        .refresh      (nes_refresh | reset_nes)
    );
    assign sdramCs  = sdram_nCS;
    assign sdramRas = sdram_nRAS;
    assign sdramCas = sdram_nCAS;
    assign sdramWe  = sdram_nWE;
    assign sdramDqm = {sdram_DQMH, sdram_DQML};

    //////////////////////////////////////////////////////////////////////
    // Video
    //////////////////////////////////////////////////////////////////////
    // Output one pixel per PPU dot, for dots 2..257 of lines 0..239 (the
    // same alignment of color to dot counter as MiSTer's video.sv). The
    // sample is taken two cycles after the dot counter changes, once both
    // the counter and the color have settled; de-jitter "fake" dots don't
    // advance the counter, so they're skipped.
    reg [8:0] cycle_d1, cycle_d2;
    always @(posedge clock) begin
        cycle_d1 <= cycle;
        cycle_d2 <= cycle_d1;
    end
    wire dot_tick = (cycle_d1 != cycle_d2);
    wire visible_line = (scanline < 9'd240);
    wire visible_dot = (cycle_d1 >= 9'd2) && (cycle_d1 <= 9'd257);

    always @(posedge clock) begin
        // While paused, the NES keeps generating video timing: skip it, so
        // that the last frame stays on screen.
        pixelValid <= dot_tick && visible_line && visible_dot && !reset_nes && !core_paused;
        pixelColor <= color;
        pixelEmphasis <= emphasis;
        hblank <= !visible_dot;
        vblank <= !visible_line || reset_nes || core_paused;
    end

    //////////////////////////////////////////////////////////////////////
    // Audio
    //////////////////////////////////////////////////////////////////////
    // Unsigned sample to signed, at half volume to leave some headroom.
    always @(posedge clock) begin
        audio <= $signed({~sample[15], sample[14:0]}) >>> 1;
    end

endmodule
