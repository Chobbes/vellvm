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
Require Import Program Classical.
Require Import paco.
Import ListNotations.

Set Implicit Arguments.
Set Contextual Implicit.

Module Type EffT.
  (* The effects interface is parameterized by the language's types and the 
   memory model's notion of addresses. *)
  Parameter typ : Set.
  Parameter addr : Set.
  Parameter value : Set.
  Parameter inj_addr: addr -> value.
End EffT.

Module Effects(ET:EffT).
Export ET.


(* TODO: Add other memory effects, such as synchronization operations *)
(* Notes: 
   - To allow the memory model to correctly model stack alloca deallocation,
     we would also have to expose the "Ret" instruction. 

   - What is the correct way to model global data? 
*)
Inductive effects (d:Type) : Type :=
| Alloca (t:typ)  (k:value -> d)        (* Stack allocation *)
| Load   (a:addr) (k:value -> d)
| Store  (a:addr) (v:value) (k:d)
| Call   (v:value) (args:list value) (k:value -> d)
.    

Definition effects_map {A B} (f:A -> B) (m:effects A) : effects B :=
  match m with
  | Alloca t g => Alloca t (fun a => f (g a))
  | Load a g  => Load a (fun dv => f (g dv))
  | Store a dv d => Store a dv (f d)
  | Call v args d => Call v args (fun dv => f (d dv))
  end.

Instance effects_functor : Functor effects := fun A => fun B => @effects_map A B.
Program Instance effects_functor_eq_laws : (@FunctorLaws effects) effects_functor (@eq).
Next Obligation.
  unfold fmap. unfold effects_functor. unfold effects_map. destruct a; reflexivity.
Defined.
Next Obligation.
  unfold fmap. unfold effects_functor. unfold effects_map. destruct a; reflexivity.
Defined.  

Inductive Event X :=
| Fin : value -> Event X
| Err : string -> Event X
| Eff : effects X -> Event X
.

Definition event_map {A B} (f:A -> B) (e:Event A) : Event B :=
  match e with
  | Fin v => Fin v
  | Err s => Err s
  | Eff m => Eff (f <$> m)
  end.

Instance event_functor : Functor Event := fun A B => @event_map A B.
Program Instance event_functor_eq_laws : (@FunctorLaws Event) event_functor (@eq).
Next Obligation.
  unfold fmap. unfold event_functor. destruct a; simpl; auto. rewrite fmap_id. reflexivity.
Defined.
Next Obligation.
  unfold fmap. unfold event_functor. unfold event_map. destruct a; auto. rewrite fmap_comp. reflexivity.
Defined.  


(* Observations of a computation generated by state X. *)
CoInductive Obs :=
| Vis (v : Event Obs)
| Tau (k : Obs)
.

(*
CoInductive Obs X :=
| Ret : X -> Obs X        (* Unfinished trace *)
| Fin : value -> Obs X    (* Finished trace *) 
| Err : string -> Obs X   (* Abort with an error *)
| Tau : Obs X -> Obs X    (* Internal step of computation *)
| Eff : effects X -> Obs X    (* Externally visible step of computation *)
.
*)
(*
CoFixpoint obs_map {A B} (f:A -> B) (d:Obs A) : Obs B :=
  match d with
(*  | Ret s => Ret (f s) *)
  | Vis v => Vis ((obs_map f) <$> v)
  | Tau k => Tau (obs_map f k)
  end.

Instance Obs_functor : @Functor Obs := fun A => fun B => @obs_map A B.
(* A functor only up to stuttering equivalence. *)
(*
Program Instance OBS_functor_eq_laws : (@FunctorLaws D) OBS_functor (@obs_equiv).
*)
*)
Definition id_match_obs (d:Obs) : Obs :=
  match d with
(*  | Ret s => Ret s *)
  | Vis v => Vis v
  | Tau k => Tau k
  end.

Lemma id_obs_eq : forall (d:Obs),
  d = id_match_obs d.
Proof.
  destruct d; auto.
Qed.


Definition non_tau (d:Obs) : Prop :=
  match d with
  | Tau _ => False
  | _ => True
  end.

Definition tau (d:Obs) : Prop :=
  match d with
  | Tau _ => True
  | _ => False
  end.

(* Define a predicate that holds only of infinite Tau observations a.k.a. silent divergence *)
Inductive diverges_step (div : Obs -> Prop) : Obs -> Prop :=
| div_tau : forall d, div d -> diverges_step div (Tau d)
.
Hint Constructors diverges_step.

Lemma diverges_step_mono : monotone1 diverges_step.
Proof.
  pmonauto.
Qed.
Hint Resolve diverges_step_mono : paco.

Definition diverges := paco1 diverges_step bot1.
Hint Unfold diverges.

(* observational equivalence ------------------------------------------------ *)

Section RELATED_EFFECTS.
  Variable X : Type.
  Variable R : X -> X -> Prop.

  
  (*
  This relation doesn't allow any variation in the relations for the memory model.  
  A more parametric version would:
    - Replace the use of '=' in the definition of obs_equiv_effect_step with 
      a state relation on states: RA : A -> A -> Prop
    - have an address relation   RAddr : addr -> addr -> Prop  
    - have a value relation     RValue : value -> value -> Prop
  It builds in the "total" relation for error string observations:
     Err s1 ~~ Err s2   for any s1, s2     
     ( Could pass in E : string -> string -> Prop )

  In order for the theory to make sense, we probly would also want to have:
    RA a1 a2 <-> R (Ret a1) (Ret a2)
    RAddr a1 a2 <->  RValue (inj_addr a1) (inj_addr a2)
  *)
  
  Inductive related_effect_step  : effects X -> effects X -> Prop :=
  | related_effect_Alloca :
      forall t k1 k2
        (HRk : forall (a1 a2:addr), a1 = a2 -> R (k1 (inj_addr a1)) (k2 (inj_addr a2))),
        related_effect_step (Alloca t k1) (Alloca t k2)

  | related_effect_Load :
      forall a1 a2 k1 k2
        (HRa : a1 = a2)
        (HRk : (forall (v1 v2:value), v1 = v2 -> R (k1 v1) (k2 v2))),
        related_effect_step (Load a1 k1) (Load a2 k2)

  | related_effect_Store  :
      forall a1 a2 v1 v2 k1 k2
        (HRa : a1 = a2)
        (HRv : v1 = v2)
        (HRk : R k1 k2),
        related_effect_step (Store a1 v1 k1) (Store a2 v2 k2)

  | related_effect_Call :
      forall v1 v2 vs1 vs2 k1 k2
        (HRv : v1 = v2)
        (HRvs : vs1 = vs2)
        (HRk : (forall (rv1 rv2:value), rv1 = rv2 -> R (k1 v1) (k2 v2))),
        related_effect_step (Call v1 vs1 k1) (Call v2 vs2 k2)
  .
  Hint Constructors related_effect_step.
  
  Lemma related_effect_refl : (reflexive _ R) -> reflexive _ related_effect_step.
  Proof.
    unfold reflexive.
    intros HR x.
    destruct x; eauto.
    - econstructor. intros a1 a2 H. subst. eauto.
    - econstructor; eauto. intros v1 v2 H. subst. eauto.
  Qed.      

  Lemma related_effect_symm : (symmetric _ R) -> symmetric _ related_effect_step.
  Proof.
    unfold symmetric.
    intros HR x y H.
    dependent destruction H; eauto.
  Qed.

  Lemma related_effect_trans : (transitive _ R) -> transitive _ related_effect_step.
  Proof.
    unfold transitive.
    intros HR x y z H1 H2.
    dependent destruction H1; dependent destruction H2; eauto.
  Qed.    
End RELATED_EFFECTS.    

Section RELATED_EVENTS.

  Variable X : Type.
  Variable R : X -> X -> Prop.
  
  Inductive related_event_step : Event X -> Event X -> Prop :=
  | related_event_fin :
      forall v1 v2
        (Hv: v1 = v2),
        related_event_step (Fin v1) (Fin v2)

  | related_event_err :
      forall s1 s2,
        related_event_step (Err s1) (Err s2)

  | related_event_eff :
      forall e1 e2
        (HRe : related_effect_step R e1 e2),
        related_event_step (Eff e1) (Eff e2)
  .
  Hint Constructors related_event_step.
  
  Lemma related_event_refl : (reflexive _ R) -> reflexive _ related_event_step.
  Proof.
    unfold reflexive.
    intros HR x.
    destruct x; eauto. 
    - constructor. apply related_effect_refl; auto.
  Qed.      

  Lemma related_event_symm : (symmetric _ R) -> symmetric _ related_event_step.
  Proof.
    unfold symmetric.
    intros HR x y H.
    dependent destruction H; subst; constructor; eauto.
    - apply related_effect_symm; auto.
  Qed.

  Lemma related_event_trans : (transitive _ R) -> transitive _ related_event_step.
  Proof.
    unfold transitive.
    intros HR x y z H1 H2.
    dependent destruction H1; dependent destruction H2; constructor; eauto.
    - eapply related_effect_trans; eauto.
  Qed.    
  
End RELATED_EVENTS.

Section OBSERVATIONAL_EQUIVALENCE. 

  Variable R : Obs -> Obs -> Prop.
  
  Inductive obs_equiv_step : Obs -> Obs -> Prop :=
  | obs_equiv_step_vis :
      forall e1 e2
        (HRe : related_event_step R e1 e2),
        obs_equiv_step (Vis e1) (Vis e2)

  | obs_equiv_step_tau :
      forall k1 k2
        (HRk : R k1 k2),
        obs_equiv_step (Tau k1) (Tau k2)

  | obs_equiv_step_lft :
      forall k1 k2
        (IH : obs_equiv_step k1 k2),
        obs_equiv_step (Tau k1) k2

  | obs_equiv_step_rgt :
      forall k1 k2
        (IH : obs_equiv_step k1 k2),
        obs_equiv_step k1 (Tau k2)
  .
  Hint Constructors obs_equiv_step.
  
End OBSERVATIONAL_EQUIVALENCE.

Hint Constructors related_effect_step related_event_step obs_equiv_step.

Lemma related_effect_step_monotone : forall X (R1 R2: X -> X -> Prop)
                                        (HR: forall d1 d2, R1 d1 d2 -> R2 d1 d2) e1 e2
                                        (HM:related_effect_step R1 e1 e2),
    related_effect_step R2 e1 e2.
Proof.
  intros X R1 R2 HR e1 e2 HM.
  dependent destruction HM; constructor; eauto.
Qed.  
Hint Resolve related_effect_step_monotone : paco.

Lemma related_event_step_monotone : forall X (R1 R2:X -> X -> Prop)
                                        (HR: forall d1 d2, R1 d1 d2 -> R2 d1 d2) m1 m2
                                        (HM:related_event_step R1 m1 m2),
    related_event_step R2 m1 m2.
Proof.
  intros X R1 R2 HR m1 m2 HM.
  dependent destruction HM; constructor; eauto using related_effect_step_monotone.
Qed.  
Hint Resolve related_event_step_monotone : paco.  

Lemma obs_equiv_step_monotone : monotone2 obs_equiv_step.
Proof.
  unfold monotone2. intros. induction IN; eauto using related_event_step_monotone.
Qed.
Hint Resolve obs_equiv_step_monotone : paco.

Definition obs_equiv (p q: Obs) := paco2 obs_equiv_step bot2 p q.
Hint Unfold obs_equiv.

Lemma upaco2_refl : forall {X} F r, reflexive X r -> reflexive _ (upaco2 F r).
Proof.
  intros X F r H.
  unfold reflexive. intros. right. apply H.
Qed.

Lemma obs_equiv_refl : reflexive Obs obs_equiv.
Proof.
  pcofix CIH. intro d.
  pfold. destruct d; eauto.
  - destruct v; eauto. destruct e; econstructor; eauto; constructor; apply related_effect_refl;
    apply upaco2_refl; auto.
Qed.

Lemma obs_equiv_symm : symmetric Obs obs_equiv.
Proof.
  pcofix CIH.
  intros d1 d2 H.
  punfold H. 
  induction H; pfold; econstructor; eauto.
  - dependent destruction HRe; subst; eauto.
    constructor. inversion HRe; constructor; eauto.
    + intros. specialize (HRk a2 a1 (sym_eq H1)). pclearbot. right. eauto.
    + intros. specialize (HRk v2 v1 (sym_eq H1)). pclearbot. right. eauto.
    + pclearbot. right.  eauto.
    + intros. specialize (HRk v2 v1 (sym_eq HRv)). pclearbot. right. eauto.
  - pclearbot. right. eauto.
  - punfold IHobs_equiv_step.
  - punfold IHobs_equiv_step.
Qed.    
      
Inductive tau_star (P:Obs -> Prop) : Obs  -> Prop :=
| tau_star_zero : forall (d:Obs), P d -> tau_star P d
| tau_star_tau  : forall (d:Obs), tau_star P d -> tau_star P (Tau d)
.                                                       
Hint Constructors tau_star.

Lemma tau_star_monotone : monotone1 tau_star.
Proof.
  unfold monotone1.
  intros x0 r r' IN LE.
  induction IN; auto.
Qed.  
Hint Resolve tau_star_monotone : paco.

(* This predicate relates two traces that agree on a non-tau step *)
Inductive obs_event (R: Obs -> Obs -> Prop) : Obs -> Obs -> Prop :=
| obs_event_vis : forall e1 e2, related_event_step R e1 e2 -> obs_event R (Vis e1) (Vis e2)
.                                                                  
Hint Constructors obs_event.

Lemma obs_event_monotone : monotone2 obs_event.
Proof.
  unfold monotone2.
  intros x0 x1 r r' IN LE.
  induction IN; auto. constructor. eapply related_event_step_monotone; eauto.
Qed.

Inductive obs_equiv_big_step (R:Obs -> Obs -> Prop) : Obs -> Obs -> Prop :=
| obs_equiv_big_diverge s1 s2 (DS1:diverges s1) (DS2:diverges s2) : obs_equiv_big_step R s1 s2
| obs_equiv_big_taus s1 s2 t1 t2
                     (TS1:tau_star (fun t => t = t1) s1)
                     (TS2:tau_star (fun t => t = t2) s2)
                     (HO: obs_event R t1 t2) : obs_equiv_big_step R s1 s2
.                                                                 
Hint Constructors obs_equiv_big_step.

Lemma obs_equiv_big_step_monotone : monotone2 obs_equiv_big_step.
Proof.
  unfold monotone2.
  intros x0 x1 r r' IN LE.
  induction IN; auto.
  eapply obs_equiv_big_taus. apply TS1. apply TS2.
  eapply obs_event_monotone. apply HO. exact LE.
Qed.  
Hint Resolve obs_equiv_big_step_monotone : paco.

Definition obs_equiv_big (d1 d2:Obs) := paco2 obs_equiv_big_step bot2 d1 d2.
Hint Unfold obs_equiv_big.

Lemma obs_equiv_tau_lft : forall (d1 d2:Obs), obs_equiv d1 d2 -> obs_equiv (Tau d1) d2.
Proof.
  intros.
  pfold. apply obs_equiv_step_lft.
  punfold H.
Qed.  

Lemma obs_equiv_tau_rgt : forall (d1 d2:Obs), obs_equiv d1 d2 -> obs_equiv d1 (Tau d2).
Proof.
  intros.
  pfold. apply obs_equiv_step_rgt.
  punfold H.
Qed.  

Lemma obs_equiv_lft_inversion : forall(d1 d2:Obs), obs_equiv (Tau d1) d2 -> obs_equiv d1 d2.
Proof.
  intros d1 d2 H.
  punfold H. remember (Tau d1) as d. 
  induction H; try (solve [inversion Heqd; subst; clear Heqd]).
  - inversion Heqd. subst. apply obs_equiv_tau_rgt. pclearbot. punfold HRk.
  - inversion Heqd. subst. pfold. exact H.
  - subst. apply obs_equiv_tau_rgt. apply IHobs_equiv_step. reflexivity.
Qed.    

Lemma obs_equiv_rgt_inversion : forall (d1 d2:Obs), obs_equiv d1 (Tau d2) -> obs_equiv d1 d2.
Proof.
  intros.
  apply obs_equiv_symm. apply obs_equiv_symm in H. apply obs_equiv_lft_inversion. exact H.
Qed.  

Lemma event_not_diverges : forall (d:Obs), tau_star non_tau d -> diverges d -> False.
Proof.
  intros d HS.
  induction HS.
  - intros HD; dependent destruction d; punfold HD; inversion HD.
  - intros HD. apply IHHS. punfold HD. dependent destruction HD. pclearbot. apply H.
Qed.    

(* CLASSICAL! *)
Lemma event_or_diverges : forall (d:Obs), tau_star non_tau d \/ diverges d.
Proof.
  intros d.
  destruct (classic (tau_star non_tau d)); eauto.
  right. revert d H.
  pcofix CIH.
  intros d H.
  destruct d; try solve [exfalso; apply H; constructor; simpl; auto].
  pfold. econstructor. right. eauto.
Qed.

Lemma obs_equiv_diverges : forall (d1 d2:Obs) (EQ: obs_equiv d1 d2) (HD:diverges d1), diverges d2.
Proof.
  pcofix CIH.
  intros d1 d2 EQ.
  punfold EQ. induction EQ; intros HD; try solve [punfold HD; inversion HD].
  - punfold HD. inversion HD. pclearbot. subst.
    pfold. constructor. right. eauto.
  - punfold HD. inversion HD. subst. pclearbot. apply IHEQ. apply H0.
  - pfold. constructor. left. auto.
Qed.    

Lemma obs_equiv_event : forall (d1 d2:Obs) (EQ:obs_equiv d1 d2) (HS:tau_star non_tau d1), tau_star non_tau d2.
Proof.
  intros d1 d2 EQ HS.
  revert d2 EQ.
  induction HS; intros d2 EQ.
  - punfold EQ. induction EQ; auto.
    inversion H.
  - punfold EQ. dependent induction EQ.
    + apply tau_star_tau. apply IHHS. pclearbot. eauto.
    + apply IHHS. pfold. exact EQ.
    + apply tau_star_tau. eauto.
Qed.      

Lemma obs_equiv_diverges_or_event : forall (d1 d2:Obs) (EQ:obs_equiv d1 d2),
    (diverges d1 /\ diverges d2) \/ (tau_star non_tau d1 /\ tau_star non_tau d2).
Proof.
  intros d1 d2 EQ.
  destruct (@event_or_diverges d1) as [HS | HD].
  - right. eauto using obs_equiv_event.
  - left. eauto using obs_equiv_diverges.
Qed.    

Lemma obs_equiv_big_step_tau_left :  forall R (d1 d2:Obs)
                                       (HR: paco2 obs_equiv_big_step R d1 d2), paco2 obs_equiv_big_step R (Tau d1) d2.
Proof.
  intros R d1 d2 HR.
  punfold HR.
  pfold.
  destruct HR.
  - apply obs_equiv_big_diverge; eauto. pfold. constructor. left. eauto.
  - eapply obs_equiv_big_taus; eauto.
Qed.

Lemma obs_equiv_big_step_tau_right :  forall R (d1 d2:Obs)
                                       (HR: paco2 obs_equiv_big_step R d1 d2), paco2 obs_equiv_big_step R d1 (Tau d2).
Proof.
  intros R d1 d2 HR.
  punfold HR.
  pfold.
  destruct HR.
  - apply obs_equiv_big_diverge; eauto. pfold. constructor. left. eauto.
  - eapply obs_equiv_big_taus; eauto.
Qed.

Lemma obs_equiv_implies_obs_equiv_big: forall (d1 d2:Obs) (EQ:obs_equiv d1 d2), obs_equiv_big d1 d2.
Proof.
  pcofix CIH.
  intros d1 d2 EQ.
  destruct (@obs_equiv_diverges_or_event d1 d2 EQ) as [[HD1 HD2]|[HS1 HS2]]; eauto.
  induction HS1.
  - induction HS2.
    + pfold. eapply obs_equiv_big_taus; try solve [eauto].
      punfold EQ. dependent destruction EQ; eauto; try solve [simpl in H; inversion H]; try solve [simpl in H0; inversion H0].
      constructor.
      apply related_event_step_monotone with (R1 := (upaco2 obs_equiv_step bot2)).
      intros d1 d2 H2. right.  eapply CIH. pclearbot. eapply H2.
      exact HRe.
    + eauto using obs_equiv_big_step_tau_right, obs_equiv_rgt_inversion.
  - eauto using obs_equiv_big_step_tau_left, obs_equiv_lft_inversion.
Qed.
      
Lemma obs_equiv_big_implies_obs_equiv : forall (d1 d2:Obs) (EQB:obs_equiv_big d1 d2), obs_equiv d1 d2.
Proof.
  pcofix CIH.
  intros d1 d2 EQB.
  punfold EQB. dependent destruction EQB.
  - punfold DS1. punfold DS2.
    dependent destruction DS1. dependent destruction DS2.
    pfold. econstructor; eauto. right. apply CIH. pclearbot.
    pfold. eapply obs_equiv_big_diverge; eauto.
  - dependent induction TS1; subst.
    + dependent induction TS2; subst.
      * pfold. dependent destruction HO; eauto.
        constructor. eapply related_event_step_monotone with (R1 := (upaco2 obs_equiv_big_step bot2)).
        intros. right. apply CIH. pclearbot. eauto.
        exact H.
      * pfold.  apply IHTS2 in HO. punfold HO.
    + pfold. constructor. apply IHTS1 in TS2; eauto. punfold TS2.
Qed.      

Lemma obs_event_non_tau_left : forall R (d1 d2:Obs), obs_event R d1 d2 -> non_tau d1.
Proof.
  intros R d1 d2 H.
  dependent destruction H; simpl; auto.
Qed.

Lemma obs_event_non_tau_right : forall R (d1 d2:Obs), obs_event R d1 d2 -> non_tau d2.
Proof.
  intros R d1 d2 H.
  dependent destruction H; simpl; auto.
Qed.

Lemma tau_star_non_tau_unique : forall (d d1 d2:Obs)
   (TS1:tau_star (fun s => s = d1) d)
   (TS2:tau_star (fun s => s = d2) d)
   (NT1:non_tau d1)
   (NT2:non_tau d2),
    d1 = d2.
Proof.
  intros d d1 d2 TS1.
  revert d2.
  induction TS1; intros d2 TS2 ND1 ND2.
  - induction TS2; subst; eauto.
    + simpl in ND1. inversion ND1.
  - dependent destruction TS2; eauto.
    simpl in ND2. inversion ND2.
Qed.    

(*
Lemma obs_equiv_mem_step_trans:
  forall {A} (R : relation (Obs A)) (TR:transitive _ R) m1 m2 m3,
    obs_equiv_mem_step R m1 m2 -> obs_equiv_mem_step R m2 m3 ->
    obs_equiv_mem_step R m1 m3.
Proof.
  intros A R TR m1 m2 m3 H12 H23.
  inversion H12; subst; inversion H23; subst; constructor; intros; eauto.
Qed.
 *)
(*
Lemma obs_equiv_mem_step_trans:
  forall {A} (m1 m2 m3:effects A),
    obs_equiv_mem_step m1 m2 -> obs_equiv_mem_step m2 m3 ->
    obs_equiv_mem_step m1 m3.
Proof.
  intros A m1 m2 m3 H12 H23.
  inversion H12; subst; inversion H23; subst; constructor; intros; eauto.
  - rewrite H. rewrite H3. reflexivity.
  - rewrite H. rewrite H3. reflexivity.
  - rewrite H. rewrite H4. reflexivity.    
Qed.
*)

Lemma obs_equiv_big_trans : forall (d1 d2 d3:Obs), obs_equiv_big d1 d2 -> obs_equiv_big d2 d3 -> obs_equiv_big d1 d3.
Proof.
  pcofix CIH.
  intros d1 d2 d3 EQB1 EQB2.
  punfold EQB1. punfold EQB2.
  destruct EQB1, EQB2; eauto.
  - exfalso. eapply event_not_diverges, DS2.
    eapply tau_star_monotone. apply TS1.
    intros s PR. simpl in PR.  subst. eauto using obs_event_non_tau_left.
  - exfalso. eapply event_not_diverges, DS1.
    eapply tau_star_monotone. apply TS2.
    intros s PR. simpl in PR. subst. eauto using obs_event_non_tau_right.
  - eapply tau_star_non_tau_unique in TS2; eauto using obs_event_non_tau_left, obs_event_non_tau_right.
    subst.
    pfold. eapply obs_equiv_big_taus; eauto.
    destruct HO; dependent destruction HO0; eauto.
    econstructor.
    dependent destruction H; dependent destruction H0; constructor; eauto.
    dependent destruction HRe; dependent destruction HRe0; constructor; eauto.
    + intros a1 a2 Heq.
      specialize (HRk a1 a2 Heq). specialize (HRk0 a1 a2 Heq). subst. pclearbot.
      right. eapply CIH; eauto.
    + intros v1 v2 Heq.
      specialize (HRk v1 v2 Heq). specialize (HRk0 v1 v2 Heq). subst. pclearbot.
      right. eapply CIH; eauto.
    + pclearbot. right. eapply CIH; eauto.
    + intros rv1 rv2 Heq.
      specialize (HRk rv1 rv2 Heq). specialize (HRk0 rv1 rv2 Heq). subst. pclearbot.
      right. eapply CIH; eauto.
Qed.    
    

Lemma obs_equiv_trans : forall (d1 d2 d3:Obs), obs_equiv d1 d2 -> obs_equiv d2 d3 -> obs_equiv d1 d3.
Proof.
  eauto using obs_equiv_big_trans, obs_equiv_implies_obs_equiv_big, obs_equiv_big_implies_obs_equiv.
Qed.




(* This statement is false if d1 and d2 are inifinite Tau streams
    would have to weaken the conclusion to:
      (d1 = d2 /\ d1 = all_taus) \/ ... 
    this would probably require classical logic to prove.

Lemma obs_equiv_inversion : forall {A} (d1 d2:Obs A),
    obs_equiv d1 d2 ->  exists d1', exists d2', exists n, exists m,
            d1 = taus n d1' /\ d2 = taus m d2' /\ non_tau_head d1' /\ non_tau_head d2' /\ obs_equiv d1' d2'.
Proof.
Abort.  
*)


(* stuttering --------------------------------------------------------------- *)

Fixpoint taus (n:nat) (d:Obs) : Obs :=
  match n with
  | 0 => d
  | S n => Tau (taus n d)
  end.

Lemma stutter_simpl : forall (d1 d2: Obs) n, obs_equiv (taus n d1) d2 -> obs_equiv d1 d2.
Proof.
  intros. induction n. punfold H.
  eapply IHn. simpl in H. eapply obs_equiv_lft_inversion. eapply H.
Qed.

Lemma stutter : forall (d1 d2: Obs) n m, obs_equiv (taus n d1) (taus m d2) -> obs_equiv d1 d2.
Proof.
  intros.
  eapply stutter_simpl.
  eapply obs_equiv_symm.
  eapply stutter_simpl.
  eapply obs_equiv_symm.
  eauto.
Qed.

(* error-free observations -------------------------------------------------- *)


Section PREDICATE_EFFECTS.
  Variable X : Type.
  Variable R : X -> Prop.

  Inductive predicate_effect_step  : effects X -> Prop :=
  | predicate_effect_Alloca :
      forall t k
        (HRk : forall (a:addr), R (k (inj_addr a))),
        predicate_effect_step (Alloca t k)

  | predicate_effect_Load :
      forall a k
        (HRk : forall (v:value), R (k v)),
        predicate_effect_step (Load a k)

  | predicate_effect_Store  :
      forall a v k
        (HRk : R k),
        predicate_effect_step (Store a v k)

  | predicate_effect_Call :
      forall v vs k
        (HRk : forall (rv:value), R (k rv)),
        predicate_effect_step (Call v vs k)
  .
End PREDICATE_EFFECTS.

Hint Constructors predicate_effect_step.


Lemma predicate_effect_step_monotone : forall X (R1 R2: X -> Prop)
                                        (HR: forall d, R1 d -> R2 d) e
                                        (HM:predicate_effect_step R1 e),
    predicate_effect_step R2 e.
Proof.
  intros X R1 R2 HR e HM.
  dependent destruction HM; constructor; eauto.
Qed.  
Hint Resolve predicate_effect_step_monotone : paco.


Inductive error_free_event_step {X} (R : X -> Prop) : Event X -> Prop :=
| error_free_event_fin :
    forall v,
      error_free_event_step R (Fin v)

| error_free_event_eff :
      forall e
        (HRe : predicate_effect_step R e),
        error_free_event_step R (Eff e)
.
Hint Constructors error_free_event_step.

Lemma error_free_event_step_monotone : forall X (R1 R2: X -> Prop)
                                        (HR: forall d, R1 d -> R2 d) e
                                        (HM:error_free_event_step R1 e),
    error_free_event_step R2 e.
Proof.
  intros X R1 R2 HR e HM.
  dependent destruction HM; constructor; eauto.
  eapply predicate_effect_step_monotone; eauto.
Qed.  
Hint Resolve error_free_event_step_monotone : paco.

Inductive error_free_obs_step (R : Obs -> Prop) : Obs -> Prop :=
| error_free_vis : forall e, error_free_event_step R e -> error_free_obs_step R (Vis e)
| error_free_tau : forall k, R k -> error_free_obs_step R (Tau k)
.                                                  
Hint Constructors error_free_obs_step.

Lemma error_free_obs_step_monotone : monotone1 error_free_obs_step.
Proof.
  unfold monotone1.
  intros x0 r r' IN LE.
  induction IN; constructor; eauto.
  eapply error_free_event_step_monotone; eauto.
Qed.
Hint Resolve error_free_obs_step_monotone : paco.

Definition error_free_obs d := paco1 error_free_obs_step bot1 d.
Hint Unfold error_free_obs.

End Effects.