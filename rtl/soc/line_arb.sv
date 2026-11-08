// DDR3 line port arbiter (HAS_DDR_MEM = 1): the I-cache refill (read only)
// and the D-cache refill / write-back share rtl/ddr/ddr_line_bridge.sv, one
// requester at a time.
//
// Requester port (both caches): req and addr (DDR3 byte address [27:4]), for
// the D-cache also we and wdata, held until gnt. gnt is a one-cycle pulse:
// for a write, the cycle both the command and its data have entered the
// bridge FIFOs (the write is then done for the requester); for a read, the
// cycle the command has entered the bridge. A read then gets exactly one
// valid pulse with the 16 bytes (byte k in data[8k+7:8k]); the port stays
// owned until that beat, so at most one read is outstanding. The D-cache wins
// when both ask in the same cycle.
module line_arb (
    input  logic         clk,
    input  logic         rst,

    // I-cache refill
    input  logic         i_req,
    input  logic [27:4]  i_addr,
    output logic         i_gnt,
    output logic         i_valid,
    output logic [127:0] i_data,

    // D-cache refill / write-back
    input  logic         d_req,
    input  logic         d_we,
    input  logic [27:4]  d_addr,
    input  logic [127:0] d_wdata,
    output logic         d_gnt,
    output logic         d_valid,
    output logic [127:0] d_data,

    // ddr_line_bridge core-side port
    output logic         cmd_valid,
    input  logic         cmd_ready,
    output logic         cmd_store,
    output logic [23:0]  cmd_line,
    output logic         wr_valid,
    input  logic         wr_ready,
    output logic [127:0] wr_data,
    input  logic         rd_valid,
    output logic         rd_ready,
    input  logic [127:0] rd_data
);

    typedef enum logic [1:0] {A_IDLE, A_CMD, A_WAIT} astate_t;
    astate_t st;
    logic    own_d;              // the D-cache owns the port
    logic    cmd_done, dat_done; // this write's command / data already in the bridge
    logic    store;

    assign store     = own_d && d_we;
    assign cmd_store = store;
    assign cmd_line  = own_d ? d_addr : i_addr;
    assign wr_data   = d_wdata;
    assign cmd_valid = (st == A_CMD) && !cmd_done;
    assign wr_valid  = (st == A_CMD) && store && !dat_done;

    logic issued;
    assign issued = (st == A_CMD) && (cmd_done || (cmd_valid && cmd_ready)) &&
                    (!store || dat_done || (wr_valid && wr_ready));

    assign i_gnt = issued && !own_d;
    assign d_gnt = issued && own_d;

    assign rd_ready = (st == A_WAIT);
    assign i_valid  = (st == A_WAIT) && rd_valid && !own_d;
    assign d_valid  = (st == A_WAIT) && rd_valid && own_d;
    assign i_data   = rd_data;
    assign d_data   = rd_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            st       <= A_IDLE;
            own_d    <= 1'b0;
            cmd_done <= 1'b0;
            dat_done <= 1'b0;
        end else begin
            unique case (st)
                A_IDLE: if (d_req || i_req) begin
                    own_d <= d_req;
                    st    <= A_CMD;
                end
                A_CMD: begin
                    if (issued) begin
                        cmd_done <= 1'b0;
                        dat_done <= 1'b0;
                        st       <= store ? A_IDLE : A_WAIT;
                    end else begin
                        if (cmd_valid && cmd_ready) cmd_done <= 1'b1;
                        if (wr_valid && wr_ready)   dat_done <= 1'b1;
                    end
                end
                A_WAIT: if (rd_valid) st <= A_IDLE;
                default: st <= A_IDLE;
            endcase
        end
    end

endmodule
