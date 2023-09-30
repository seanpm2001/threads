open Values
open Types
open Instance
open Ast
open Source


(* Errors *)

module Link = Error.Make ()
module Trap = Error.Make ()
module Crash = Error.Make ()
module Exhaustion = Error.Make ()

exception Link = Link.Error
exception Trap = Trap.Error
exception Crash = Crash.Error (* failure that cannot happen in valid code *)
exception Exhaustion = Exhaustion.Error

let table_error at = function
  | Table.Bounds -> "out of bounds table access"
  | Table.SizeOverflow -> "table size overflow"
  | Table.SizeLimit -> "table size limit reached"
  | Table.Type -> Crash.error at "type mismatch at table access"
  | exn -> raise exn

let memory_error at = function
  | Memory.Bounds -> "out of bounds memory access"
  | Memory.SizeOverflow -> "memory size overflow"
  | Memory.SizeLimit -> "memory size limit reached"
  | Memory.Type -> Crash.error at "type mismatch at memory access"
  | exn -> raise exn

let numeric_error at = function
  | Ixx.Overflow -> "integer overflow"
  | Ixx.DivideByZero -> "integer divide by zero"
  | Ixx.InvalidConversion -> "invalid conversion to integer"
  | Values.TypeError (i, v, t) ->
    Crash.error at
      ("type error, expected " ^ Types.string_of_num_type t ^ " as operand " ^
       string_of_int i ^ ", got " ^ Types.string_of_num_type (type_of_num v))
  | exn -> raise exn

(* Must be positive and non-zero *)
let timeout_epsilon = 1000000L


(* Administrative Expressions & Configurations *)

type 'a stack = 'a list

type frame =
{
  inst : module_inst;
  locals : value ref list;
}

type code = value stack * admin_instr list

and admin_instr = admin_instr' phrase
and admin_instr' =
  | Plain of instr'
  | Refer of ref_
  | Invoke of func_inst
  | Trapping of string
  | Returning of value stack
  | Breaking of int32 * value stack
  | Label of int32 * instr list * code
  | Frame of int32 * frame * code
  | Suspend of memory_inst * Memory.address * float

type action =
  | NoAction
    (* memory, cell index, number of threads to wake *)
  | NotifyAction of memory_inst * Memory.address * I32.t

type thread =
{
  frame : frame;
  code : code;
  budget : int;  (* to model stack overflow *)
}

type config = thread list
type thread_id = int
type status = Running | Result of value list | Trap of exn

let frame inst locals = {inst; locals}
let thread inst vs es = {frame = frame inst []; code = vs, es; budget = !Flags.budget}
let empty_thread = thread empty_module_inst [] []
let empty_config = []
let spawn (c : config) = List.length c, c @ [empty_thread]

let status (c : config) (n : thread_id) : status =
  let t = List.nth c n in
  match t.code with
  | vs, [] -> Result (List.rev vs)
  | [], {it = Trapping msg; at} :: _ -> Trap (Trap.Error (at, msg))
  | _ -> Running

let clear (c : config) (n : thread_id) : config =
  let ts1, t, ts2 = Lib.List.extract n c in
  ts1 @ [{t with code = [], []}] @ ts2
  
let plain e = Plain e.it @@ e.at

let lookup category list x =
  try Lib.List32.nth list x.it with Failure _ ->
    Crash.error x.at ("undefined " ^ category ^ " " ^ Int32.to_string x.it)

let type_ (inst : module_inst) x = lookup "type" inst.types x
let func (inst : module_inst) x = lookup "function" inst.funcs x
let table (inst : module_inst) x = lookup "table" inst.tables x
let memory (inst : module_inst) x = lookup "memory" inst.memories x
let global (inst : module_inst) x = lookup "global" inst.globals x
let elem (inst : module_inst) x = lookup "element segment" inst.elems x
let data (inst : module_inst) x = lookup "data segment" inst.datas x
let local (frame : frame) x = lookup "local" frame.locals x

let any_ref inst x i at =
  try Table.load (table inst x) i with Table.Bounds ->
    Trap.error at ("undefined element " ^ Int32.to_string i)

let func_ref inst x i at =
  match any_ref inst x i at with
  | FuncRef f -> f
  | NullRef _ -> Trap.error at ("uninitialized element " ^ Int32.to_string i)
  | _ -> Crash.error at ("type mismatch for element " ^ Int32.to_string i)

let func_type_of = function
  | Func.AstFunc (t, inst, f) -> t
  | Func.HostFunc (t, _) -> t

let block_type inst bt =
  match bt with
  | VarBlockType x -> type_ inst x
  | ValBlockType None -> FuncType ([], [])
  | ValBlockType (Some t) -> FuncType ([], [t])

let take n (vs : 'a stack) at =
  try Lib.List32.take n vs with Failure _ -> Crash.error at "stack underflow"

let drop n (vs : 'a stack) at =
  try Lib.List32.drop n vs with Failure _ -> Crash.error at "stack underflow"

let check_align addr ty sz at =
  if not (Memory.is_aligned addr ty sz) then
    Trap.error at "unaligned atomic memory access"

let check_shared mem at =
  if shared_memory_type (Memory.type_of mem) <> Shared then
    Trap.error at "expected shared memory"

(* Evaluation *)

(*
 * Conventions:
 *   e  : instr
 *   v  : value
 *   es : instr list
 *   vs : value stack
 *   c : config
 *)

let mem_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Memory.bound (memory frame.inst x))

let data_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Data.size (data frame.inst x))

let table_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (I64_convert.extend_i32_u (Table.size (table frame.inst x)))

let elem_oob frame x i n =
  I64.gt_u (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (I64_convert.extend_i32_u (Elem.size (elem frame.inst x)))

let rec step_thread (t : thread) : thread * action =
  let {frame; code = vs, es; _} = t in
  let e = List.hd es in
  let vs', es', act =
    match e.it, vs with
    | Plain e', vs ->
      (match e', vs with
      | Unreachable, vs ->
        vs, [Trapping "unreachable executed" @@ e.at], NoAction

      | Nop, vs ->
        vs, [], NoAction

      | Block (bt, es'), vs ->
        let FuncType (ts1, ts2) = block_type frame.inst bt in
        let n1 = Lib.List32.length ts1 in
        let n2 = Lib.List32.length ts2 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        vs', [Label (n2, [], (args, List.map plain es')) @@ e.at], NoAction

      | Loop (bt, es'), vs ->
        let FuncType (ts1, ts2) = block_type frame.inst bt in
        let n1 = Lib.List32.length ts1 in
        let args, vs' = take n1 vs e.at, drop n1 vs e.at in
        vs', [Label (n1, [e' @@ e.at], (args, List.map plain es')) @@ e.at], NoAction

      | If (bt, es1, es2), Num (I32 i) :: vs' ->
        if i = 0l then
          vs', [Plain (Block (bt, es2)) @@ e.at], NoAction
        else
          vs', [Plain (Block (bt, es1)) @@ e.at], NoAction

      | Br x, vs ->
        [], [Breaking (x.it, vs) @@ e.at], NoAction

      | BrIf x, Num (I32 i) :: vs' ->
        if i = 0l then
          vs', [], NoAction
        else
          vs', [Plain (Br x) @@ e.at], NoAction

      | BrTable (xs, x), Num (I32 i) :: vs' ->
        if I32.ge_u i (Lib.List32.length xs) then
          vs', [Plain (Br x) @@ e.at], NoAction
        else
          vs', [Plain (Br (Lib.List32.nth xs i)) @@ e.at], NoAction

      | Return, vs ->
        [], [Returning vs @@ e.at], NoAction

      | Call x, vs ->
        vs, [Invoke (func frame.inst x) @@ e.at], NoAction

      | CallIndirect (x, y), Num (I32 i) :: vs ->
        let func = func_ref frame.inst x i e.at in
        if type_ frame.inst y <> Func.type_of func then
          vs, [Trapping "indirect call type mismatch" @@ e.at], NoAction
        else
          vs, [Invoke func @@ e.at], NoAction

      | Drop, v :: vs' ->
        vs', [], NoAction

      | Select _, Num (I32 i) :: v2 :: v1 :: vs' ->
        if i = 0l then
          v2 :: vs', [], NoAction
        else
          v1 :: vs', [], NoAction

      | LocalGet x, vs ->
        !(local frame x) :: vs, [], NoAction

      | LocalSet x, v :: vs' ->
        local frame x := v;
        vs', [], NoAction

      | LocalTee x, v :: vs' ->
        local frame x := v;
        v :: vs', [], NoAction

      | GlobalGet x, vs ->
        Global.load (global frame.inst x) :: vs, [], NoAction

      | GlobalSet x, v :: vs' ->
        (try Global.store (global frame.inst x) v; vs', [], NoAction
        with Global.NotMutable -> Crash.error e.at "write to immutable global"
           | Global.Type -> Crash.error e.at "type mismatch at global write")

      | TableGet x, Num (I32 i) :: vs' ->
        (try Ref (Table.load (table frame.inst x) i) :: vs', [], NoAction
        with exn -> vs', [Trapping (table_error e.at exn) @@ e.at], NoAction)

      | TableSet x, Ref r :: Num (I32 i) :: vs' ->
        (try Table.store (table frame.inst x) i r; vs', [], NoAction
        with exn -> vs', [Trapping (table_error e.at exn) @@ e.at], NoAction)

      | TableSize x, vs ->
        Num (I32 (Table.size (table frame.inst x))) :: vs, [], NoAction

      | TableGrow x, Num (I32 delta) :: Ref r :: vs' ->
        let tab = table frame.inst x in
        let old_size = Table.size tab in
        let result =
          try Table.grow tab delta r; old_size
          with Table.SizeOverflow | Table.SizeLimit | Table.OutOfMemory -> -1l
        in Num (I32 result) :: vs', [], NoAction

      | TableFill x, Num (I32 n) :: Ref r :: Num (I32 i) :: vs' ->
        if table_oob frame x i n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else
          let _ = assert (I32.lt_u i 0xffff_ffffl) in
          vs', List.map (at e.at) [
            Plain (Const (I32 i @@ e.at));
            Refer r;
            Plain (TableSet x);
            Plain (Const (I32 (I32.add i 1l) @@ e.at));
            Refer r;
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableFill x);
          ], NoAction

      | TableCopy (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if table_oob frame x d n || table_oob frame y s n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else if I32.le_u d s then
          vs', List.map (at e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (TableGet y);
            Plain (TableSet x);
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableCopy (x, y));
          ], NoAction
        else (* d > s *)
          vs', List.map (at e.at) [
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableCopy (x, y));
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (TableGet y);
            Plain (TableSet x);
          ], NoAction

      | TableInit (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if table_oob frame x d n || elem_oob frame y s n then
          vs', [Trapping (table_error e.at Table.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else
          let seg = elem frame.inst y in
          vs', List.map (at e.at) [
            Plain (Const (I32 d @@ e.at));
            Refer (Elem.load seg s);
            Plain (TableSet x);
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (TableInit (x, y));
          ], NoAction

      | ElemDrop x, vs ->
        let seg = elem frame.inst x in
        Elem.drop seg;
        vs, [], NoAction

      | Load {offset; ty; pack; _}, Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let a = I64_convert.extend_i32_u i in
        (try
          let n =
            match pack with
            | None -> Memory.load_num mem a offset ty
            | Some (sz, ext) -> Memory.load_num_packed sz ext mem a offset ty
          in Num n :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | Store {offset; pack; _}, Num n :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let a = I64_convert.extend_i32_u i in
        (try
          (match pack with
          | None -> Memory.store_num mem a offset n
          | Some sz -> Memory.store_num_packed sz mem a offset n
          );
          vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction);

      | AtomicLoad {offset; ty; pack; _}, Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          check_align addr ty pack e.at;
          let n =
            match pack with
            | None -> Memory.load_num mem addr offset ty
            | Some sz -> Memory.load_num_packed sz ZX mem addr offset ty
          in Num n :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | AtomicStore {offset; ty; pack; _}, Num n :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          check_align addr ty pack e.at;
          (match pack with
          | None -> Memory.store_num mem addr offset n
          | Some sz -> Memory.store_num_packed sz mem addr offset n
          );
          vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction);

      | AtomicRmw (rmwop, {offset; ty; pack; _}), Num n :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          check_align addr ty pack e.at;
          let n1 =
            match pack with
            | None -> Memory.load_num mem addr offset ty
            | Some sz -> Memory.load_num_packed sz ZX mem addr offset ty
          in let n2 = Eval_num.eval_rmwop rmwop n1 n
          in (match pack with
          | None -> Memory.store_num mem addr offset n2
          | Some sz -> Memory.store_num_packed sz mem addr offset n2
          );
          Num n1 :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | AtomicRmwCmpXchg {offset; ty; pack; _}, Num vn :: Num ve :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          check_align addr ty pack e.at;
          let n1, expected =
            match pack with
            | None -> Memory.load_num mem addr offset ty, ve
            | Some sz -> Memory.load_num_packed sz ZX mem addr offset ty,
                           (match ve with
                            | I32 x -> I32 (I32.trunc_to x ((packed_size sz) * 8))
                            | I64 x -> I64 (I64.trunc_to x ((packed_size sz) * 8))
                            | _ -> Crash.error e.at "non-integer atomic comparison attempted")
          in
          (if n1 = expected then
                match pack with
                | None -> Memory.store_num mem addr offset vn
                | Some sz -> Memory.store_num_packed sz mem addr offset vn
          );
          Num n1 :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction);

      | MemoryAtomicWait {offset; ty; pack; _}, Num (I64 timeout) :: Num ve :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          assert (pack = None);
          check_align addr ty pack e.at;
          check_shared mem e.at;
          let v = Memory.load_num mem addr offset ty in
          if v = ve then
            if timeout >= 0L && timeout < timeout_epsilon then
              Num (I32 2l) :: vs', [], NoAction (* Treat as though wait timed out immediately *)
            else
              (* TODO: meaningful timestamp handling *)
              vs', [Suspend (mem, addr, 0.) @@ e.at], NoAction
          else
            Num (I32 1l) :: vs', [], NoAction  (* Not equal *)
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | MemoryAtomicNotify {offset; ty; pack; _}, Num (I32 count) :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          check_align addr ty pack e.at;
          let _ = Memory.load_num mem addr offset ty in
          if count = 0l then
            Num (I32 0l) :: vs', [], NoAction  (* Trivial case waking 0 waiters *)
          else
            vs', [], NotifyAction (mem, addr, count)
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | AtomicFence, vs ->
        vs, [], NoAction

      | VecLoad {offset; ty; pack; _}, Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          let v =
            match pack with
            | None -> Memory.load_vec mem addr offset ty
            | Some (sz, ext) ->
              Memory.load_vec_packed sz ext mem addr offset ty
          in Vec v :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | VecStore {offset; _}, Vec v :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          Memory.store_vec mem addr offset v;
          vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction);

      | VecLoadLane ({offset; ty; pack; _}, j), Vec (V128 v) :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          let v =
            match pack with
            | Pack8 ->
              V128.I8x16.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num_packed Pack8 SX mem addr offset I32Type))
            | Pack16 ->
              V128.I16x8.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num_packed Pack16 SX mem addr offset I32Type))
            | Pack32 ->
              V128.I32x4.replace_lane j v
                (I32Num.of_num 0 (Memory.load_num mem addr offset I32Type))
            | Pack64 ->
              V128.I64x2.replace_lane j v
                (I64Num.of_num 0 (Memory.load_num mem addr offset I64Type))
          in Vec (V128 v) :: vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | VecStoreLane ({offset; ty; pack; _}, j), Vec (V128 v) :: Num (I32 i) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let addr = I64_convert.extend_i32_u i in
        (try
          (match pack with
          | Pack8 ->
            Memory.store_num_packed Pack8 mem addr offset (I32 (V128.I8x16.extract_lane_s j v))
          | Pack16 ->
            Memory.store_num_packed Pack16 mem addr offset (I32 (V128.I16x8.extract_lane_s j v))
          | Pack32 ->
            Memory.store_num mem addr offset (I32 (V128.I32x4.extract_lane_s j v))
          | Pack64 ->
            Memory.store_num mem addr offset (I64 (V128.I64x2.extract_lane_s j v))
          );
          vs', [], NoAction
        with exn -> vs', [Trapping (memory_error e.at exn) @@ e.at], NoAction)

      | MemorySize, vs ->
        let mem = memory frame.inst (0l @@ e.at) in
        Num (I32 (Memory.size mem)) :: vs, [], NoAction

      | MemoryGrow, Num (I32 delta) :: vs' ->
        let mem = memory frame.inst (0l @@ e.at) in
        let old_size = Memory.size mem in
        let result =
          try Memory.grow mem delta; old_size
          with Memory.SizeOverflow | Memory.SizeLimit | Memory.OutOfMemory -> -1l
        in Num (I32 result) :: vs', [], NoAction

      | MemoryFill, Num (I32 n) :: Num k :: Num (I32 i) :: vs' ->
        if mem_oob frame (0l @@ e.at) i n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else
          vs', List.map (at e.at) [
            Plain (Const (I32 i @@ e.at));
            Plain (Const (k @@ e.at));
            Plain (Store
              {ty = I32Type; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add i 1l) @@ e.at));
            Plain (Const (k @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryFill);
          ], NoAction

      | MemoryCopy, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if mem_oob frame (0l @@ e.at) s n || mem_oob frame (0l @@ e.at) d n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else if I32.le_u d s then
          vs', List.map (at e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (Load
              {ty = I32Type; align = 0; offset = 0l; pack = Some (Pack8, ZX)});
            Plain (Store
              {ty = I32Type; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryCopy);
          ], NoAction
        else (* d > s *)
          vs', List.map (at e.at) [
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryCopy);
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 s @@ e.at));
            Plain (Load
              {ty = I32Type; align = 0; offset = 0l; pack = Some (Pack8, ZX)});
            Plain (Store
              {ty = I32Type; align = 0; offset = 0l; pack = Some Pack8});
          ], NoAction

      | MemoryInit x, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
        if mem_oob frame (0l @@ e.at) d n || data_oob frame x s n then
          vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at], NoAction
        else if n = 0l then
          vs', [], NoAction
        else
          let seg = data frame.inst x in
          let a = I64_convert.extend_i32_u s in
          let b = Data.load seg a in
          vs', List.map (at e.at) [
            Plain (Const (I32 d @@ e.at));
            Plain (Const (I32 (I32.of_int_u (Char.code b)) @@ e.at));
            Plain (Store
              {ty = I32Type; align = 0; offset = 0l; pack = Some Pack8});
            Plain (Const (I32 (I32.add d 1l) @@ e.at));
            Plain (Const (I32 (I32.add s 1l) @@ e.at));
            Plain (Const (I32 (I32.sub n 1l) @@ e.at));
            Plain (MemoryInit x);
          ], NoAction

      | DataDrop x, vs ->
        let seg = data frame.inst x in
        Data.drop seg;
        vs, [], NoAction

      | RefNull t, vs' ->
        Ref (NullRef t) :: vs', [], NoAction

      | RefIsNull, Ref r :: vs' ->
        (match r with
        | NullRef _ ->
          Num (I32 1l) :: vs', [], NoAction
        | _ ->
          Num (I32 0l) :: vs', [], NoAction
        )

      | RefFunc x, vs' ->
        let f = func frame.inst x in
        Ref (FuncRef f) :: vs', [], NoAction

      | Const n, vs ->
        Num n.it :: vs, [], NoAction

      | Test testop, Num n :: vs' ->
        (try value_of_bool (Eval_num.eval_testop testop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | Compare relop, Num n2 :: Num n1 :: vs' ->
        (try value_of_bool (Eval_num.eval_relop relop n1 n2) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | Unary unop, Num n :: vs' ->
        (try Num (Eval_num.eval_unop unop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | Binary binop, Num n2 :: Num n1 :: vs' ->
        (try Num (Eval_num.eval_binop binop n1 n2) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | Convert cvtop, Num n :: vs' ->
        (try Num (Eval_num.eval_cvtop cvtop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecConst v, vs ->
        Vec v.it :: vs, [], NoAction

      | VecTest testop, Vec n :: vs' ->
        (try value_of_bool (Eval_vec.eval_testop testop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecUnary unop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_unop unop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecBinary binop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_binop binop n1 n2) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecCompare relop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_relop relop n1 n2) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecConvert cvtop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_cvtop cvtop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecShift shiftop, Num s :: Vec v :: vs' ->
        (try Vec (Eval_vec.eval_shiftop shiftop v s) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecBitmask bitmaskop, Vec v :: vs' ->
        (try Num (Eval_vec.eval_bitmaskop bitmaskop v) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecTestBits vtestop, Vec n :: vs' ->
        (try value_of_bool (Eval_vec.eval_vtestop vtestop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecUnaryBits vunop, Vec n :: vs' ->
        (try Vec (Eval_vec.eval_vunop vunop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecBinaryBits vbinop, Vec n2 :: Vec n1 :: vs' ->
        (try Vec (Eval_vec.eval_vbinop vbinop n1 n2) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecTernaryBits vternop, Vec v3 :: Vec v2 :: Vec v1 :: vs' ->
        (try Vec (Eval_vec.eval_vternop vternop v1 v2 v3) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecSplat splatop, Num n :: vs' ->
        (try Vec (Eval_vec.eval_splatop splatop n) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecExtract extractop, Vec v :: vs' ->
        (try Num (Eval_vec.eval_extractop extractop v) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | VecReplace replaceop, Num r :: Vec v :: vs' ->
        (try Vec (Eval_vec.eval_replaceop replaceop v r) :: vs', [], NoAction
        with exn -> vs', [Trapping (numeric_error e.at exn) @@ e.at], NoAction)

      | _ ->
        let s1 = string_of_values (List.rev vs) in
        let s2 = string_of_value_types (List.map type_of_value (List.rev vs)) in
        Crash.error e.at
          ("missing or ill-typed operand on stack (" ^ s1 ^ " : " ^ s2 ^ ")")
      )

    | Refer r, vs ->
      Ref r :: vs, [], NoAction

    | Trapping msg, vs ->
      assert false

    | Returning vs', vs ->
      Crash.error e.at "undefined frame"

    | Breaking (k, vs'), vs ->
      Crash.error e.at "undefined label"

    | Label (n, es0, (vs', [])), vs ->
      vs' @ vs, [], NoAction

    | Label (n, es0, (vs', {it = Trapping msg; at} :: es')), vs ->
      vs, [Trapping msg @@ at], NoAction

    | Label (n, es0, (vs', {it = Returning vs0; at} :: es')), vs ->
      vs, [Returning vs0 @@ at], NoAction

    | Label (n, es0, (vs', {it = Breaking (0l, vs0); at} :: es')), vs ->
      take n vs0 e.at @ vs, List.map plain es0, NoAction

    | Label (n, es0, (vs', {it = Breaking (k, vs0); at} :: es')), vs ->
      vs, [Breaking (Int32.sub k 1l, vs0) @@ at], NoAction

    | Label (n, es0, code'), vs ->
      let (t', act) = step_thread {t with code = code'} in
      vs, [Label (n, es0, t'.code) @@ e.at], act

    | Frame (n, frame', (vs', [])), vs ->
      vs' @ vs, [], NoAction

    | Frame (n, frame', (vs', {it = Trapping msg; at} :: es')), vs ->
      vs, [Trapping msg @@ at], NoAction

    | Frame (n, frame', (vs', {it = Returning vs0; at} :: es')), vs ->
      take n vs0 e.at @ vs, [], NoAction

    | Frame (n, frame', code'), vs ->
      let (t', act) = step_thread {frame = frame'; code = code'; budget = t.budget - 1} in
      vs, [Frame (n, t'.frame, t'.code) @@ e.at], act

    | Invoke func, vs when t.budget = 0 ->
      Exhaustion.error e.at "call stack exhausted"

    | Invoke func, vs ->
      let FuncType (ins, out) = func_type_of func in
      let n1, n2 = Lib.List32.length ins, Lib.List32.length out in
      let args, vs' = take n1 vs e.at, drop n1 vs e.at in
      (match func with
      | Func.AstFunc (t, inst', f) ->
        let locals' = List.rev args @ List.map default_value f.it.locals in
        let frame' = {inst = !inst'; locals = List.map ref locals'} in
        let instr' = [Label (n2, [], ([], List.map plain f.it.body)) @@ f.at] in
        vs', [Frame (n2, frame', ([], instr')) @@ e.at], NoAction

      | Func.HostFunc (t, f) ->
        try List.rev (f (List.rev args)) @ vs', [], NoAction
        with Crash (_, msg) -> Crash.error e.at msg
      )
    | Suspend _, vs ->
      (* TODO: meaningful timestamp handling *)
      vs, [e], NoAction
  in {t with code = vs', es' @ List.tl es}, act


let rec plug_value (c : code) (v : value) : code =
  let vs, es = c in
  match es with
  | {it = Label (n, es0, c'); at} :: es' ->
    vs, {it = Label (n, es0, plug_value c' v); at} :: es'
  | {it = Frame (n, f, c'); at} :: es' ->
    vs, {it = Frame (n, f, plug_value c' v); at} :: es'
  | _ ->
    v :: vs, es

let rec try_unsuspend (c : code) (m : memory_inst) (addr : Memory.address) : code option =
  let vs, es = c in
  match es with
  | {it = Label (n, es0, c'); at} :: es' ->
    Lib.Option.map (fun c'' -> vs, {it = Label (n, es0, c''); at} :: es') (try_unsuspend c' m addr)
  | {it = Frame (n, f, c'); at} :: es' ->
    Lib.Option.map (fun c'' -> vs, {it = Frame (n, f, c''); at} :: es') (try_unsuspend c' m addr)
  | {it = Suspend (m', addr', timeout); at} :: es' ->
    if m == m' && addr = addr' then
      Some (Num (I32 0l) :: vs, es')
    else
      None
  | _ ->
    None

let rec wake (c : config) (m : memory_inst) (addr : Memory.address) (count : int32) : config * int32 =
  if count = 0l then
    c, 0l
  else
    match c with
    | [] ->
      c, 0l
    | t :: ts ->
      let t', count' = match (try_unsuspend t.code m addr) with | None -> t, 0l | Some c' -> {t with code = c'}, 1l in
      let ts', count'' = wake ts m addr (Int32.sub count count') in
      t' :: ts', Int32.add count' count''

let rec step (c : config) (n : thread_id) : config =
  let ts1, t, ts2 = Lib.List.extract n c in
  if snd t.code = [] then
    step c n
  else
    let t', act = try step_thread t with Stack_overflow ->
      Exhaustion.error (List.hd (snd t.code)).at "call stack exhausted"
    in
    match act with
    | NotifyAction (m, addr, count) ->
      let ts1', count1 = wake ts1 m addr count in
      let ts2', count2 = wake ts2 m addr (Int32.sub count count1) in
      ts1' @ [{t' with code = plug_value t'.code (Num (I32 (Int32.add count1 count2)))}] @ ts2'
    | _ -> ts1 @ [t'] @ ts2

let rec eval (c : config ref) (n : thread_id) : value list =
  match status !c n with
  | Result vs -> vs
  | Trap e -> raise e
  | Running ->
    let c' = step !c n in
    c := c'; eval c n


(* Functions & Constants *)

let invoke c n (func : func_inst) (vs : value list) : config =
  let at = match func with Func.AstFunc (_,_, f) -> f.at | _ -> no_region in
  let FuncType (ins, out) = Func.type_of func in
  if List.map Values.type_of_value vs <> ins then
    Crash.error at "wrong number or types of arguments";
  let ts1, t, ts2 = Lib.List.extract n c in
  let vs', es' = t.code in
  let code = List.rev vs @ vs', (Invoke func @@ at) :: es' in
  ts1 @ [{t with code}] @ ts2

let eval_const (inst : module_inst) (const : const) : value =
  let t = thread inst [] (List.map plain const.it) in
  match eval (ref [t]) 0 with
  | [v] -> v
  | _ -> Crash.error const.at "wrong number of results on stack"

(* Modules *)

let create_func (inst : module_inst) (f : func) : func_inst =
  Func.alloc (type_ inst f.it.ftype) (ref inst) f

let create_table (inst : module_inst) (tab : table) : table_inst =
  let {ttype} = tab.it in
  let TableType (_lim, t) = ttype in
  Table.alloc ttype (NullRef t)

let create_memory (inst : module_inst) (mem : memory) : memory_inst =
  let {mtype} = mem.it in
  Memory.alloc mtype

let create_global (inst : module_inst) (glob : global) : global_inst =
  let {gtype; ginit} = glob.it in
  let v = eval_const inst ginit in
  Global.alloc gtype v

let create_export (inst : module_inst) (ex : export) : export_inst =
  let {name; edesc} = ex.it in
  let ext =
    match edesc.it with
    | FuncExport x -> ExternFunc (func inst x)
    | TableExport x -> ExternTable (table inst x)
    | MemoryExport x -> ExternMemory (memory inst x)
    | GlobalExport x -> ExternGlobal (global inst x)
  in (name, ext)

let create_elem (inst : module_inst) (seg : elem_segment) : elem_inst =
  let {etype; einit; _} = seg.it in
  Elem.alloc (List.map (fun c -> as_ref (eval_const inst c)) einit)

let create_data (inst : module_inst) (seg : data_segment) : data_inst =
  let {dinit; _} = seg.it in
  Data.alloc dinit

let add_import (m : module_) (ext : extern) (im : import) (inst : module_inst)
  : module_inst =
  if not (match_extern_type (extern_type_of ext) (import_type m im)) then
    Link.error im.at ("incompatible import type for " ^
      "\"" ^ Utf8.encode im.it.module_name ^ "\" " ^
      "\"" ^ Utf8.encode im.it.item_name ^ "\": " ^
      "expected " ^ Types.string_of_extern_type (import_type m im) ^
      ", got " ^ Types.string_of_extern_type (extern_type_of ext));
  match ext with
  | ExternFunc func -> {inst with funcs = func :: inst.funcs}
  | ExternTable tab -> {inst with tables = tab :: inst.tables}
  | ExternMemory mem -> {inst with memories = mem :: inst.memories}
  | ExternGlobal glob -> {inst with globals = glob :: inst.globals}

let init_func (inst : module_inst) (func : func_inst) =
  match func with
  | Func.AstFunc (_, inst_ref, _) -> inst_ref := inst
  | _ -> assert false

let run_elem i elem =
  let at = elem.it.emode.at in
  let x = i @@ at in
  match elem.it.emode.it with
  | Passive -> []
  | Active {index; offset} ->
    offset.it @ [
      Const (I32 0l @@ at) @@ at;
      Const (I32 (Lib.List32.length elem.it.einit) @@ at) @@ at;
      TableInit (index, x) @@ at;
      ElemDrop x @@ at
    ]
  | Declarative ->
    [ElemDrop x @@ at]

let run_data i data =
  let at = data.it.dmode.at in
  let x = i @@ at in
  match data.it.dmode.it with
  | Passive -> []
  | Active {index; offset} ->
    assert (index.it = 0l);
    offset.it @ [
      Const (I32 0l @@ at) @@ at;
      Const (I32 (Int32.of_int (String.length data.it.dinit)) @@ at) @@ at;
      MemoryInit x @@ at;
      DataDrop x @@ at
    ]
  | Declarative -> assert false

let run_start start =
  [Call start.it.sfunc @@ start.at]

let init c n (m : module_) (exts : extern list) : module_inst * config =
  let
    { imports; tables; memories; globals; funcs; types;
      exports; elems; datas; start
    } = m.it
  in
  if List.length exts <> List.length imports then
    Link.error m.at "wrong number of imports provided for initialisation";
  let inst0 =
    { (List.fold_right2 (add_import m) exts imports empty_module_inst) with
      types = List.map (fun type_ -> type_.it) types }
  in
  let fs = List.map (create_func inst0) funcs in
  let inst1 = {inst0 with funcs = inst0.funcs @ fs} in
  let inst2 =
    { inst1 with
      tables = inst1.tables @ List.map (create_table inst1) tables;
      memories = inst1.memories @ List.map (create_memory inst1) memories;
      globals = inst1.globals @ List.map (create_global inst1) globals;
    }
  in
  let inst =
    { inst2 with
      exports = List.map (create_export inst2) exports;
      elems = List.map (create_elem inst2) elems;
      datas = List.map (create_data inst2) datas;
    }
  in
  List.iter (init_func inst) fs;
  let es_elem = List.concat (Lib.List32.mapi run_elem elems) in
  let es_data = List.concat (Lib.List32.mapi run_data datas) in
  let es_start = Lib.Option.get (Lib.Option.map run_start start) [] in
  let ts1, t, ts2 = Lib.List.extract n c in
  let vs', es' = t.code in
  let code = vs', (List.map plain (es_elem @ es_data @ es_start)) @ es' in
  let c' = ts1 @ [{t with code}] @ ts2 in
  inst, c'
