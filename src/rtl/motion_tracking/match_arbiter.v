//冲突仲裁模块
`timescale 1ns/1ps
// match_arbiter
// 功能：匹配冲突仲裁
module match_arbiter#(
parameter MAX_ROI =4,
parameter MAX_TRACK=4,
parameter DIST_W=12,
parameter IDX_W=4)
(
input[3:0] cur_num,
input[MAX_ROI-1:0] match_valid,
input[MAX_ROI*IDX_W-1:0] matched_idx,
input[MAX_ROI*DIST_W-1:0] min_dist,
output[MAX_ROI-1:0] arb_valid
);
genvar i,k;
generate
    for(i=0;i<MAX_ROI;i=i+1)begin : GEN_ARB_ROW
        wire lose_i;
        wire [MAX_ROI-1:0] beaten_by_k;
        for(k=0;k<MAX_ROI;k=k+1)begin : GEN_ARB_COL
            // 提取当前目标 i 的数据
            wire [DIST_W-1:0] dist_i = min_dist[i*DIST_W+:DIST_W];
            wire [IDX_W-1:0]  idx_i  = matched_idx[i*IDX_W+:IDX_W];
            
            // 提取竞争对手 k 的数据
            wire [DIST_W-1:0] dist_k = min_dist[k*DIST_W+:DIST_W];
            wire [IDX_W-1:0]  idx_k  = matched_idx[k*IDX_W+:IDX_W];
            
            if(i==k)begin : GEN_SELF
                // 不能自己打败自己
                assign beaten_by_k[k] = 1'b0;
            end else begin : GEN_OTHER
                // 竞争条件：k有效 & i有效 & 抢同一个历史槽位 & (k距离更短 或 (距离相等且k索引更小))
                assign beaten_by_k[k] = (k < cur_num) && (i < cur_num) &&
                                        match_valid[k] && match_valid[i] &&
                                        (idx_k == idx_i) &&
                                        ( (dist_k < dist_i) || ((dist_k == dist_i) && (k < i)) );
            end
        end
        // 只要有任何一个 k 打败了 i，i 就出局
        assign lose_i = |beaten_by_k;
        
        // 输出仲裁结果：保留原有有效性，剔除被击败的；
        // 超出 cur_num 的行不参与仲裁，输出也强制为 0（与竞争条件口径一致）
        assign arb_valid[i] = (i < cur_num) && (match_valid[i] & (~lose_i));
    end
endgenerate
endmodule //match_arbiter
