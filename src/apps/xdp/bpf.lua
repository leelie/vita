-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local ffi = require("ffi")
local bor = bit.bor

-- BPF: just enough eBPF to assemble trivial XDP programs.
--
-- See "BPF Architecture":
--   https://docs.cilium.io/en/v1.6/bpf/#bpf-architecture
--
-- See Linux v4.19:
--   include/uapi/linux/bpf_common.h
--   include/uapi/linux/bpf.h
--   tools/include/linux/filter.h

ins = ffi.typeof[[
   struct {
      uint8_t op;      /* opcode */
      uint8_t dst:4;   /* dest register */
      uint8_t src:4;   /* source register */
      int16_t off;     /* signed offset */
      int32_t imm;     /* signed immediate constant */
   } __attribute__((packed))
]]

c = { -- Op class
   LD = 0x00,
   LDX = 0x01,
   ST = 0x02,
   STX = 0x03,
   ALU = 0x04,
   JMP = 0x05,
   RET = 0x06,
   MISC = 0x07,
   ALU64 = 0x07 -- alu mode in double word width
}

f = { -- Load/store width
   W  = 0x00,  -- 32-bit
   H  = 0x08,  -- 16-bit
   B  = 0x10,  -- 8-bit
   DW = 0x18   -- 64-bit
}

m = { -- Op mode
   IMM = 0x00,
   ABS = 0x20,
   IND = 0x40,
   MEM = 0x60,
   LEN = 0x80,
   MSH = 0xa0,
   XADD = 0xc0 -- exclusive add
}

a = { -- ALU mode
   ADD = 0x00,
   SUB = 0x10,
   MUL = 0x20,
   DIV = 0x30,
   OR = 0x40,
   AND = 0x50,
   LSH = 0x60,
   RSH = 0x70,
   NEG = 0x80,
   MOD = 0x90,
   XOR = 0xa0,
   MOV = 0xb0
}

s = { -- Src mode
   K = 0x00,
   X = 0x08,
   MAP_FD = 0x01
}

j = { -- JMP mode
   JA   = 0x00,
   JEQ  = 0x10,
   JGT  = 0x20,
   JGE  = 0x30,
   JSET = 0x40,
   JNE  = 0x50,
   JLT  = 0xa0,
   JLE  = 0xb0,
   JSGT = 0x60,
   JSGE = 0x70,
   JSLT = 0xc0,
   JSLE = 0xd0,
   CALL = 0x80,
   EXIT = 0x90
}

fn = { -- Built-in helpers
   unspec = 0,
   map_lookup_elem = 1,
   map_update_elem = 2,
   map_delete_elem = 3,
   probe_read = 4,
   ktime_get_ns = 5,
   trace_printk = 6,
   get_prandom_u32 = 7,
   get_smp_processor_id = 8,
   skb_store_bytes = 9,
   l3_csum_replace = 10,
   l4_csum_replace = 11,
   tail_call = 12,
   clone_redirect = 13,
   get_current_pid_tgid = 14,
   get_current_uid_gid = 15,
   get_current_comm = 16,
   get_cgroup_classid = 17,
   skb_vlan_push = 18,
   skb_vlan_pop = 19,
   skb_get_tunnel_key = 20,
   skb_set_tunnel_key = 21,
   perf_event_read = 22,
   redirect = 23,
   get_route_realm = 24,
   perf_event_output = 25,
   skb_load_bytes = 26,
   get_stackid = 27,
   csum_diff = 28,
   skb_get_tunnel_opt = 29,
   skb_set_tunnel_opt = 30,
   skb_change_proto = 31,
   skb_change_type = 32,
   skb_under_cgroup = 33,
   get_hash_recalc = 34,
   get_current_task = 35,
   probe_write_user = 36,
   current_task_under_cgroup = 37,
   skb_change_tail = 38,
   skb_pull_data = 39,
   csum_update = 40,
   set_hash_invalid = 41,
   get_numa_node_id = 42,
   skb_change_head = 43,
   xdp_adjust_head = 44,
   probe_read_str = 45,
   get_socket_cookie = 46,
   get_socket_uid = 47,
   set_hash = 48,
   setsockopt = 49,
   skb_adjust_room = 50,
   redirect_map = 51,
   sk_redirect_map = 52,
   sock_map_update = 53,
   xdp_adjust_meta = 54,
   perf_event_read_value = 55,
   perf_prog_read_value = 56,
   getsockopt = 57,
   override_return = 58,
   sock_ops_cb_flags_set = 59,
   msg_redirect_map = 60,
   msg_apply_bytes = 61,
   msg_cork_bytes = 62,
   msg_pull_data = 63,
   bind = 64,
   xdp_adjust_tail = 65,
   skb_get_xfrm_state = 66,
   get_stack = 67,
   skb_load_bytes_relative = 68,
   fib_lookup = 69,
   sock_hash_update = 70,
   msg_redirect_hash = 71,
   sk_redirect_hash = 72,
   lwt_push_encap = 73,
   lwt_seg6_store_bytes = 74,
   lwt_seg6_adjust_srh = 75,
   lwt_seg6_action = 76,
   rc_repeat = 77,
   rc_keydown = 78,
   skb_cgroup_id = 79,
   get_current_cgroup_id = 80,
   get_local_storage = 81,
   sk_select_reuseport = 82,
   skb_ancestor_cgroup_id = 83,
}

function asm (insn) return ffi.typeof("$[?]", ins)(#insn, insn) end
