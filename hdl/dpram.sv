// Portable replacement for the Altera altsyncram-based `dpram` used by the
// NES_MiSTer mappers (MMC5, Namco 163, VRC). Infers a true dual-port block
// RAM in Vivado with the same behavior as the original configuration:
// one cycle read latency, write-first (new data) on read-during-write.
module dpram #(
    parameter init_file = " ",
    parameter widthad_a = 8,
    parameter width_a = 8,
    parameter outdata_reg_a = "UNREGISTERED",
    parameter outdata_reg_b = "UNREGISTERED"
) (
    input  wire                     clock_a,
    input  wire [widthad_a-1:0]     address_a,
    input  wire [width_a-1:0]       data_a,
    input  wire                     wren_a,
    input  wire [width_a/8-1:0]     byteena_a,
    output logic [width_a-1:0]      q_a,

    input  wire                     clock_b,
    input  wire [widthad_a-1:0]     address_b,
    input  wire [width_a-1:0]       data_b,
    input  wire                     wren_b,
    input  wire [width_a/8-1:0]     byteena_b,
    output logic [width_a-1:0]      q_b
);
    (* ram_style = "block" *)
    logic [width_a-1:0] mem [0:(2**widthad_a)-1];

    initial begin
        for (int i = 0; i < 2**widthad_a; i++) mem[i] = '0;
    end

    always_ff @(posedge clock_a) begin
        if (wren_a) begin
            for (int i = 0; i < width_a / 8; i++) begin
                if (byteena_a[i]) mem[address_a][i*8 +: 8] <= data_a[i*8 +: 8];
            end
            q_a <= data_a;
        end else begin
            q_a <= mem[address_a];
        end
    end

    always_ff @(posedge clock_b) begin
        if (wren_b) begin
            for (int i = 0; i < width_a / 8; i++) begin
                if (byteena_b[i]) mem[address_b][i*8 +: 8] <= data_b[i*8 +: 8];
            end
            q_b <= data_b;
        end else begin
            q_b <= mem[address_b];
        end
    end
endmodule
