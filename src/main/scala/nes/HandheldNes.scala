package nes

import chisel3._
import chisel3.util._
import lib.mem.{MemoryInterface, MemoryMap, RegisterMap}
import lib.video.ColorRGB
import net.gamebub.framework.interface._
import net.gamebub.framework.Core

object HandheldNes {
  object CommandState extends ChiselEnum {
    val idle, busy, error, done = Value
  }

  /**
   * MMCM VCO frequency: 601.25 MHz.
   *
   * The NES master clock (NTSC: 21.477272 MHz) is VCO / 28 = 21.473 MHz, which
   * is 0.02% slow. The SDRAM clock must be exactly 4x the master clock (and
   * phase aligned), so both are integer divisions of the same VCO.
   */
  val mmcmVcoHz = 50_000_000.toDouble / 5 * 60.125
  val systemDivider = 28
  val sdramDivider = 7

  /**
   * Phase (degrees) of the clock forwarded to the SDRAM, relative to the
   * SDRAM controller clock. Chosen to center the read data capture window
   * and command setup/hold (see the I/O constraints in nes.xdc).
   */
  val sdramOutPhase = 270.0

  /** File IDs, must match the firmware. */
  val FileRom = 0
  val FileSave = 1

  /** Master clocks per frame (341 x 262 dots, 4 clocks each). */
  val clocksPerFrame = 341 * 262 * 4

  /**
   * Video framebuffer pixel format: the raw NES color is stored, and converted
   * to RGB by the video filter:
   *   r: emphasis bits
   *   g, b: color bits [5:3], [2:0]
   * The color is XORed with $0F, so that a zeroed framebuffer is black (color
   * $0F) instead of gray (color $00).
   */
  val colorXor = 0x0F

  /** Interface of the NesGamebub Verilog module. */
  class NesIO extends Bundle {
    val clockSdram = Input(Clock())
    val clockSdramOut = Input(Clock())

    val coreReset = Input(Bool())
    val corePause = Input(Bool())

    val loadActive = Input(Bool())
    val loadValid = Input(Bool())
    val loadData = Input(UInt(32.W))
    val loadReady = Output(Bool())
    val loadBusy = Output(Bool())
    val romLoaded = Output(Bool())
    val loadError = Output(Bool())

    val saveEnable = Input(Bool())
    val saveWrite = Input(Bool())
    val saveAddress = Input(UInt(18.W))
    val saveDataWrite = Input(UInt(32.W))
    val saveDataRead = Output(UInt(32.W))
    val saveDone = Output(Bool())
    val saveSize = Output(UInt(18.W))
    val saveLoad = Input(Bool())
    val saveStore = Input(Bool())
    val saveBusy = Output(Bool())

    /** {right, left, down, up, start, select, b, a} */
    val buttons = Input(UInt(8.W))

    val pixelValid = Output(Bool())
    val pixelColor = Output(UInt(6.W))
    val pixelEmphasis = Output(UInt(3.W))
    val hblank = Output(Bool())
    val vblank = Output(Bool())

    val audio = Output(UInt(16.W))

    val sdramClock = Output(Bool())
    val sdramCke = Output(Bool())
    val sdramCs = Output(Bool())
    val sdramRas = Output(Bool())
    val sdramCas = Output(Bool())
    val sdramWe = Output(Bool())
    val sdramDqm = Output(UInt(2.W))
    val sdramBank = Output(UInt(2.W))
    val sdramAddress = Output(UInt(13.W))
    val sdramDataIn = Input(UInt(16.W))
    val sdramDataOut = Output(UInt(16.W))
    val sdramDataDir = Output(Bool())
  }

  /**
   * Default NES palette (Kitrinx 34, from NES_MiSTer), indexed by NES color.
   */
  val palette: Seq[Int] = Seq(
    0x666666, 0x01247B, 0x1B1489, 0x39087C, 0x520257, 0x5C0725, 0x571300, 0x472300,
    0x2D3300, 0x0E4000, 0x004500, 0x004124, 0x003456, 0x000000, 0x000000, 0x000000,
    0xADADAD, 0x2759C9, 0x4845DB, 0x6F34CA, 0x922B9B, 0xA1305A, 0x9B4018, 0x885400,
    0x686700, 0x3E7A00, 0x1B8213, 0x0D7C57, 0x136C99, 0x000000, 0x000000, 0x000000,
    0xFFFFFF, 0x78ABFF, 0x9897FF, 0xC086FF, 0xE27DEF, 0xF281AF, 0xED916D, 0xDBA43B,
    0xBDB825, 0x92CB33, 0x6DD463, 0x5ECEA8, 0x65BEEA, 0x525252, 0x000000, 0x000000,
    0xFFFFFF, 0xCADBFF, 0xD8D2FF, 0xE7CCFF, 0xF4C9F9, 0xFACBDF, 0xF7D2C4, 0xEEDAAF,
    0xE1E3A5, 0xD0EBAB, 0xC2EEBF, 0xBDEBDB, 0xC0E4F7, 0xB8B8B8, 0x000000, 0x000000,
  )
}

/**
 * NES core, wrapping the NES_MiSTer Verilog core (see hdl/).
 */
class HandheldNes extends Module with Core {
  import HandheldNes._

  val clockDisplayRange = ClocksV0.getClockDisplayHz(1.0 / 60.0)
  val displayDivider = (mmcmVcoHz / clockDisplayRange._1).floor.toInt
  val clockSystemHz = (mmcmVcoHz / systemDivider).toInt

  val io = IO(new Bundle {
    val clocks = new ClocksV0(
      clockSystemHz = clockSystemHz,
      clockDisplayHz = (mmcmVcoHz / displayDivider).toInt,
      clockSpiHz = (mmcmVcoHz / 3).toInt,
    )
    val video = new VideoV0(
      videoWidth = 256,
      videoHeight = 240,
      colorDepthR = 3,
      colorDepthG = 3,
      colorDepthB = 3,
      framePeriod = clocksPerFrame.toDouble / clockSystemHz,
    )
    val videoFilter = new VideoFilterBasicV0(
      colorInDepthR = 3,
      colorInDepthG = 3,
      colorInDepthB = 3,
      latency = 2,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputV0()
    val sdram = new SdramV0()
  })

  // Main MMCM
  val mmcm = Module(new Mmcm(
    clockInHz = 50_000_000,
    divide = 5,
    multiply = 60.125,
    outputs = Seq(
      (systemDivider, 0.0),           // System (NES master clock)
      (sdramDivider, 0.0),            // SDRAM controller (4x)
      (displayDivider, 0.0),          // Display
      (3, 0.0),                       // Host SPI
      (sdramDivider, sdramOutPhase),  // Forwarded to the SDRAM
    )
  ))
  mmcm.io.clockIn := io.clocks.clockIn50M
  io.clocks.clockOutSystem := mmcm.io.clockOuts(0)
  val clockSdram = mmcm.io.clockOuts(1)
  io.clocks.clockOutDisplay := mmcm.io.clockOuts(2)
  io.clocks.clockOutSpi := mmcm.io.clockOuts(3)
  io.clocks.locked := mmcm.io.locked

  val regCoreSetup = RegInit(false.B)
  val regCoreReset = RegInit(true.B)
  val regCoreFocus = RegInit(false.B)
  val regCoreResetOnce = RegInit(false.B)
  regCoreResetOnce := false.B
  /** A ROM file is being written. */
  val regRomLoading = RegInit(false.B)

  // NES
  val nes = Wire(new NesIO)
  bindExtModule("NesGamebub", nes)
  nes.clockSdram := clockSdram
  nes.clockSdramOut := mmcm.io.clockOuts(4)
  nes.coreReset := regCoreReset || regCoreResetOnce
  nes.corePause := !regCoreFocus
  nes.loadActive := regRomLoading

  // Host memory map
  val registerInterface = Wire(new MemoryInterface(addressWidth = 16, dataWidth = 32))
  val romInterface = Wire(new MemoryInterface(addressWidth = 16, dataWidth = 32))
  val saveInterface = Wire(new MemoryInterface(addressWidth = 18, dataWidth = 32))
  val commandInterface = Wire(new MemoryInterface(addressWidth = 16, dataWidth = 32))
  val memoryMap = MemoryMap(
    addressWidth = 32,
    dataWidth = 32,
    entries = Seq(
      0x0.U(4.W) -> registerInterface,
      0x3.U(4.W) -> romInterface,
      0x4.U(4.W) -> saveInterface,
      0xF0.U(8.W) -> commandInterface,
    ))
  io.host.mem.unsafe :<>= memoryMap.unsafe
  memoryMap.writeStrobe := "b1111".U

  registerInterface <> RegisterMap(
    addressWidth = 16,
    dataWidth = 32,
    entries = Seq(
      0x0000 -> RegisterMap.Entry.r(Cat(nes.loadError, nes.romLoaded)),
      0x0004 -> RegisterMap.Entry.r(nes.saveSize),
      0x2000 -> RegisterMap.Entry.w(regCoreResetOnce),
    )
  )

  // ROM loading: 32-bit words (little endian) are passed to the loader.
  // Writes outside of a ROM file transfer are ignored.
  //
  // The host interface ignores `done` in the first cycle of a request, and
  // holds the request until `done`. So each word is accepted once, and done
  // is signaled the cycle after.
  val regRomAccepted = RegInit(false.B)
  val romWrite = romInterface.enable && romInterface.write && regRomLoading
  romInterface.dataRead := 0.U
  nes.loadValid := romWrite && !regRomAccepted
  nes.loadData := romInterface.dataWrite
  when (nes.loadValid && nes.loadReady) {
    regRomAccepted := true.B
  }
  when (regRomAccepted) {
    regRomAccepted := false.B
  }
  romInterface.done := Mux(romWrite, regRomAccepted, RegNext(romInterface.enable))

  // Save RAM staging buffer (byte access)
  val regSaveLoad = RegInit(false.B)
  val regSaveStore = RegInit(false.B)
  regSaveLoad := false.B
  regSaveStore := false.B
  nes.saveLoad := regSaveLoad
  nes.saveStore := regSaveStore
  nes.saveEnable := saveInterface.enable
  nes.saveWrite := saveInterface.write
  nes.saveAddress := saveInterface.address
  nes.saveDataWrite := saveInterface.dataWrite
  saveInterface.dataRead := nes.saveDataRead
  saveInterface.done := nes.saveDone

  // Command interface
  val commandHostState = RegInit(CommandState.idle)
  val regCommandHost = Reg(Vec(2, UInt(32.W)))
  /**
   * Cycles left to wait before finishing a busy command: for the ROM loader to
   * finish (then check the result), or for the save copy to start.
   */
  val regBusyTimer = RegInit(0.U(5.W))
  /** The busy command is a ROM load (otherwise, a save copy). */
  val regBusyRom = Reg(Bool())
  commandInterface <> RegisterMap(
    addressWidth = 16,
    dataWidth = 32,
    entries =
      regCommandHost.zipWithIndex.map { case (reg, i) => (0x0000 + (4 * i) -> RegisterMap.Entry.rw(reg)) }
  )
  // Host -> Core commands
  io.host.commandHost.busy := commandHostState === CommandState.busy
  io.host.commandHost.done := commandHostState === CommandState.done
  io.host.commandHost.error := commandHostState === CommandState.error
  when (io.host.commandHost.request) {
    when (commandHostState === CommandState.idle) {
      val command = regCommandHost(0)(15, 0)
      val argument = regCommandHost(1)
      for (reg <- regCommandHost) {
        reg := 0.U
      }
      commandHostState := CommandState.done

      when (command === HostV0.CommandGetStatus.U) {
        when (regCoreSetup && !nes.saveBusy) {
          regCommandHost(0) := Mux(regCoreReset, HostV0.StatusCoreHalt.U, HostV0.StatusCoreRun.U)
        } .elsewhen (regCoreSetup) {
          // Still copying the save into the cartridge RAM.
          regCommandHost(0) := HostV0.StatusSetup.U
        } .otherwise {
          // No pre-setup initialization to do.
          regCommandHost(0) := HostV0.StatusSetup.U
        }
      } .elsewhen (command === HostV0.CommandSetupComplete.U) {
        // No post-setup initialization to do.
        regCoreSetup := true.B
      } .elsewhen (command === HostV0.CommandCoreRun.U) {
        regCoreReset := false.B
      } .elsewhen (command === HostV0.CommandCoreHalt.U) {
        regCoreReset := true.B
      } .elsewhen (command === HostV0.CommandNotifyFocus.U) {
        regCoreFocus := argument(0)
      } .elsewhen (command === HostV0.CommandFileWriteStart.U) {
        when (argument === FileRom.U) {
          regRomLoading := true.B
          regRomAccepted := false.B
        }
      } .elsewhen (command === HostV0.CommandFileWriteEnd.U) {
        when (argument === FileRom.U) {
          // Let the loader finish, then report whether the ROM was valid.
          regRomLoading := false.B
          regBusyTimer := 3.U
          regBusyRom := true.B
          commandHostState := CommandState.busy
        } .elsewhen (argument === FileSave.U) {
          // Copy the save into the cartridge RAM. This finishes in the
          // background, and the core isn't ready to run until it's done.
          regSaveStore := true.B
        }
      } .elsewhen (command === HostV0.CommandFileReadStart.U) {
        when (argument === FileSave.U) {
          // Copy the cartridge RAM into the staging buffer before reading.
          regCommandHost(0) := nes.saveSize
          regSaveLoad := true.B
          regBusyTimer := 3.U
          regBusyRom := false.B
          commandHostState := CommandState.busy
        }
      } .elsewhen (command === HostV0.CommandFileReadEnd.U) {
        // Nothing to do.
      } .otherwise {
        // Unknown command
        commandHostState := CommandState.error
      }
    } .elsewhen (commandHostState === CommandState.busy) {
      when (regBusyTimer =/= 0.U) {
        regBusyTimer := regBusyTimer - 1.U
      } .elsewhen (regBusyRom) {
        // romLoaded is updated the cycle after the loader finishes.
        when (!nes.loadBusy && !RegNext(nes.loadBusy)) {
          commandHostState := Mux(nes.romLoaded, CommandState.done, CommandState.error)
        }
      } .elsewhen (!nes.saveBusy) {
        commandHostState := CommandState.done
      }
    }
  } .otherwise {
    commandHostState := CommandState.idle
  }
  // Core -> Host commands
  io.host.commandCore.request := false.B

  // Input
  val buttons = io.input.buttons
  nes.buttons := Cat(
    buttons.right,
    buttons.left,
    buttons.down,
    buttons.up,
    buttons.start,
    buttons.select,
    buttons.b || buttons.y,
    buttons.a || buttons.x,
  )

  // Audio (mono)
  io.audio.left := nes.audio.asSInt
  io.audio.right := nes.audio.asSInt

  // Video
  io.video.dataEnable := nes.pixelValid
  val storedColor = nes.pixelColor ^ colorXor.U(6.W)
  io.video.data.r := nes.pixelEmphasis
  io.video.data.g := storedColor(5, 3)
  io.video.data.b := storedColor(2, 0)
  io.video.hblank := nes.hblank
  io.video.vblank := nes.vblank

  // Video filter: NES color to RGB, with color emphasis.
  withClockAndReset (io.videoFilter.clock, io.videoFilter.reset) {
    val in = io.videoFilter.dataIn
    val color = RegNext(Cat(in.g, in.b) ^ colorXor.U(6.W))
    val emphasis = RegNext(in.r)
    val paletteRom = VecInit(palette.map(_.U(24.W)))

    // Stage 1: palette lookup
    val rgb = RegNext(paletteRom(color).asTypeOf(ColorRGB(8)))
    // Emphasis doesn't apply to the blacks at the end of each row ($xE, $xF).
    val emphasisActive = RegNext(Mux(color(3, 1) === "b111".U, 0.U, emphasis))

    // Stage 2: emphasis (attenuate the channels that aren't emphasized)
    def sub2(x: UInt): UInt = x - (x >> 2)
    def sub3(x: UInt): UInt = x - (x >> 3)
    def sub23(x: UInt): UInt = x - (x >> 2) - (x >> 3)
    val out = Wire(ColorRGB(8))
    out := rgb
    switch (emphasisActive) {
      is (1.U) { out.g := sub2(rgb.g); out.b := sub2(rgb.b) }
      is (2.U) { out.r := sub2(rgb.r); out.b := sub2(rgb.b) }
      is (3.U) { out.r := sub2(rgb.r); out.g := sub3(rgb.g); out.b := sub23(rgb.b) }
      is (4.U) { out.r := sub3(rgb.r); out.g := sub3(rgb.g) }
      is (5.U) { out.r := sub3(rgb.r); out.g := sub2(rgb.g); out.b := sub3(rgb.b) }
      is (6.U) { out.r := sub2(rgb.r); out.g := sub3(rgb.g); out.b := sub3(rgb.b) }
      is (7.U) { out.r := sub2(rgb.r); out.g := sub2(rgb.g); out.b := sub2(rgb.b) }
    }
    io.videoFilter.dataOut := out
  }

  // SDRAM (driven directly by the NES SDRAM controller)
  io.sdram.clock := nes.sdramClock.asClock
  io.sdram.cke := nes.sdramCke
  io.sdram.cs := nes.sdramCs.asUInt
  io.sdram.ras := nes.sdramRas
  io.sdram.cas := nes.sdramCas
  io.sdram.we := nes.sdramWe
  io.sdram.dqm := nes.sdramDqm
  io.sdram.bank := nes.sdramBank
  io.sdram.address := nes.sdramAddress
  nes.sdramDataIn := io.sdram.dataIn
  io.sdram.dataOut := nes.sdramDataOut
  io.sdram.dataDir := nes.sdramDataDir
}
