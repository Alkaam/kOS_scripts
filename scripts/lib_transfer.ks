@LAZYGLOBAL OFF.
pOut("lib_transfer.ks v1.3.0 20161130").

FOR f IN LIST(
  "lib_orbit.ks",
  "lib_burn.ks",
  "lib_orbit_match.ks",
  "lib_runmode.ks",
  "lib_hoh.ks",
  "lib_ca.ks"
) { RUNONCEPATH(loadScript(f)). }

GLOBAL CURRENT_BODY IS BODY.
GLOBAL MAX_SCORE IS 99999.
GLOBAL MIN_SCORE IS -999999999.
GLOBAL TIME_TO_NODE IS 900.

FUNCTION bodyChange
{
  PARAMETER cb.
  RETURN BODY <> cb.
}

FUNCTION nodeCopy
{
  PARAMETER n1, n2.
  SET n2:PROGRADE TO n1:PROGRADE.
  SET n2:NORMAL TO n1:NORMAL.
  SET n2:RADIALOUT TO n1:RADIALOUT.
  SET n2:ETA TO n1:ETA.
}

FUNCTION futureOrbit
{
  PARAMETER init_orb, count.

  LOCAL orb IS init_orb.
  LOCAL i IS 0.
  UNTIL i >= count {
    IF NOT orb:HASNEXTPATCH {
      pOut("WARNING: futureOrbit("+count+") called but patch "+i+" is the last.").
      SET i TO count.
    } ELSE { SET orb TO orb:NEXTPATCH. }
    SET i TO i + 1.
  }
  
  RETURN orb.
}

FUNCTION futureOrbitETATime
{
  PARAMETER init_orb, count.

  LOCAL eta_time IS TIME:SECONDS.
  LOCAL orb IS init_orb.
  LOCAL i IS 0.
  UNTIL i >= count {
    IF orb:HASNEXTPATCH {
      SET eta_time TO eta_time + orb:NEXTPATCHETA.
      SET orb TO orb:NEXTPATCH.
    } ELSE {
      SET eta_time TO eta_time + orb:PERIOD.
      SET i TO count.
    }
    SET i TO i + 1.
  }
  RETURN eta_time.
}

FUNCTION orbitReachesBody
{
  PARAMETER orb, dest, count IS 0.

  IF orb:BODY = dest { RETURN count. }
  ELSE IF orb:HASNEXTPATCH { RETURN orbitReachesBody(orb:NEXTPATCH,dest,count+1). }
  ELSE { RETURN -1. }
}

FUNCTION scoreNodeDestOrbit
{
  PARAMETER dest, pe, i, lan, n.
  LOCAL score IS 0.

  ADD n. WAIT 0.
  LOCAL orb IS n:ORBIT.
  LOCAL orb_count IS orbitReachesBody(orb,dest).
  IF orb_count >= 0 {
    SET score TO MAX_SCORE - nodeDV(n).
    LOCAL r IS dest:RADIUS + pe.
    LOCAL next_orb IS futureOrbit(orb,orb_count).
    LOCAL next_pe IS next_orb:PERIAPSIS.
    LOCAL next_i IS next_orb:INCLINATION.
    LOCAL next_lan IS next_orb:LAN.

    // calculate additional delta-v required to correct periapsis after circularisation
    LOCAL a0 IS dest:RADIUS + ((next_pe + pe) / 2).
    LOCAL v0 IS SQRT(dest:MU * ((2/r)-(1/a0))).
    LOCAL v1 IS SQRT(dest:MU/r).
    LOCAL dv_pe IS ABS(v1 - v0).
    SET score TO score - dv_pe.

    // calculate additional delta-v required to correct orbit plane after circularisation
    // and after correction of periapsis
    IF i >= 0 {
      IF lan < 0 { SET lan TO next_lan. }
      LOCAL ang IS VANG(orbitNormal(dest,i,lan),orbitNormal(dest,next_i,next_lan)).
      LOCAL v_circ IS SQRT(dest:MU/r).
      LOCAL dv_inc IS 2 * v_circ * SIN(ang/2).
      SET score TO score - dv_inc.
    }

  } ELSE IF dest:HASBODY {
    // base score on how close we get to destination within orbit of its parent body
    // if we don't reach the parent, try its parent and so on...
    LOCAL pb IS dest:BODY.
    SET orb_count TO orbitReachesBody(orb,pb).
    UNTIL orb_count >= 0 OR NOT pb:HASBODY {
      SET dest TO pb.
      SET pb TO pb:BODY.
      SET orb_count TO orbitReachesBody(orb,pb).
    }
    IF orb_count >= 0 {
      LOCAL u_time1 IS futureOrbitETATime(orb,orb_count).
      LOCAL u_time2 IS futureOrbitETATime(orb,orb_count+1).
      SET score TO -targetDist(dest,targetCA(dest,u_time1,u_time2)) / 1000.
    } ELSE { SET score TO MIN_SCORE. }

  } ELSE { SET score TO MIN_SCORE. }
  REMOVE n.

  RETURN score.
}

FUNCTION updateBest
{
  PARAMETER score_func, nn, bn, bs.
  LOCAL ns IS score_func(nn).
  IF ns > bs { nodeCopy(nn, bn). }
  RETURN MAX(ns, bs).
}

FUNCTION newNodeByDiff
{
  PARAMETER n, eta_diff, rad_diff, nrm_diff, pro_diff.
  RETURN NODE(n:ETA+eta_diff, n:RADIALOUT+rad_diff, n:NORMAL+nrm_diff, n:PROGRADE+pro_diff).
}

FUNCTION improveNode
{
  PARAMETER n, score_func.
  LOCAL ubn IS updateBest@:BIND(score_func).

  LOCAL best_node IS newNodeByDiff(n,0,0,0,0).
  LOCAL best_score IS score_func(best_node).
  LOCAL orig_score IS best_score.

  // start by trying a set of adjustments to just one node element at a time
  // FOR dv_power IN RANGE(-2,5,1): 2^-2 = 0.25m/s, 2^4 = 16m/s
  // 42 nodes
  LOCAL dv_delta_power IS 4.
  FOR dv_power IN RANGE(-2,5,1) {
    FOR mult IN LIST(-1,1) {
      LOCAL curr_score IS best_score.
      LOCAL dv_delta IS mult * 2^dv_power.

      SET best_score TO ubn(newNodeByDiff(n,0,0,0,dv_delta), best_node, best_score).
      SET best_score TO ubn(newNodeByDiff(n,0,0,dv_delta,0), best_node, best_score).
      SET best_score TO ubn(newNodeByDiff(n,0,dv_delta,0,0), best_node, best_score).

      IF best_score > curr_score { SET dv_delta_power TO dv_power. }
    }
  }

  IF best_score > orig_score { nodeCopy(best_node, n). }

  // now try combinations of adjusting all elements, reducing the size of the steps
  // each time we don't find an improvement
  // 27 nodes per loop
  LOCAL dv_delta IS 2^dv_delta_power.
  LOCAL done IS FALSE.
  UNTIL done {
    LOCAL curr_score IS best_score.

    FOR p_loop IN RANGE(-1,2,1) { FOR n_loop IN RANGE(-1,2,1) { FOR r_loop IN RANGE(-1,2,1) {
      LOCAL p_diff IS dv_delta * p_loop.
      LOCAL n_diff IS dv_delta * n_loop.
      LOCAL r_diff IS dv_delta * r_loop.
      SET best_score TO ubn(newNodeByDiff(n,0,r_diff,n_diff,p_diff), best_node, best_score).
    } } }

    IF best_score > curr_score { nodeCopy(best_node, n). }
    ELSE IF dv_delta < 0.01 { SET done TO TRUE. }
    ELSE { SET dv_delta TO dv_delta / 2. }
  }
}

FUNCTION nodeBodyToMoon
{
  PARAMETER u_time, dest, dest_pe, i IS -1, lan IS -1.

  LOCAL t_pe IS (dest:RADIUS + dest_pe) * COS(MIN(i,0))).

  LOCAL hnode IS nodeHohmann(dest, u_time, t_pe).
  improveNode(hnode,scoreNodeDestOrbit@:BIND(dest,dest_pe,i,lan)).

  RETURN hnode.
}

FUNCTION nodeMoonToBody
{
  PARAMETER u_time, moon, dest_pe, i IS -1, lan IS -1.

  LOCAL dest IS moon:OBT:BODY.

  LOCAL mu IS moon:MU.
  LOCAL hoh_mu IS dest:MU.
  LOCAL r_soi IS moon:SOIRADIUS.
  LOCAL r_pe IS ORBITAT(SHIP,u_time):SEMIMAJORAXIS.

  LOCAL r1 IS ORBITAT(moon,u_time):SEMIMAJORAXIS.
  LOCAL r2 IS dest_pe + dest:RADIUS.
  LOCAL v_soi IS SQRT(hoh_mu/r1) * (SQRT((2*r2)/(r1+r2)) -1).
  LOCAL v_pe IS SQRT(v_soi^2 + (2 * mu/r_pe) - (2 * mu/r_soi)).
  LOCAL v_orbit IS SQRT(mu/r_pe).
  LOCAL dv IS ABS(v_pe) - v_orbit.
  LOCAL a IS 1/((2/r_pe)-(v_pe^2 / mu)).
  LOCAL r_ap IS (2 * a) - r_pe.
  LOCAL energy IS (v_pe^2 / 2)-(mu / r_pe).
  LOCAL h IS r_pe * v_pe.
  LOCAL e IS 0.
  IF energy >= 0 { SET e TO SQRT(1 + (2 * energy * h^2 / mu^2)). }
  ELSE { SET e TO (r_ap - r_pe) / (r_ap + r_pe). }

  LOCAL theta_eject IS 100.
  IF e > 1 { SET theta_eject TO ARCCOS(-1/e). }
  ELSE { pOut("WARNING: Cannot calculate ejection angle as required orbit is not a hyperbola."). }

  LOCAL man_node IS NODE(u_time, 0, 0, ABS(dv)).

  LOCAL c_time IS u_time.
  LOCAL done IS FALSE.
  UNTIL done {
    LOCAL moon_pos IS POSITIONAT(moon,c_time).
    LOCAL moon_vel IS VELOCITYAT(moon,c_time):ORBIT.
    LOCAL s_pos IS posAt(SHIP,c_time).
    LOCAL s_normal IS VCRS(velAt(SHIP,c_time),s_pos).

    LOCAL ang IS VANG(s_normal,-moon_vel).
    LOCAL eff_i IS ABS(ang-90).
    LOCAL ret_xcl IS VXCL(s_normal,-moon_vel).
    LOCAL s_ang IS VANG(s_pos,ret_xcl).
    IF VDOT(VCRS(ret_xcl,s_pos),s_normal) < 0 { SET s_ang TO 360 - s_ang. }
    IF ABS(s_ang - theta_eject) < 0.5 AND eff_i < 25 {
      SET done TO TRUE.
      SET man_node:ETA TO c_time - TIME:SECONDS.
      LOCAL score_func IS scoreNodeDestOrbit@:BIND(dest,dest_pe,i,lan).
      improveNode(man_node,score_func).
    }
    SET c_time TO c_time + 15.
  }

  RETURN man_node.
}

FUNCTION doTransfer
{
  PARAMETER exit_mode, can_stage, dest, dest_pe, dest_i IS -1, dest_lan IS -1.

  LOCAL LOCK rm TO runMode().

  pOut("Transferring to " + dest:NAME + " with target periapsis of " + dest_pe + "m.").

  IF rm < 101 OR rm > 149 { runMode(101). }

UNTIL rm = exit_mode
{
  IF rm = 101 {
    removeAllNodes().
    LOCAL t_time IS TIME:SECONDS+600.
    LOCAL node_ok IS FALSE.
    LOCAL n1 IS NODE(0,0,0,0).
    IF dest:BODY = BODY {
      // planet to moon
      SET n1 TO nodeBodyToMoon(t_time,dest,dest_pe,dest_i,dest_lan).
    } ELSE IF dest = BODY:OBT:BODY {
      // moon to planet (or planet to sun)
      SET n1 TO nodeMoonToBody(t_time,BODY,dest_pe,dest_i,dest_lan).
    } ELSE {
      // other transfers not supported yet - TBD
    }

    IF n1:ETA > 0 {
      addNode(n1).
      IF orbitReachesBody(n1:ORBIT,dest) > 0 {
        pOut("Trans-"+dest:NAME+" Injection node added.").
        SET node_ok TO TRUE.
      } ELSE { pOut("ERROR: transfer node does not reach "+dest:NAME+"."). }
    } ELSE { pOut("ERROR: transfer node was not created successfully or is in past."). }

    IF node_ok { runMode(102). }
    ELSE {
      removeAllNodes().
      runMode(109,101).
    }
  } ELSE IF rm = 102 {
    IF HASNODE {
      IF execNode(can_stage) { runMode(111). } ELSE { runMode(109,102). }
    } ELSE {
      IF BODY = dest { runMode(131). }
      ELSE IF orbitReachesBody(SHIP:OBT,dest) > 0 { runMode(111). }
      ELSE { runMode(109,101). }
    }
  } ELSE IF rm = 111 {
    // check if we've appeared in the orbit of the destination beyond the periapsis
    LOCAL pe_eta IS secondsToTA(SHIP,TIME:SECONDS+1,0) + 1.
    IF BODY = dest AND (pe_eta < 0 OR (SHIP:OBT:HASNEXTPATCH AND ETA:TRANSITION < pe_eta)) { runMode(131). }
    ELSE { runMode(112). }
  } ELSE IF rm = 112 {
    SET TIME_TO_NODE TO 900.
    runMode(113).
  } ELSE IF rm = 113 {
    IF NOT isSteerOn() {
      steerSun().
      WAIT UNTIL steerOk().
    }
    // check node would not be too close to SoI transition / periapsis before continuing
    IF (SHIP:OBT:HASNEXTPATCH AND ETA:TRANSITION < (TIME_TO_NODE + 900)) OR
        ETA:PERIAPSIS < (TIME_TO_NODE + 900) { runMode(115). }
    ELSE {
      // check accuracy of orbit
      // TBD - work out when we can sensibly try to change the inclination
      LOCAL mcc IS NODE(TIME:SECONDS+TIME_TO_NODE,0,0,0).
      ADD mcc.
      WAIT 0.
      LOCAL orb_pe IS 0.
      LOCAL orb_count IS orbitReachesBody(mcc:ORBIT,dest).
      IF orb_count >= 0 { SET orb_pe TO futureOrbit(mcc:ORBIT,orb_count):PERIAPSIS. }
      REMOVE mcc.
      IF orb_count < 0 OR ABS(orb_pe - dest_pe) > (1000 * 25^orb_count) {
        LOCAL score_func IS scoreNodeDestOrbit@:BIND(dest,dest_pe,dest_i,dest_lan).
        improveNode(mcc,score_func).
        addNode(mcc).
        pOut("Mid-course correction node added.").
        runMode(114).
      } ELSE { runMode(115). }
    }
  } ELSE IF rm = 114 {
    IF HASNODE {
      IF execNode(can_stage) { runMode(113). } ELSE { runMode(119,114). }
    } ELSE {
      IF BODY = dest { runMode(131). }
      ELSE IF orbitReachesBody(SHIP:OBT,dest) > 0 { runMode(113). }
      ELSE { runMode(119,112). }
    }
  } ELSE IF rm = 115 {
    // go to next SoI transition if not already in SoI of destination:
    IF BODY = dest { runMode(131). } ELSE { runMode(121). }
  } ELSE IF rm = 121 {
    IF BODY = CURRENT_BODY AND BODY <> dest AND SHIP:OBT:HASNEXTPATCH {
      LOCAL next_body IS SHIP:OBT:NEXTPATCH:BODY.
      pOut("Sphere of influence transition from "+BODY:NAME+" to "+next_body:NAME+
           " in "+ROUND(ETA:TRANSITION)+"s.").
      LOCAL on_body_change IS bodyChange@:BIND(CURRENT_BODY).

      pOut("Warping to transition.").
      UNTIL on_body_change() OR NOT SHIP:OBT:HASNEXTPATCH {
        LOCAL warp_time IS TIME:SECONDS + ETA:TRANSITION - 180.
        IF warp_time > TIME:SECONDS { doWarp(warp_time, on_body_change). }
        ELSE { doWarp(TIME:SECONDS + 360, on_body_change). }
      }
      IF on_body_change() { hudMsg("Sphere of influence body now: " + BODY:NAME). }
      IF ADDONS:KAC:AVAILABLE {
        LOCAL al IS LIST().
        SET al TO LISTALARMS("All").
        FOR a IN al { IF a:REMAINING < 0 { DELETEALARM(a:ID). } }
      }
    }
    SET CURRENT_BODY TO BODY.
    runMode(111).
  } ELSE IF rm = 131 {
    // in sphere of influence of destination
    // re-entry or aerobraking handled separately by other scripts
    IF BODY:ATM:EXISTS AND PERIAPSIS < BODY:ATM:HEIGHT { runMode(133). }
    ELSE {
      // enter orbit, but first check in case we're beyond the periapsis
      LOCAL pe_eta IS secondsToTA(SHIP,TIME:SECONDS+1,0) + 1.
      IF (SHIP:OBT:HASNEXTPATCH AND ETA:TRANSITION < pe_eta) OR pe_eta < 0 { SET pe_eta TO 60. }
      LOCAL oi IS nodeAlterOrbit(TIME:SECONDS+pe_eta,dest_pe).
      addNode(oi).
      pOut(dest:NAME + " Orbit Insertion node added.").
      runMode(132).
    }
  } ELSE IF rm = 132 {
    IF HASNODE {
      IF execNode(can_stage) { runMode(133). } ELSE { runMode(139,132). }
    } ELSE {
      IF SHIP:OBT:HASNEXTPATCH { runMode(131). } ELSE { runMode(133). }
    }
  } ELSE IF rm = 133 {
    steerSun().
    WAIT UNTIL steerOk().
    dampSteering().
    runMode(exit_mode).
  } ELSE IF MOD(rm,10) = 9 AND rm > 100 AND rm < 150 {
    hudMsg("Error state. Hit abort to switch to recovery mode: " + abortMode() + ".").
    steerSun().
    WAIT UNTIL MOD(runMode(),10) <> 9.
  } ELSE {
    pOut("Transfer - unexpected run mode: " + rm).
    runMode(149,101).
  }

  WAIT 0.
}

}
