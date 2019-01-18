(* -------------------------------------------------------------------------- *
 *                     Vellvm - the Verified LLVM project                     *
 *                                                                            *
 *     Copyright (c) 2017 Steve Zdancewic <stevez@cis.upenn.edu>              *
 *                                                                            *
 *   This file is distributed under the terms of the GNU General Public       *
 *   License as published by the Free Software Foundation, either version     *
 *   3 of the License, or (at your option) any later version.                 *
 ---------------------------------------------------------------------------- *)


module DV = TopLevel.IO.DV

let print_int_dvalue dv : unit =
  match dv with
  | DV.DVALUE_I1 (x) -> Printf.printf "Program terminated with: DVALUE_I1(%d)\n" (Camlcoq.Z.to_int (DynamicValues.Int1.unsigned x))
  | DV.DVALUE_I8 (x) -> Printf.printf "Program terminated with: DVALUE_I8(%d)\n" (Camlcoq.Z.to_int (DynamicValues.Int8.unsigned x))
  | DV.DVALUE_I32 (x) -> Printf.printf "Program terminated with: DVALUE_I32(%d)\n" (Camlcoq.Z.to_int (DynamicValues.Int32.unsigned x))
  | DV.DVALUE_I64 (x) -> Printf.printf "Program terminated with: DVALUE_I64(%d) [possible precision loss: converted to OCaml int]\n"
                       (Camlcoq.Z.to_int (DynamicValues.Int64.unsigned x))
  | _ -> Printf.printf "Program terminated with non-Integer value.\n"

let rec step m =
  match Core.observe m with
  | Core.TauF x -> step x
  | Core.RetF v -> v
  | Core.VisF (OpenSum.Coq_inrE s, _) -> failwith (Printf.sprintf "ERROR: %s" (Camlcoq.camlstring_of_coqstring s))
  | Core.VisF (OpenSum.Coq_inlE e, k) ->
    begin match Obj.magic e with
      | TopLevel.IO.Call(_, f, _) ->
        (Printf.printf "UNINTERPRETED EXTERNAL CALL: %s - returning 0l to the caller\n" (Camlcoq.camlstring_of_coqstring f));
        step (k (Obj.magic (DV.DVALUE_I64 DynamicValues.Int64.zero)))
      | TopLevel.IO.GEP(_, _, _) -> failwith "GEP failed"
      | _ -> failwith "should have been handled by the memory model"  
    end
      

let interpret (prog:(LLVMAst.block list) LLVMAst.toplevel_entity list) = 
  match TopLevel.run_with_memory prog with
  | None -> failwith "bad module"
  | Some t -> step t
  
