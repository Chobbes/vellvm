(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2017 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)

Require Import ZArith List String Omega.
Require Import  Vellvm.Classes Vellvm.Util.
Require Import Vellvm.Ollvm_ast Vellvm.AstLib Vellvm.CFG.
Import ListNotations.

Require Import compcert.lib.Integers.

Open Scope Z_scope.
Open Scope string_scope.

Set Implicit Arguments.
Set Contextual Implicit.

Require Import Vellvm.Effects.

Module Type ADDR.
  Parameter addr : Set.
End ADDR.  


Module Wordsize1.
  Definition wordsize := 1%nat.
  Remark wordsize_not_zero: wordsize <> 0%nat.
  Proof. unfold wordsize; congruence. Qed.
End Wordsize1.

Module Int64 := Integers.Int64.
Module Int32 := Integers.Int.
Module Int1 := Make(Wordsize1).

Definition int1 := Int1.int.
Definition int32 := Int32.int.
Definition int64 := Int64.int.

Definition inttyp (x:Z) : Type :=
  match x with
  | 1 => int1
  | 32 => int32
  | 64 => int64
  | _ => False
  end.

Module StepSemantics(A:ADDR).

  (* The set of dynamic values manipulated by an LLVM program. This
   datatype uses the "Expr" functor from the Ollvm_ast definition,
   injecting new base values.  This allows the semantics to do
   'symbolic' execution for things that we don't have a way of
   interpreting concretely (e.g. undef).  *)
    Inductive dvalue : Set :=
    | DV : Expr dvalue -> dvalue
    | DVALUE_CodePointer (p : pc)
    | DVALUE_Addr (a:A.addr)
    | DVALUE_I1 (x:int1)
    | DVALUE_I32 (x:int32)
    | DVALUE_I64 (x:int64)
    | DVALUE_Poison
    .
  
    Module ET : Vellvm.Effects.EffT
        with Definition addr := A.addr
        with Definition typ := Ollvm_ast.typ
        with Definition value := dvalue.

      Definition addr := A.addr.
      Definition typ := Ollvm_ast.typ.
      Definition value := dvalue.
      Definition inj_addr := DVALUE_Addr.
    
    End ET.    
  Module E := Vellvm.Effects.Effects(ET).
  Export E.

  (* TODO: add the global environment *)
  Definition genv := list (global_id * value).
  Definition env  := list (local_id * value).

  Inductive frame : Set :=
  | KRet      (e:env) (id:local_id) (q:pc)
  | KRet_void (e:env) (q:pc)
  .       
  
  Definition stack := list frame.
  Definition state := (pc * env * stack)%type.

  Definition def_id_of_pc (p:pc) : err local_id :=
    match ins p with
    | IId id => mret id
    | _ => failwith ("def_id_of_pc: " ++ (string_of p))
    end.

  Definition local_id_of_ident (i:ident) : err local_id :=
    match i with
    | ID_Global _ => failwith ("local_id_of_ident: " ++ string_of i)
    | ID_Local i => mret i
    end.

  Fixpoint string_of_env' (e:env) : string :=
    match e with
    | [] => ""
    | (lid, _)::rest => (string_of_raw_id lid) ++ " " ++ (string_of_env' rest)
    end.

  Instance string_of_env : StringOf env := string_of_env'.
  
  Definition lookup_env (e:env) (id:local_id) : err value :=
    trywith ("lookup_env: id = " ++ (string_of id) ++ " NOT IN env = " ++ (string_of e)) (assoc RawID.eq_dec id e).

  (* Arithmetic Operations ---------------------------------------------------- *)
  (* TODO: implement LLVM semantics *)


  (* Since modules are not first class, this code duplication
     will probably have to do. *)
  Definition eval_i1_op (iop:ibinop) (x y:inttyp 1) : value:=
    DVALUE_I1
      match iop with
      | Add _ _ => Int1.add x y
      | Sub _ _ => Int1.sub x y
      | Mul _ _ => Int1.mul x y
      | Shl _ _ => Int1.shl x y
      | UDiv _ => Int1.divu x y
      | SDiv _ => Int1.divs x y
      | LShr _ => Int1.shl x y
      | AShr _ => Int1.shr x y
      | URem => Int1.modu x y
      | SRem => Int1.mods x y
      | And => Int1.and x y
      | Or => Int1.or x y
      | Xor => Int1.xor x y
      end.

  Definition eval_i32_op (iop:ibinop) (x y:inttyp 32) : value:=
    DVALUE_I32
      match iop with
      | Add _ _ => Int32.add x y
      | Sub _ _ => Int32.sub x y
      | Mul _ _ => Int32.mul x y
      | Shl _ _ => Int32.shl x y
      | UDiv _ => Int32.divu x y
      | SDiv _ => Int32.divs x y
      | LShr _ => Int32.shl x y
      | AShr _ => Int32.shr x y
      | URem => Int32.modu x y
      | SRem => Int32.mods x y
      | And => Int32.and x y
      | Or => Int32.or x y
      | Xor => Int32.xor x y
      end.

  Definition eval_i64_op (iop:ibinop) (x y:inttyp 64) : value:=
    (* This needs to be tested *)
    match iop with
    | Add nuw nsw =>
      if orb (andb nuw (Int64.eq (Int64.add_carry x y Int64.zero) Int64.one))
             (andb nsw (Int64.eq (Int64.add_overflow x y Int64.zero) Int64.one))
      then DVALUE_Poison else DVALUE_I64 (Int64.add x y)
    | Sub nuw nsw =>
      if orb (andb nuw (Int64.eq (Int64.sub_borrow x y Int64.zero) Int64.one))
             (andb nsw (Int64.eq (Int64.sub_overflow x y Int64.zero) Int64.one))
      then DVALUE_Poison else DVALUE_I64 (Int64.sub x y)
    | Mul nuw nsw =>
      let res := Int64.mul x y in
      let res_s' := (Int64.signed x) * (Int64.signed y) in
      if orb (andb nuw ((Int64.unsigned x) * (Int64.unsigned y) >?
                      Int64.unsigned res))
             (andb nsw (orb (Int64.min_signed >? res_s')
                            (res_s' >? Int64.max_signed)))
      then DVALUE_Poison else DVALUE_I64 res
    | Shl nuw nsw =>
      let res := Int64.shl x y in
      let res_u := Int64.unsigned res in
      let res_u' := Z.shiftl (Int64.unsigned x) (Int64.unsigned y) in
      (* Need to verify this method for checking overflow. Take sign bit.
         Unsigned shift x right by 64 - y. If shifted x != sign bit * (2^y - 1),
         then there is overflow. 
         Alternative: adapt alg on p 99 of hackers 
         delight for counting 1s rather than 0s (should just be flipping
         bits and shifting right rather than left) *)
      if (Int64.unsigned y) >=? 64 then DV (VALUE_Undef) 
      else if orb (andb nuw (res_u' >? res_u))
                  (andb nsw (negb (Z.shiftr (Int64.unsigned x)
                                            (64 - Int64.unsigned y)
                                   =? (Int64.unsigned (Int64.negative x))
                                      * (Z.pow 2 (Int64.unsigned y) - 1))))
      then DVALUE_Poison else DVALUE_I64 res
    | UDiv ex =>
      if andb ex (negb ((Int64.unsigned x) mod (Int64.unsigned y) =? 0))
      then DVALUE_Poison else DVALUE_I64 (Int64.divu x y)
    | SDiv ex =>
      if andb ex (negb (((Int64.signed x) mod (Int64.signed y)) =? 0))
      then DVALUE_Poison else DVALUE_I64 (Int64.divs x y)
    | LShr ex =>
      if (Int64.unsigned y) >=? 64 then DV (VALUE_Undef)
      else if andb ex (negb ((Int64.unsigned x)
                               mod (Z.pow 2 (Int64.unsigned y)) =? 0))
      then DVALUE_Poison else DVALUE_I64 (Int64.shru x y)
    | AShr ex =>
      if (Int64.unsigned y) >=? 64 then DV (VALUE_Undef)
      else if andb ex (negb ((Int64.unsigned x)
                               mod (Z.pow 2 (Int64.unsigned y)) =? 0))
      then DVALUE_Poison else DVALUE_I64 (Int64.shr x y)
    | URem =>
      DVALUE_I64 (Int64.modu x y)
    | SRem =>
      DVALUE_I64 (Int64.mods x y)
    | And =>
      DVALUE_I64 (Int64.and x y)
    | Or =>
      DVALUE_I64 (Int64.or x y)
    | Xor =>
      DVALUE_I64 (Int64.xor x y)
    end.

  (* Evaluate the given iop on the given arguments according to the bitsize *)
  Definition integer_op (bits:Z) (iop:ibinop) (x y:inttyp bits) : err value:=
    match bits, x, y with
    | 1, x, y => mret (eval_i1_op iop x y)
    | 32, x, y => mret (eval_i32_op iop x y)
    | 64, x, y => mret (eval_i64_op iop x y)
    | _, _, _ => failwith "unsupported bitsize"
    end.

  (* Convert written integer constant to corresponding integer with bitsize bits.
     Takes the integer modulo 2^bits. *)
  Definition coerce_integer_to_int (bits:Z) (i:Z) : err (inttyp bits) :=
    match bits with
    | 1 => mret (Int1.repr i) 
    | 32 => mret (Int32.repr i)
    | 64 => mret (Int64.repr i)
    | _ => failwith "unsupported integer size"
    end.
        
  Definition eval_iop t iop v1 v2 : err value :=
    match t, v1, v2 with
    | TYPE_I bits, DV (VALUE_Integer i1), DV (VALUE_Integer i2) =>
      'v1 <- coerce_integer_to_int bits i1;
      'v2 <- coerce_integer_to_int bits i2;
      integer_op bits iop v1 v2
    | TYPE_I 1, DVALUE_I1 i1, DVALUE_I1 i2 => integer_op 1 iop i1 i2
    | TYPE_I 32, DVALUE_I32 i1, DVALUE_I32 i2 => integer_op 32 iop i1 i2
    | TYPE_I 64, DVALUE_I64 i1, DVALUE_I64 i2 => integer_op 64 iop i1 i2
    | _, _, _ => failwith "ill_typed"
    end.

  (* TODO: replace Coq Z with appropriate i64, i32, i1 values *)
  Definition eval_icmp icmp v1 v2 : err value :=
    match v1, v2 with
    | DV (VALUE_Integer i1), DV (VALUE_Integer i2) =>
      mret (DV (VALUE_Bool 
                           match icmp with
                           | Eq => Z.eqb i1 i2
                           | Ne => negb (Z.eqb i1 i2)
                           | Ugt => Z.gtb i1 i2
                           | Uge => Z.leb i2 i1
                           | Ult => Z.gtb i2 i1
                           | Ule => Z.leb i1 i2
                           | Sgt => Z.gtb i1 i2
                           | Sge => Z.leb i2 i1
                           | Slt => Z.ltb i1 i2
                           | Sle => Z.leb i1 i2
                           end))
    | _, _ => failwith "eval_icmp"
    end.

  Definition eval_fop (fop:fbinop) (v1:value) (v2:value) : err value := failwith "eval_fop not implemented".

  Definition eval_fcmp (fcmp:fcmp) (v1:value) (v2:value) : err value := failwith "eval_fcmp not implemented".

Definition eval_expr {A:Set} (f:env -> A -> err value) (e:env) (o:Expr A) : err value :=
  match o with
  | VALUE_Ident id => 
    'i <- local_id_of_ident id;
      lookup_env e i
  | VALUE_Integer x => mret (DV (VALUE_Integer x))
  | VALUE_Float x   => mret (DV (VALUE_Float x))
  | VALUE_Bool b    => mret (DV (VALUE_Bool b)) 
  | VALUE_Null      => mret (DV (VALUE_Null))
  | VALUE_Zero_initializer => mret (DV (VALUE_Zero_initializer))
  | VALUE_Cstring s => mret (DV (VALUE_Cstring s))
  | VALUE_None      => mret (DV (VALUE_None))
  | VALUE_Undef     => mret (DV (VALUE_Undef))

  | VALUE_Struct es =>
    'vs <- map_monad (monad_app_snd (f e)) es;
     mret (DV (VALUE_Struct vs))

  | VALUE_Packed_struct es =>
    'vs <- map_monad (monad_app_snd (f e)) es;
     mret (DV (VALUE_Packed_struct vs))
    
  | VALUE_Array es =>
    'vs <- map_monad (monad_app_snd (f e)) es;
     mret (DV (VALUE_Array vs))
    
  | VALUE_Vector es =>
    'vs <- map_monad (monad_app_snd (f e)) es;
     mret (DV (VALUE_Vector vs))

  | OP_IBinop iop t op1 op2 =>
    'v1 <- f e op1;
    'v2 <- f e op2;
    (eval_iop t iop) v1 v2

  | OP_ICmp cmp t op1 op2 => 
    'v1 <- f e op1;                   
    'v2 <- f e op2;
    (eval_icmp cmp) v1 v2

  | OP_FBinop fop fm t op1 op2 =>
    'v1 <- f e op1;
    'v2 <- f e op2;
    (eval_fop fop) v1 v2

  | OP_FCmp fcmp t op1 op2 => 
    'v1 <- f e op1;
    'v2 <- f e op2;
    (eval_fcmp fcmp) v1 v2
              
  | OP_Conversion conv t1 op t2 =>
    f e op    (* TODO: is conversion a no-op semantically? *)
      
  | OP_GetElementPtr t ptrval idxs =>
    'vptr <- monad_app_snd (f e) ptrval;
    'vs <- map_monad (monad_app_snd (f e)) idxs;
    failwith "getelementptr not implemented"  (* TODO: Getelementptr *)  
    
  | OP_ExtractElement vecop idx =>
    'vec <- monad_app_snd (f e) vecop;
    'vidx <- monad_app_snd (f e) idx;
    failwith "extractelement not implemented" (* TODO: Extract Element *)
      
  | OP_InsertElement vecop eltop idx =>
    'vec <- monad_app_snd (f e) vecop;
    'v <- monad_app_snd (f e) eltop;
    'vidx <- monad_app_snd (f e) idx;
    failwith "insertelement not implemented" (* TODO *)
    
  | OP_ShuffleVector vecop1 vecop2 idxmask =>
    'vec1 <- monad_app_snd (f e) vecop1;
    'vec2 <- monad_app_snd (f e) vecop2;      
    'vidx <- monad_app_snd (f e) idxmask;
    failwith "shufflevector not implemented" (* TODO *)

  | OP_ExtractValue vecop idxs =>
    'vec <- monad_app_snd (f e) vecop;
    failwith "extractvalue not implemented"
        
  | OP_InsertValue vecop eltop idxs =>
    'vec <- monad_app_snd (f e) vecop;
    'v <- monad_app_snd (f e) eltop;
    failwith "insertvalue not implemented"
    
  | OP_Select cndop op1 op2 =>
    'cnd <- monad_app_snd (f e) cndop;
    'v1 <- monad_app_snd (f e) op1;
    'v2 <- monad_app_snd (f e) op2;      
    failwith "select not implemented"
  end.

Fixpoint eval_op (e:env) (o:Ollvm_ast.value) : err value :=
  match o with
  | SV o' => eval_expr eval_op e o'
  end.

(* Semantically, a jump at the LLVM IR level might not be "atomic" in the sense that
   Phi nodes may be lowered into a sequence of non-atomic operations on registers.  However,
   Phi's should never touch memory [is that true? can there be spills?], so modeling them
   as atomic should be OK. *)
Fixpoint jump (CFG:cfg) (bn:block_id) (e_init:env) (e:env) ps (q:pc) (k:stack) : err state :=
  match ps with
  | [] => mret (q, e, k)
  | (id, (INSTR_Phi _ ls))::rest => 
    match assoc RawID.eq_dec bn ls with
    | Some op =>
      'dv <- eval_op e_init op;
      jump CFG bn e_init ((id,dv)::e) rest q k
    | None => failwith ("jump: block name not found " ++ string_of_raw_id bn)
    end
  | _ => failwith "jump: got non-phi instruction"
  end.

Definition raise s p : (Obs state) :=
  Err (s ++ ": " ++ (string_of_pc p)).

Definition lift_err_d {A B} (m:err A) (f: A -> Obs B) : Obs B :=
  match m with
    | inl s => Err s
    | inr b => f b
  end.

Notation "'do' x <- m ; f" := (lift_err_d m (fun x => f)) 
   (at level 200, x ident, m at level 100, f at level 200).

Fixpoint stepD (CFG:mcfg) (s:state) : Obs state :=
  let '(p, e, k) := s in
  let pc_of_pt pt := mk_pc (fn p) pt in
  do cmd <- trywith ("stepD: no cmd at pc " ++ (string_of p)) (fetch CFG p);
    match cmd with
    | Step (INSTR_Op op) p' =>
      do id <- def_id_of_pc p; 
      do dv <- eval_op e op;     
       Ret (pc_of_pt p', (id, dv)::e, k)

    (* NOTE : this doesn't yet correctly handle external calls or function pointers *)
    | Step (INSTR_Call (ret_ty,ID_Global f) args) p' =>
      do id <- def_id_of_pc p; 
      do fdef <- trywith ("stepD: no function " ++ (string_of f)) (find_function CFG f);
      let ids := (df_args fdef) in  
      let cfg := df_instrs fdef in
      do dvs <-  map_monad (eval_op e) (map snd args);
      Ret (mk_pc f (init cfg), combine ids dvs, 
          match ret_ty with
          | TYPE_Void => (KRet_void e (pc_of_pt p'))::k
          | _ =>         (KRet e id (pc_of_pt p'))::k
          end)

    | Step (INSTR_Call (_, ID_Local _) _) _ => raise "INSTR_Call to local" p
        
    | Step (INSTR_Unreachable) _ => raise "IMPOSSIBLE: unreachable" p
                                                       
    | Jump _ (TERM_Ret (t, op)) =>
      do dv <- eval_op e op;
      match k with
      | [] => Fin dv
      | (KRet e' id p') :: k' => Ret (p', (id, dv)::e', k')
      | _ => raise "IMPOSSIBLE: Ret op in non-return configuration" p
      end

    | Jump _ (TERM_Ret_void) =>
      match k with
      | [] => Fin (DV (VALUE_Bool true))
      | (KRet_void e' p')::k' => Ret (p', e', k')
      | _ => raise "IMPOSSIBLE: Ret void in non-return configuration" p
      end
        
    | Jump current_block (TERM_Br (_,op) br1 br2) =>
      do dv <- eval_op e op;
      do br <- match dv with 
               | DV (VALUE_Bool true) => mret br1
               | DV (VALUE_Bool false) => mret br2
               | _ => failwith "Br got non-bool value"
      end;
      do fdef <- trywith ("stepD: no function " ++ (string_of (fn p))) (find_function CFG (fn p));
      let cfg := (df_instrs fdef) in
      match (phis cfg br) with
      | Some (Phis _ ps q) => 
        lift_err_d (jump cfg current_block e e ps (pc_of_pt q) k) (@Ret state)
      | None => raise ("ERROR: Br " ++ (string_of br) ++ " not found") p
      end
        
    | Jump current_block (TERM_Br_1 br) =>
      do fdef <- trywith ("stepD: no function " ++ (string_of (fn p))) (find_function CFG (fn p));
      let cfg := (df_instrs fdef) in
        match (phis cfg br) with
          | Some (Phis _ ps q) => 
            lift_err_d (jump cfg current_block e e ps (pc_of_pt q) k) (@Ret state)
          | None => raise ("ERROR: Br1  " ++ (string_of br) ++ " not found") p
        end
      
    | Step (INSTR_Alloca t _ _) p' =>
      do id <- def_id_of_pc p;  
      Eff (Alloca t (fun (a:value) => Ret (pc_of_pt p', (id, a)::e, k)))
      
    | Step (INSTR_Load _ t (_,ptr) _) p' =>
      do id <- def_id_of_pc p;  
      do dv <- eval_op e ptr;     
      match dv with
      | DVALUE_Addr a => Eff (Load a (fun dv => Ret (pc_of_pt p', (id, dv)::e, k))) 
      | _ => raise "ERROR: Load got non-pointer value" p
      end

      
    | Step (INSTR_Store _ (_, val) (_, ptr) _) p' => 
      do dv <- eval_op e val;
      do v <- eval_op e ptr;
      match v with 
      | DVALUE_Addr a => Eff (Store a dv (Ret (pc_of_pt p', e, k)))
      |  _ => raise "ERROR: Store got non-pointer value" p
      end

    | Step (INSTR_Phi _ _) p' => Err "IMPOSSIBLE: Phi encountered in step"
      (* We should never evaluate Phi nodes except in jump *)

    (* Currently unhandled LLVM instructions *)
    | Step INSTR_Fence p'
    | Step INSTR_AtomicCmpXchg p'
    | Step INSTR_AtomicRMW p'
    | Step INSTR_VAArg p'
    | Step INSTR_LandingPad p' => raise "Unsupported LLVM intsruction" p
 
    (* Currently unhandled LLVM terminators *)                                  
    | Jump _ (TERM_Switch _ _ _)
    | Jump _ (TERM_IndirectBr _ _)
    | Jump _ (TERM_Resume _)
    | Jump _ (TERM_Invoke _ _ _ _) => raise "Unsupport LLVM terminator" p
    end.

Inductive Empty := .

(* Assumes that the entry-point function is named "fn" and that it takes
   no parameters *)
Definition init_state (CFG:mcfg) (fn:string) : err state :=
  'fdef <- trywith ("stepD: no main function ") (find_function CFG (Name fn));
    let cfg := df_instrs fdef in
    mret ((mk_pc (Name fn) (init cfg)), [], []).

(* Note: codomain is D'  *)
CoFixpoint sem (CFG:mcfg) (s:state) : (Obs Empty) :=
  bind (stepD CFG s) (sem CFG).

End StepSemantics.